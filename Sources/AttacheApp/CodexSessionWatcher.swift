import AttacheCore
import Foundation

final class CodexSessionWatcher {
    var onEvent: ((NormalizedEvent) -> Void)?
    var onStatus: ((String) -> Void)?
    /// Fires when a watched session's attention state changes (INF-179).
    var onAttention: ((String, SessionAttentionState) -> Void)?
    /// Fires when a watched session's live sub-agent count changes (INF-275).
    var onSubAgents: ((String, Int) -> Void)?

    private let sessionsDirectory: URL
    private let archivedSessionsDirectory: URL
    private let claudeProjectsDirectory: URL
    private let defaults: UserDefaults
    private var timer: Timer?
    private var sessions: [CodexSessionTarget] = []   // all attached sessions, watched concurrently
    private var startedSessionIDs: Set<String> = []   // polled at least once (so the latest is emitted only on first attach)
    private var fileOffsets: [String: UInt64] = [:]
    private var pendingFragments: [String: String] = [:]
    private var currentWorkingDirectories: [String: String] = [:]
    private var locatedFileURLs: [String: URL] = [:]
    private var locateMissTick: [String: Int] = [:]   // poll tick of the last locate miss, for negative caching
    private var pollTick = 0
    private let missRecheckPolls = 15                 // ~30s at the 2s poll interval
    private var coalescers: [String: NarrationCoalescer] = [:]   // per-session turn buffers
    /// Idle polls before a buffered turn flushes, driven by the narration-detail
    /// setting. Defaults to the Milestones value; changing it starts fresh buffers.
    var quietPolls = 15 {
        didSet { if quietPolls != oldValue { coalescers.removeAll() } }
    }
    private var attentionStates: [String: SessionAttentionState] = [:]
    private var subAgentCounts: [String: Int] = [:]

    init(
        sessionsDirectory: URL? = nil,
        archivedSessionsDirectory: URL? = nil,
        claudeProjectsDirectory: URL? = nil,
        defaults: UserDefaults = .standard
    ) {
        let codexHome = CodexPaths.home()
        self.sessionsDirectory = sessionsDirectory ?? codexHome
            .appendingPathComponent("sessions", isDirectory: true)
        self.archivedSessionsDirectory = archivedSessionsDirectory ?? codexHome
            .appendingPathComponent("archived_sessions", isDirectory: true)
        self.claudeProjectsDirectory = claudeProjectsDirectory ?? ClaudePaths.projectsDirectory()
        self.defaults = defaults
    }

    /// Watch every attached active session concurrently. A newly added session emits
    /// its latest message once; the rest stream new messages as they arrive.
    func watch(_ sessions: [CodexSessionTarget]) {
        let active = sessions.filter { $0.category == .activeSession }
        self.sessions = active
        let activeIDs = Set(active.map(\.id))
        startedSessionIDs.formIntersection(activeIDs)   // forget sessions that detached
        // Drop buffers for sessions no longer watched (avoid emitting a stale
        // mid-turn recap when they re-attach later).
        for id in coalescers.keys where !activeIDs.contains(id) { coalescers[id] = nil }
        for id in attentionStates.keys where !activeIDs.contains(id) {
            attentionStates[id] = nil
            onAttention?(id, .quiet)
        }
        for id in subAgentCounts.keys where !activeIDs.contains(id) {
            subAgentCounts[id] = nil
            onSubAgents?(id, 0)
        }

        guard !active.isEmpty else {
            timer?.invalidate(); timer = nil
            locatedFileURLs.removeAll()
            coalescers.removeAll()
            return
        }
        for session in active where !startedSessionIDs.contains(session.id) {
            pendingFragments[session.id] = nil
            coalescers[session.id] = nil   // fresh buffer for this attach
            if defaults.double(forKey: seenKey(sessionID: session.id)) > 0 {
                // Seen before (re-attach): catch up to the current end instead of
                // replaying the whole missed backlog as cards/speech. Nil offset +
                // a prior lastSeen takes the skip-history path on the next poll.
                fileOffsets[session.id] = nil
            } else {
                fileOffsets[session.id] = storedOffset(sessionID: session.id)
            }
        }
        poll()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.poll()
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sessions = []
        startedSessionIDs.removeAll()
        locatedFileURLs.removeAll()
        locateMissTick.removeAll()
        coalescers.removeAll()
    }

