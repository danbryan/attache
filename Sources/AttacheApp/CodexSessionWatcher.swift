import AttacheCore
import Foundation

final class CodexSessionWatcher {
    var onEvent: ((NormalizedEvent) -> Void)?
    var onStatus: ((String) -> Void)?
    /// Fires when a watched session's attention state changes (INF-179).
    var onAttention: ((String, SessionAttentionState, Date?) -> Void)?
    /// Fires when a watched session's live sub-agent count changes (INF-275).
    var onSubAgents: ((String, Int) -> Void)?

    /// The registered sources this watcher polls and classifies files
    /// against. Defaults to production (Codex + Claude Code) built from the
    /// explicit directory overrides below, if any; a caller (tests) can pass
    /// a full custom registry instead, e.g. to register a synthetic source
    /// and prove classification/format/watching are purely data-driven
    /// (INF-360).
    private let sourceRegistry: SessionSourceRegistry
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
    private var attentionRecordAt: [String: Date] = [:]
    private var subAgentCounts: [String: Int] = [:]

    /// Subagent tail state, keyed by `"<parent session id>::<subagent file
    /// path>"` (INF-368 Part B). Records parsed from a subagent file are fed
    /// into the PARENT's coalescer (`coalescer(for: session.id)`), so they
    /// become the same session's narration turns; they never create a
    /// separate card or session. Subagent transcripts still stay out of the
    /// session index (INF-168 stands) - only the live watcher opens them,
    /// and only for a session currently in `sessions` (watched/focused).
    private var subagentFileOffsets: [String: UInt64] = [:]
    private var subagentPendingFragments: [String: String] = [:]
    /// Bound the cost: only the 8 most-recently-modified subagent files are
    /// tailed per session, recomputed every poll (an oldest-mtime eviction).
    private let maxConcurrentSubagentTails = 8

    init(
        sessionsDirectory: URL? = nil,
        archivedSessionsDirectory: URL? = nil,
        claudeProjectsDirectory: URL? = nil,
        sourceRegistry: SessionSourceRegistry? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.sourceRegistry = sourceRegistry ?? .production(
            codexSessionsDirectory: sessionsDirectory,
            codexArchivedSessionsDirectory: archivedSessionsDirectory,
            claudeProjectsDirectory: claudeProjectsDirectory
        )
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
            attentionRecordAt[id] = nil
            onAttention?(id, .quiet, nil)
        }
        for id in subAgentCounts.keys where !activeIDs.contains(id) {
            subAgentCounts[id] = nil
            onSubAgents?(id, 0)
        }
        for key in subagentFileOffsets.keys where !activeIDs.contains(parentSessionID(fromSubagentKey: key)) {
            subagentFileOffsets[key] = nil
            subagentPendingFragments[key] = nil
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
            // A session FIRST becoming watched/focused checkpoints at the
            // transcript's CURRENT END, so only turns appended AFTER registration
            // are ever narrated or filed; a finished session focused later
            // produces no voicemail for its past turns, matching
            // OpencodeLiveWatcher (INF-397). The nil offset takes the
            // registration-checkpoint (skip-history) path on the next poll, which
            // seeds the offset at EOF and narrates nothing that already exists.
            // This unifies three symptoms that all replayed backlog before:
            // first focus of a finished session, enabling a source with existing
            // sessions, and relaunch where a stale persisted offset lagged a file
            // that grew while the app was closed. The persisted offset is
            // deliberately NOT used to seed the initial read; it lives only for
            // in-session truncation detection.
            fileOffsets[session.id] = nil
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
        subagentFileOffsets.removeAll()
        subagentPendingFragments.removeAll()
    }

    private func poll() {
        pollTick &+= 1
        for session in sessions {
            startedSessionIDs.insert(session.id)
            pollSession(session)
        }
    }

