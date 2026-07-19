import AttacheCore
import Foundation

/// Live narration + coarse activity for WATCHED opencode sessions (INF-397),
/// the last big opencode parity gap.
///
/// opencode stores every session as rows in one shared SQLite database
/// (`opencode.db`, WAL mode), not a tailable per-session `.jsonl`, so the
/// file-tailing watchers (`CodexSessionWatcher`, `SessionActivityWatcher`)
/// structurally skip it: they walk directories for `.jsonl` files whose name
/// carries the session id, and `opencode.db` matches neither. Before this
/// watcher existed, watching an opencode session produced no live voicemail
/// cards and no activity phrases; only historic summaries, search, and two-way
/// (with the delivered-reply fallback from INF-395/INF-396) worked.
///
/// This watcher polls the shared database read-only on a modest cadence for the
/// sessions the user is watching, and on a NEW completed assistant turn
/// (`finish == "stop"`) past the per-session checkpoint narrates it through the
/// SAME filing path the file watchers use: a `NormalizedEvent` carrying the
/// `opencode-session-db` adapter tag, fed to `AppModel.receive`, so
/// `linkResponseCard` and the recap machinery treat it identically to any other
/// source's live turn. First registration of a session does NOT narrate the
/// historic backlog: the checkpoint initializes to the current latest completed
/// turn, so only turns that complete AFTER watching begins are narrated,
/// mirroring how the file watchers start at end-of-file.
///
/// Change detection: opencode writes land in the WAL (`opencode.db-wal`), so a
/// cheap "did anything change" signal is the size+mtime of the db and its WAL.
/// When that signal is unchanged and every watched session is already
/// checkpointed, the whole tick skips the SQLite reads entirely: an idle watch
/// does no query work, only a stat of two files. A not-yet-checkpointed session
/// always forces one read so its checkpoint initializes.
///
/// Threading: the repeating timer lives on the main run loop, but every tick's
/// database work runs on a private serial queue, and callbacks are invoked from
/// that queue (the `AppModel` wiring hops to main to publish, exactly as it
/// wraps `CodexSessionWatcher`'s callbacks). All mutable bookkeeping is confined
/// to that serial queue, so there is no cross-thread state race.
final class OpencodeLiveWatcher {
    /// A newly completed assistant turn to narrate as a voicemail card, wired to
    /// `AppModel.receive` (the same contract as `CodexSessionWatcher.onEvent`).
    var onEvent: ((NormalizedEvent) -> Void)?
    /// A coarse working/idle transition for a watched session, wired to
    /// `AppModel.handleAttentionChange` (the same contract as
    /// `CodexSessionWatcher.onAttention`). opencode rows carry no tool-level
    /// detail until parts complete, so this stays turn-level: `.active` while a
    /// turn is in flight (or a user turn awaits its reply), `.turnComplete` when
    /// the latest turn just finished, `.quiet` otherwise.
    var onAttention: ((String, SessionAttentionState, Date?) -> Void)?
    var onStatus: ((String) -> Void)?

    private let databaseURLProvider: () -> URL
    private let loadSnapshot: (String, URL) -> OpencodeSessionSnapshot?
    private let changeTokenProvider: (URL) -> String?
    private let adapterTag: String
    private let pollInterval: TimeInterval

    private let queue = DispatchQueue(label: "com.bryanlabs.attache.opencode-live-watcher")
    private var timer: Timer?
    /// Watched opencode sessions, id -> display title (for the card title).
    private var watched: [String: String] = [:]
    private var startedSessionIDs: Set<String> = []
    private var checkpoints: [String: Int64] = [:]
    private var attentionStates: [String: SessionAttentionState] = [:]
    private var lastChangeToken: String?

    init(
        databaseURL: URL? = nil,
        loadSnapshot: @escaping (String, URL) -> OpencodeSessionSnapshot? = { OpencodeSessionSnapshot.load(sessionID: $0, databaseURL: $1) },
        changeTokenProvider: ((URL) -> String?)? = nil,
        adapterTag: String = "opencode-session-db",
        pollInterval: TimeInterval = 2.5
    ) {
        self.databaseURLProvider = { databaseURL ?? OpencodePaths.databaseURL() }
        self.loadSnapshot = loadSnapshot
        self.changeTokenProvider = changeTokenProvider ?? OpencodeLiveWatcher.defaultChangeToken
        self.adapterTag = adapterTag
        self.pollInterval = pollInterval
    }

    /// Watch every attached active opencode session. No polling runs at all when
    /// none are watched (the timer is torn down), so an installation with the
    /// opencode source disabled or nothing attached pays nothing.
    func watch(_ sessions: [CodexSessionTarget]) {
        let opencode = sessions
            .filter { $0.category == .activeSession && $0.sourceKind == .opencode }
        let next = Dictionary(opencode.map { ($0.id, $0.displayTitle) }, uniquingKeysWith: { first, _ in first })
        // Synchronous so first-registration checkpoints are established before
        // watch() returns: a subsequent poll (the timer's, or a test's) then sees
        // a fully reconciled watch set with no ordering ambiguity. The work is one
        // bounded read per newly-added session.
        queue.sync { self.reconcile(watched: next) }
        // Timer lifecycle on main: only poll while something is watched.
        if next.isEmpty {
            timer?.invalidate(); timer = nil
        } else if timer == nil {
            let created = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
                self?.queue.async { self?.pollLocked() }
            }
            RunLoop.main.add(created, forMode: .common)
            timer = created
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        queue.async { [weak self] in
            guard let self else { return }
            self.watched.removeAll()
            self.startedSessionIDs.removeAll()
            self.checkpoints.removeAll()
            self.attentionStates.removeAll()
            self.lastChangeToken = nil
        }
    }