    private func poll() {
        pollTick &+= 1
        for session in sessions {
            let emitLatest = !startedSessionIDs.contains(session.id)
            startedSessionIDs.insert(session.id)
            pollSession(session, emitLatestOnFirstAttach: emitLatest)
        }
    }

    private func pollSession(_ session: CodexSessionTarget, emitLatestOnFirstAttach: Bool) {
        guard let fileURL = locateSessionFile(id: session.id) else {
            // No file this tick; still advance the coalescer so a buffered turn
            // eventually flushes on its quiet window.
            drainIdle(session: session)
            return
        }

        let sourceKind = sourceKind(for: fileURL)
        let format: TranscriptFormat = sourceKind == .claudeCode ? .claude : .codex

        classifyAttention(session: session, fileURL: fileURL, format: format)

        let read = newAppendedText(in: fileURL, session: session)
        let parsed = TranscriptParser.parse(
            text: read.text,
            format: format,
            carriedCWD: currentWorkingDirectories[session.id]
        )
        if let cwd = parsed.cwd { currentWorkingDirectories[session.id] = cwd }

        // On first attach, surface only the latest message as a single turn and do
        // not replay history through the coalescer.
        if read.mode == .firstFull, emitLatestOnFirstAttach {
            if let latest = parsed.records.reversed().first(where: { $0.isProse }),
               case let .assistantProse(text, _) = latest.kind {
                emit(
                    CoalescedTurn(text: text, interstitials: [], cwd: latest.cwd, timestamp: latest.timestamp),
                    session: session, fileURL: fileURL, sourceKind: sourceKind
                )
            }
            return
        }

        // After a restart with lost offset, skip the backlog (mode == .skipHistory
        // gives no text); otherwise coalesce the appended records into turns.
        let turns = coalescer(for: session.id).poll(parsed.records)
        for turn in turns {
            emit(turn, session: session, fileURL: fileURL, sourceKind: sourceKind)
        }
    }

    /// Classify the session's attention state from the transcript tail and
    /// report transitions. Reads at most the last 64 KB per poll.
    ///
    /// Nothing is recorded until `onAttention` exists: the first `watch()` can
    /// run during AppModel's init, before the handler is assigned, and a
    /// transition recorded-but-undelivered there is silently lost. A watched
    /// session that was mid-turn at launch then never reports its
    /// `.active -> .turnComplete` edge, which is exactly the edge the pet's
    /// celebration hangs off (INF-271).
    private func classifyAttention(session: CodexSessionTarget, fileURL: URL, format: TranscriptFormat) {
        guard onAttention != nil else { return }
        guard let lines = tailLines(of: fileURL, maxBytes: 65_536) else { return }
        let assessment = SessionAttentionClassifier.assess(tailLines: lines, format: format)
        if subAgentCounts[session.id] != assessment.activeSubAgents {
            subAgentCounts[session.id] = assessment.activeSubAgents
            onSubAgents?(session.id, assessment.activeSubAgents)
        }
        guard attentionStates[session.id] != assessment.state else { return }
        attentionStates[session.id] = assessment.state
        onAttention?(session.id, assessment.state)
    }

    private func tailLines(of url: URL, maxBytes: Int) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        // A mid-file start almost certainly cut the first line in half.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    /// Advance a session's coalescer with no new records so a buffered turn can
    /// flush on its quiet window even when the file is momentarily unreadable.
    private func drainIdle(session: CodexSessionTarget) {
        guard let existing = coalescers[session.id], existing.hasBufferedProse else { return }
        guard let fileURL = locatedFileURLs[session.id] ?? locateSessionFile(id: session.id) else { return }
        let sourceKind = sourceKind(for: fileURL)
        for turn in existing.poll([]) {
            emit(turn, session: session, fileURL: fileURL, sourceKind: sourceKind)
        }
    }