    private func pollSession(_ session: CodexSessionTarget) {
        guard let fileURL = locateSessionFile(id: session.id) else {
            // No file this tick; still advance the coalescer so a buffered turn
            // eventually flushes on its quiet window.
            drainIdle(session: session)
            return
        }

        let sourceKind = sourceKind(for: fileURL)
        // Falls back to .codex when the registry has no format for this kind
        // (only reachable with a caller-supplied registry that omits it),
        // matching the classification fallback below.
        let format = sourceRegistry.transcriptFormat(for: sourceKind) ?? .codex

        classifyAttention(session: session, fileURL: fileURL, format: format)

        let read = newAppendedText(in: fileURL, session: session)
        let parsed = TranscriptParser.parse(
            text: read.text,
            format: format,
            carriedCWD: currentWorkingDirectories[session.id]
        )
        if let cwd = parsed.cwd { currentWorkingDirectories[session.id] = cwd }

        // First registration and a lost-offset re-read both give no text
        // (mode == .skipHistory): the checkpoint jumps to the current EOF and the
        // existing backlog is never narrated. Every later poll is .appended, so
        // only turns written after registration coalesce into turns and become
        // cards. This is the file-watcher analog of OpencodeLiveWatcher's
        // "no backlog narration" (INF-397).
        let turns = coalescer(for: session.id).poll(parsed.records)
        for turn in turns {
            emit(turn, session: session, fileURL: fileURL, sourceKind: sourceKind)
        }

        // Nearly all activity happens in the parent's subagents while an
        // executor loop is mid-delegation, so tail those too, fed into the
        // SAME coalescer so they become the parent session's own narration
        // turns (INF-368 Part B). Only reachable for a session currently in
        // `sessions` (watched/focused), same as the parent tail above.
        if sourceKind == .claudeCode {
            let subagentTurns = pollSubagents(forSession: session.id, parentFileURL: fileURL)
            for turn in subagentTurns {
                emit(turn, session: session, fileURL: fileURL, sourceKind: sourceKind)
            }
        }
    }

    /// Tail the parent session's `subagents/agent-*.jsonl` files (INF-168's
    /// layout: `<claude-project>/<session-id>/subagents/agent-*.jsonl`),
    /// feeding parsed records into the parent's own `NarrationCoalescer` so
    /// they surface as that session's narration, never a separate card or
    /// session. Recomputing the 8 most-recently-modified files every poll is
    /// an oldest-mtime eviction of anything beyond the cap.
    private func pollSubagents(forSession sessionID: String, parentFileURL: URL) -> [CoalescedTurn] {
        let files = candidateSubagentFiles(forParentFileURL: parentFileURL)
        let trackedKeys = Set(files.map { subagentKey(sessionID: sessionID, fileURL: $0) })
        for key in subagentFileOffsets.keys where parentSessionID(fromSubagentKey: key) == sessionID && !trackedKeys.contains(key) {
            subagentFileOffsets[key] = nil
            subagentPendingFragments[key] = nil
        }

        var allTurns: [CoalescedTurn] = []
        // Real Claude Code subagent transcripts can also grow large; cap the
        // first read to the same 256KiB tail ceiling `newAppendedText` uses
        // for a session's own first attach, rather than replaying an
        // unbounded backlog (INF-368 Part B).
        let tailBytes: UInt64 = 256 * 1024
        for fileURL in files {
            let key = subagentKey(sessionID: sessionID, fileURL: fileURL)
            guard let size = fileSize(fileURL) else { continue }

            let previousOffset = subagentFileOffsets[key]
            let offset: UInt64
            if let previousOffset, size >= previousOffset {
                offset = previousOffset
            } else {
                offset = size > tailBytes ? size - tailBytes : 0
                subagentPendingFragments[key] = nil
            }

            let text = subagentAppendedText(in: fileURL, key: key, from: offset)
            subagentFileOffsets[key] = size
            guard !text.isEmpty else { continue }

            let parsed = TranscriptParser.parse(text: text, format: .claude, carriedCWD: currentWorkingDirectories[sessionID], includeSidechain: true)
            allTurns.append(contentsOf: coalescer(for: sessionID).poll(parsed.records))
        }
        return allTurns
    }