    /// Test seam: run one poll synchronously on the work queue. Any `onEvent` /
    /// `onAttention` callbacks fire before this returns, so a test can drive the
    /// watcher tick-by-tick deterministically without the wall-clock timer.
    func poll() { queue.sync { self.pollLocked() } }

    // MARK: - Queue-confined bookkeeping

    private func reconcile(watched next: [String: String]) {
        let nextIDs = Set(next.keys)
        startedSessionIDs.formIntersection(nextIDs)
        checkpoints = checkpoints.filter { nextIDs.contains($0.key) }
        attentionStates = attentionStates.filter { nextIDs.contains($0.key) }
        watched = next
        guard !next.isEmpty else { return }
        // Establish checkpoints for any newly-added session promptly rather than
        // waiting a full poll interval, so a mid-turn session shows working right
        // away instead of after the first timer tick.
        pollLocked()
    }

    private func pollLocked() {
        guard !watched.isEmpty else { return }
        let dbURL = databaseURLProvider()
        let token = changeTokenProvider(dbURL)
        let allStarted = startedSessionIDs.isSuperset(of: watched.keys)
        // Skip the SQLite reads only when the cheap file signal proves nothing
        // changed AND every watched session already has a checkpoint. A missing
        // signal (nil) or an unstarted session always forces the read.
        if let token, token == lastChangeToken, allStarted { return }
        lastChangeToken = token
        for id in watched.keys {
            guard let snapshot = loadSnapshot(id, dbURL) else { continue }
            processSession(id: id, snapshot: snapshot)
        }
    }

    private func processSession(id: String, snapshot: OpencodeSessionSnapshot) {
        let messages = snapshot.messages
        if !startedSessionIDs.contains(id) {
            // First registration: checkpoint at the current latest completed turn
            // so the historic backlog is never narrated; only completions after
            // this point become cards.
            startedSessionIDs.insert(id)
            checkpoints[id] = Self.latestCompletedAssistantTime(messages)
            publishAttention(id: id, messages: messages)
            return
        }
        let checkpoint = checkpoints[id] ?? 0
        var advanced = checkpoint
        for message in messages {
            let time = Int64(message.timeCreated)
            guard time > checkpoint else { continue }
            guard message.role == "assistant", message.finish == "stop" else { continue }
            let text = OpencodeTranscriptAdapter.narratableText(of: message)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            emit(sessionID: id, text: text, directory: snapshot.directory, timeCreatedMillis: time)
            advanced = max(advanced, time)
        }
        checkpoints[id] = advanced
        publishAttention(id: id, messages: messages)
    }

    private func emit(sessionID: String, text: String, directory: String?, timeCreatedMillis: Int64) {
        var event = NormalizedEvent(
            source: SourceKind.opencode.rawValue,
            eventType: "assistant.completed",
            externalSessionID: sessionID,
            projectPath: directory,
            title: watched[sessionID] ?? SourceKind.opencode.displayName,
            text: text
        )
        event.metadata["adapter"] = adapterTag
        // Source time = when opencode wrote the turn, not when we polled it, so
        // ordering and dedup use the real timeline (mirrors CodexSessionWatcher).
        let timestamp = Date(timeIntervalSince1970: Double(timeCreatedMillis) / 1000)
        event.metadata["source_time"] = PipelineOrdering.isoString(from: timestamp)
        event.metadata["attache_summary"] = EventNormalizer.summary(for: event)
        onEvent?(event)
        onStatus?("Observed opencode session \(sessionID.prefix(8)).")
    }

    private func publishAttention(id: String, messages: [OpencodeTranscriptAdapter.MessageRow]) {
        let state = Self.attentionState(messages)
        guard attentionStates[id] != state else { return }
        attentionStates[id] = state
        let recordAt = messages.last.map { Date(timeIntervalSince1970: $0.timeCreated / 1000) }
        onAttention?(id, state, recordAt)
    }

    // MARK: - Pure helpers

    /// The `timeCreated` (ms) of the latest completed assistant turn, or 0 when
    /// none has completed. The first-registration checkpoint, so a turn already
    /// completed at attach is never re-narrated but a turn that was in flight at
    /// attach (its `timeCreated` is later than the last completed turn's) still
    /// narrates when it finishes.
    static func latestCompletedAssistantTime(_ messages: [OpencodeTranscriptAdapter.MessageRow]) -> Int64 {
        var latest: Int64 = 0
        for message in messages where message.role == "assistant" && message.finish == "stop" {
            latest = max(latest, Int64(message.timeCreated))
        }
        return latest
    }

    /// Coarse turn-level activity for a session, the opencode analog of the file
    /// sources' attention classification.
    static func attentionState(_ messages: [OpencodeTranscriptAdapter.MessageRow]) -> SessionAttentionState {
        guard let last = messages.last else { return .quiet }
        switch last.role {
        case "assistant":
            return last.finish == "stop" ? .turnComplete : .active
        case "user":
            // A user turn with no assistant reply yet: the agent is (about to be)
            // working. Coarse by design (no tool-level rows exist yet).
            return .active
        default:
            return .quiet
        }
    }

    /// A cheap change signal: the size+mtime of `opencode.db` and its `-wal`.
    /// Returns nil when the database file itself is absent, so a caller never
    /// treats "no file" as "unchanged" and skips a read it should make.
    private static func defaultChangeToken(dbURL: URL) -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: dbURL.path) else { return nil }
        func stat(_ url: URL) -> String {
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else { return "-" }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            return "\(size):\(mtime)"
        }
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        return "db=\(stat(dbURL));wal=\(stat(walURL))"
    }
}