    private func emit(_ turn: CoalescedTurn, session: CodexSessionTarget, fileURL: URL, sourceKind: SourceKind) {
        let lastSeen = defaults.double(forKey: seenKey(sessionID: session.id))
        guard turn.timestamp.timeIntervalSince1970 > lastSeen else { return }

        var event = NormalizedEvent(
            source: sourceKind.rawValue,
            eventType: "assistant.completed",
            externalSessionID: session.id,
            projectPath: turn.cwd,
            title: session.displayTitle,
            text: turn.text
        )
        event.metadata["adapter"] = sourceKind == .claudeCode ? "claude-session-file" : "codex-session-file"
        event.metadata["codex_session_file"] = fileURL.path
        event.metadata["codex_target_category"] = session.category.rawValue
        // Source time = when the agent wrote the turn, not when we processed it, so
        // ordering and dedup use the real timeline (INF-163).
        event.metadata["source_time"] = PipelineOrdering.isoString(from: turn.timestamp)
        if let endOffset = fileSize(fileURL) {
            event.metadata["transcript_end_offset"] = String(endOffset)
        }
        event.metadata["companion_summary"] = EventNormalizer.summary(for: event)
        if !turn.interstitials.isEmpty {
            event.metadata["interstitial_count"] = String(turn.interstitials.count)
            if let data = try? JSONSerialization.data(withJSONObject: turn.interstitials),
               let json = String(data: data, encoding: .utf8) {
                event.metadata["interstitials"] = json
            }
        }
        onEvent?(event)

        defaults.set(turn.timestamp.timeIntervalSince1970, forKey: seenKey(sessionID: session.id))
        onStatus?("Observed session \(session.displayTitle).")
    }

    private func coalescer(for sessionID: String) -> NarrationCoalescer {
        if let existing = coalescers[sessionID] { return existing }
        let created = NarrationCoalescer(quietPolls: quietPolls)
        coalescers[sessionID] = created
        return created
    }

    /// How the newly appended transcript text was obtained this poll.
    private enum ReadMode { case appended, firstFull, skipHistory }
    private struct AppendedRead { let text: String; let mode: ReadMode }

    private func newAppendedText(in fileURL: URL, session: CodexSessionTarget) -> AppendedRead {
        guard let fileSize = fileSize(fileURL) else {
            return AppendedRead(text: "", mode: .appended)
        }

        if let offset = fileOffsets[session.id] {
            if fileSize < offset {
                // File truncated or rotated: reset and re-read from scratch.
                fileOffsets[session.id] = nil
                pendingFragments[session.id] = nil
                defaults.removeObject(forKey: offsetKey(sessionID: session.id))
                return newAppendedText(in: fileURL, session: session)
            }
            let text = appendedText(in: fileURL, sessionID: session.id, from: offset)
            fileOffsets[session.id] = fileSize
            storeOffset(fileSize, sessionID: session.id)
            return AppendedRead(text: text, mode: .appended)
        }

        if defaults.double(forKey: seenKey(sessionID: session.id)) > 0 {
            // Seen before but offset was lost (restart): seed the offset and skip
            // replaying the backlog.
            fileOffsets[session.id] = fileSize
            storeOffset(fileSize, sessionID: session.id)
            return AppendedRead(text: "", mode: .skipHistory)
        }

        // First attach: read only the tail, not the whole file. Real Claude Code
        // sessions reach 100MB+, and a full `String(contentsOf:)` here froze the UI
        // for seconds. We only surface the latest message on first attach, so the
        // last chunk is enough; a truncated leading line is skipped by the parser.
        let tailBytes: UInt64 = 256 * 1024
        let start = fileSize > tailBytes ? fileSize - tailBytes : 0
        let text = appendedText(in: fileURL, sessionID: session.id, from: start)
        fileOffsets[session.id] = fileSize
        storeOffset(fileSize, sessionID: session.id)
        return AppendedRead(text: text, mode: .firstFull)
    }