    /// The 8 most-recently-modified `agent-*.jsonl` files directly under the
    /// parent session's `subagents/` directory. Subagent transcripts stay
    /// out of the session index (INF-168 stands); this only feeds live
    /// narration for a session that is currently watched or focused.
    private func candidateSubagentFiles(forParentFileURL parentFileURL: URL) -> [URL] {
        let subagentsDirectory = parentFileURL.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: subagentsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let agentFiles = items.filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.lowercased().hasPrefix("agent-") }
        let withMtime = agentFiles.map { url -> (url: URL, modified: Date) in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date(timeIntervalSince1970: 0)
            return (url, modified)
        }
        return withMtime.sorted { $0.modified > $1.modified }.prefix(maxConcurrentSubagentTails).map { $0.url }
    }

    private func subagentKey(sessionID: String, fileURL: URL) -> String {
        "\(sessionID)::\(fileURL.path)"
    }

    private func parentSessionID(fromSubagentKey key: String) -> String {
        String(key.split(separator: ":", maxSplits: 1).first ?? Substring(key))
    }

    private func subagentAppendedText(in fileURL: URL, key: String, from offset: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return "" }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                return ""
            }
            let combined = (subagentPendingFragments[key] ?? "") + text
            guard let last = combined.last else { return "" }
            if last.isNewline {
                subagentPendingFragments[key] = nil
                return combined
            }

            let lines = combined.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            guard let lastFragment = lines.last else {
                subagentPendingFragments[key] = combined
                return ""
            }
            subagentPendingFragments[key] = String(lastFragment)
            return lines.dropLast().map(String.init).joined(separator: "\n")
        } catch {
            return ""
        }
    }

    /// Classify the session's attention state from the transcript tail and
    /// report transitions. Reads at most the last 64 KB per poll.
    ///
    /// Nothing is recorded until `onAttention` exists: the first `watch()` can
    /// run during AppModel's init, before the handler is assigned, and a
    /// transition recorded-but-undelivered there is silently lost. A watched
    /// session that was mid-turn at launch then never reports its
    /// `.active -> .turnComplete` edge, which is exactly the edge the character's
    /// celebration hangs off (INF-271).
    private func classifyAttention(session: CodexSessionTarget, fileURL: URL, format: TranscriptFormat) {
        guard onAttention != nil else { return }
        guard let lines = tailLines(of: fileURL, maxBytes: 65_536) else { return }
        let assessment = SessionAttentionClassifier.assess(tailLines: lines, format: format)
        if subAgentCounts[session.id] != assessment.activeSubAgents {
            subAgentCounts[session.id] = assessment.activeSubAgents
            onSubAgents?(session.id, assessment.activeSubAgents)
        }
        // Emit on a state change, and also when only the newest record moved:
        // that timestamp is how the app clears an exact hook state once the
        // transcript advances past when the hook fired.
        let sameState = attentionStates[session.id] == assessment.state
        let sameRecord = attentionRecordAt[session.id] == assessment.newestRecordAt
        guard !(sameState && sameRecord) else { return }
        attentionStates[session.id] = assessment.state
        attentionRecordAt[session.id] = assessment.newestRecordAt
        onAttention?(session.id, assessment.state, assessment.newestRecordAt)
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
        guard turn.timestamp.timeIntervalSince1970 > lastSeen else {
            AttacheLog.watcher.info(
                "dropped stale turn for session \(session.id, privacy: .public) at \(turn.timestamp.timeIntervalSince1970, privacy: .public) <= lastSeen \(lastSeen, privacy: .public)"
            )
            return
        }

        var event = NormalizedEvent(
            source: sourceKind.rawValue,
            eventType: "assistant.completed",
            externalSessionID: session.id,
            projectPath: turn.cwd,
            title: session.displayTitle,
            text: turn.text
        )
        event.metadata["adapter"] = sourceRegistry.adapterTag(for: sourceKind) ?? "codex-session-file"
        event.metadata["codex_session_file"] = fileURL.path
        event.metadata["codex_target_category"] = session.category.rawValue
        // Source time = when the agent wrote the turn, not when we processed it, so
        // ordering and dedup use the real timeline (INF-163).
        event.metadata["source_time"] = PipelineOrdering.isoString(from: turn.timestamp)
        if let endOffset = fileSize(fileURL) {
            event.metadata["transcript_end_offset"] = String(endOffset)
        }
        event.metadata["attache_summary"] = EventNormalizer.summary(for: event)
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
    private enum ReadMode { case appended, skipHistory }
    private struct AppendedRead { let text: String; let mode: ReadMode }

    private func newAppendedText(in fileURL: URL, session: CodexSessionTarget) -> AppendedRead {
        guard let fileSize = fileSize(fileURL) else {
            return AppendedRead(text: "", mode: .appended)
        }

        if let offset = fileOffsets[session.id] {
            if fileSize < offset {
                // File truncated or rotated: reset and re-checkpoint at the new
                // end rather than replaying the rotated content as backlog.
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

        // First read after registration (or after a truncation reset): checkpoint
        // at the CURRENT END of the transcript and narrate nothing that already
        // exists. Only turns appended after this point become cards, matching
        // OpencodeLiveWatcher (INF-397). Seeking straight to EOF also avoids the
        // whole-file read that once froze the UI on 100MB+ Claude sessions.
        if fileSize > 0 {
            AttacheLog.watcher.info(
                "registration skipped \(fileSize, privacy: .public) pre-registration bytes for session \(session.id, privacy: .public) (no backlog narration)"
            )
        }
        AttacheLog.watcher.info(
            "registered session \(session.id, privacy: .public) initialOffset=\(fileSize, privacy: .public) eof=\(fileSize, privacy: .public)"
        )
        fileOffsets[session.id] = fileSize
        storeOffset(fileSize, sessionID: session.id)
        return AppendedRead(text: "", mode: .skipHistory)
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

    /// Classifies a file by the longest matching directory prefix across
    /// every registered source (`SessionSourceRegistry.classify`), falling
    /// back to `.codex` when nothing matches, preserving this function's old
    /// literal `... ? .claudeCode : .codex` fallback exactly.
    ///
    /// This used to be a literal `path.contains("/.claude/")` check, which
    /// broke for any override that does not itself contain that substring,
    /// e.g. a disposable test home (`/tmp/.../claude-home/projects/...`,
    /// INF-257/E2) or a real user's own `CLAUDE_CONFIG_DIR`: the file was
    /// still located correctly, but got misclassified as Codex and parsed
    /// with the wrong transcript format, so its completed turns were
    /// silently dropped instead of becoming cards. It was then a direct
    /// `hasPrefix` check against `claudeProjectsDirectory` alone (both sides
    /// resolved with `resolvingSymlinksInPath()`, since `FileManager`'s
    /// enumerator returns canonicalized paths and a `/tmp/...` override is a
    /// symlink to `/private/tmp/...` on macOS, INF-261). The registry's
    /// `classify` does the same symlink-resolved prefix check against every
    /// registered source's directories instead of one hardcoded directory.
    func sourceKind(for fileURL: URL) -> SourceKind {
        sourceRegistry.classify(fileURL: fileURL) ?? .codex
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
        // a full walk of every watched directory every 2s. After a miss, hold off
        // re-walking until the re-check window elapses.
        if let missedAt = locateMissTick[id], pollTick &- missedAt < missRecheckPolls {
            return nil
        }
        var located: URL?
        for directory in sourceRegistry.allWatchedDirectories() {
            if let match = findSessionFile(id: id, under: directory) {
                located = match
                break
            }
        }
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
            guard fileURL.pathExtension == "jsonl", matchesSession(fileURL, id: id) else {
                continue
            }
            let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date(timeIntervalSince1970: 0)
            matches.append((fileURL, modified))
        }
        return matches.sorted { $0.modified > $1.modified }.first?.url
    }

    /// Codex and Claude Code carry the session id in the transcript's own
    /// filename, so a substring match locates them. Grok Build keeps the id on
    /// the session DIRECTORY and always names the transcript `chat_history.jsonl`
    /// (see `GrokBuildSessionScanner` and `AttacheSessionReader.locateSessionFile`),
    /// so the filename never contains the id. Match the id-named parent directory
    /// instead, and only the narratable transcript (never the sibling
    /// `events.jsonl` / `hunk_records.jsonl`). Without this branch the watcher
    /// never locates a Grok session and never narrates its turns into cards,
    /// even though two-way delivery (which uses `AttacheSessionReader`) can read
    /// the same file (INF-396).
    private func matchesSession(_ fileURL: URL, id: String) -> Bool {
        if fileURL.lastPathComponent.contains(id) { return true }
        return fileURL.lastPathComponent == "chat_history.jsonl"
            && fileURL.deletingLastPathComponent().lastPathComponent.lowercased() == id.lowercased()
    }

    private func seenKey(sessionID: String) -> String {
        "attache.codexSessionWatcher.lastSeen.\(sessionID)"
    }

    private func offsetKey(sessionID: String) -> String {
        "attache.codexSessionWatcher.fileOffset.\(sessionID)"
    }

    private func storeOffset(_ offset: UInt64, sessionID: String) {
        defaults.set(String(offset), forKey: offsetKey(sessionID: sessionID))
    }
}