    private func appendedText(in fileURL: URL, sessionID: String, from offset: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return "" }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                return ""
            }
            let combined = (pendingFragments[sessionID] ?? "") + text
            guard let last = combined.last else { return "" }
            if last.isNewline {
                pendingFragments[sessionID] = nil
                return combined
            }

            let lines = combined.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            guard let lastFragment = lines.last else {
                pendingFragments[sessionID] = combined
                return ""
            }
            pendingFragments[sessionID] = String(lastFragment)
            let completeLines = lines.dropLast().map(String.init).joined(separator: "\n")
            return completeLines
        } catch {
            // Keep degrading gracefully, but leave a trail for diagnosing a
            // session that "just doesn't speak" (INF-158). No content, just the id.
            AttacheLog.watcher.error("tail read failed for session \(sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    /// A session file is Claude Code's iff it resolved under
    /// `claudeProjectsDirectory`, which itself already honors a
    /// `CLAUDE_CONFIG_DIR` override (`ClaudePaths.projectsDirectory()`). This
    /// used to be a literal `path.contains("/.claude/")` check, which broke
    /// for any override that does not itself contain that substring, e.g. a
    /// disposable test home (`/tmp/.../claude-home/projects/...`, INF-257/E2)
    /// or a real user's own `CLAUDE_CONFIG_DIR`: the file was still located
    /// correctly (`locateSessionFile` searches `claudeProjectsDirectory`), but
    /// got misclassified as Codex and parsed with the wrong transcript
    /// format, so its completed turns were silently dropped instead of
    /// becoming cards.
    ///
    /// Both sides are resolved with `resolvingSymlinksInPath()` before the
    /// prefix check: `FileManager`'s enumerator (used by `findSessionFile`)
    /// returns canonicalized paths, so a `claudeProjectsDirectory` built from
    /// a `/tmp/...` override (a symlink to `/private/tmp/...` on macOS) would
    /// otherwise never match the `/private/tmp/...` path the enumerator
    /// actually handed back, silently falling through to `.codex` even though
    /// the file was found under the right directory (INF-261).
    func sourceKind(for fileURL: URL) -> SourceKind {
        fileURL.resolvingSymlinksInPath().path.hasPrefix(claudeProjectsDirectory.resolvingSymlinksInPath().path)
            ? .claudeCode : .codex
    }

    private func fileSize(_ fileURL: URL) -> UInt64? {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? NSNumber {
            return size.uint64Value
        }
        if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return UInt64(size)
        }
        return nil
    }

    private func locateSessionFile(id: String) -> URL? {
        // The resolved file for an active session is stable, so re-validate the
        // cached URL with a cheap existence check instead of re-walking the whole
        // ~/.codex/sessions tree on every 2-second poll.
        if let cached = locatedFileURLs[id],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        // Negative cache: a session whose file is briefly missing must not trigger
        // a full three-tree walk every 2s. After a miss, hold off re-walking until
        // the re-check window elapses.
        if let missedAt = locateMissTick[id], pollTick &- missedAt < missRecheckPolls {
            return nil
        }
        let located = findSessionFile(id: id, under: sessionsDirectory)
            ?? findSessionFile(id: id, under: archivedSessionsDirectory)
            ?? findSessionFile(id: id, under: claudeProjectsDirectory)
        if let located {
            locatedFileURLs[id] = located
            locateMissTick[id] = nil
        } else {
            locatedFileURLs[id] = nil
            locateMissTick[id] = pollTick
        }
        return located
    }

    private func findSessionFile(id: String, under directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var matches: [(url: URL, modified: Date)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl",
                  fileURL.lastPathComponent.contains(id) else {
                continue
            }
            let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date(timeIntervalSince1970: 0)
            matches.append((fileURL, modified))
        }
        return matches.sorted { $0.modified > $1.modified }.first?.url
    }

    private func seenKey(sessionID: String) -> String {
        "attache.codexSessionWatcher.lastSeen.\(sessionID)"
    }

    private func offsetKey(sessionID: String) -> String {
        "attache.codexSessionWatcher.fileOffset.\(sessionID)"
    }

    private func storedOffset(sessionID: String) -> UInt64? {
        guard let value = defaults.string(forKey: offsetKey(sessionID: sessionID)),
              let offset = UInt64(value) else {
            return nil
        }
        return offset
    }

    private func storeOffset(_ offset: UInt64, sessionID: String) {
        defaults.set(String(offset), forKey: offsetKey(sessionID: sessionID))
    }
}
