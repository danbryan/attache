import Foundation
import AttacheCore

/// Wires the agent-agnostic reply engine (INF-171) to the vendor adapters
/// (INF-172) and the app: registers the adapters, derives each session's delivery
/// readiness from stable transcript state and completed turns, drives delivery,
/// and exposes the delivery log to the UI. AppModel owns one of these.
/// Used only from the main thread (shared store isn't thread-safe);
/// `@unchecked Sendable` reflects that contract.
final class TwoWayCoordinator: ObservableObject, @unchecked Sendable {
    private let engine: InstructionReplyEngine
    private let locateSessionFile: @Sendable (String) -> URL?
    /// Loads an opencode session's DB snapshot (INF-395), or nil if the session
    /// row does not exist. opencode has no per-session transcript file to tail,
    /// so its delivery adapter, readiness, and reply correlation all route
    /// through this SQLite seam instead of `locateSessionFile`. Defaults to the
    /// real database resolved via `OpencodePaths` (honoring `XDG_DATA_HOME`).
    private let opencodeSnapshot: @Sendable (String) -> OpencodeSessionSnapshot?
    private let quietWindow: TimeInterval
    private let eventPumpDebounceInterval: TimeInterval
    private var observations: [String: SessionFileObservation] = [:]
    /// opencode's analog of `observations`: a per-session stability snapshot
    /// (latest message time + count) used to enforce the same idle-quiet
    /// window before delivering, since there is no file size/mtime to compare.
    private var opencodeObservations: [String: OpencodeObservation] = [:]
    private var pendingEventPump: DispatchWorkItem?

    /// How long a burst of watcher `onEvent` signals is debounced before it
    /// collapses to a single pump (INF-255/B4). A session writing many small
    /// transcript updates in quick succession must trigger one pump after the
    /// burst settles, not one per event. Overridable for tests, the same way
    /// `AgentResumeDeliveryAdapter.defaultProcessTimeout` and
    /// `InstructionReplyEngine.defaultExpiryWindow` document their own
    /// override seams.
    static let defaultEventPumpDebounceInterval: TimeInterval = 1

    /// Recent instructions, newest first, for the delivery-log surface.
    @Published private(set) var log: [Instruction] = []
    private(set) var startupRecoveryMessage: String?

    /// Fires once per debounced event-driven pump, with whatever that pump
    /// changed (may be empty). AppModel wires this to
    /// `handleTwoWayDeliveryChanges` so a pump triggered by watcher activity
    /// surfaces delivery/expiry the same way the periodic timer's pump does;
    /// tests count invocations to prove a burst collapses to one pump.
    var onEventDrivenPump: (([Instruction]) -> Void)?

    init(
        store: CardStore,
        locateSessionFile: @escaping @Sendable (String) -> URL?,
        opencodeSnapshot: (@Sendable (String) -> OpencodeSessionSnapshot?)? = nil,
        quietWindow: TimeInterval = 6,
        expiryWindow: TimeInterval = InstructionReplyEngine.defaultExpiryWindow,
        eventPumpDebounceInterval: TimeInterval = TwoWayCoordinator.defaultEventPumpDebounceInterval,
        adapters: [InstructionDeliveryAdapter]? = nil
    ) {
        self.engine = InstructionReplyEngine(store: store, expiryWindow: expiryWindow)
        self.locateSessionFile = locateSessionFile
        let opencodeSnapshotResolver = opencodeSnapshot ?? { sessionID in
            OpencodeSessionSnapshot.load(sessionID: sessionID, databaseURL: OpencodePaths.databaseURL())
        }
        self.opencodeSnapshot = opencodeSnapshotResolver
        self.quietWindow = quietWindow
        self.eventPumpDebounceInterval = eventPumpDebounceInterval
        let resolved = adapters ?? [
            AgentResumeDeliveryAdapter(vendor: .claude, locateSessionFile: locateSessionFile),
            AgentResumeDeliveryAdapter(vendor: .codex, locateSessionFile: locateSessionFile),
            AgentResumeDeliveryAdapter(vendor: .grok, locateSessionFile: locateSessionFile),
            OpencodeResumeDeliveryAdapter(loadSnapshot: opencodeSnapshotResolver)
        ]
        resolved.forEach { engine.register($0) }
        // Durable enablement (INF-242/B5): restore persisted per-session
        // enablement, but only for sessions whose transcript still exists -
        // the same existence check delivery already relies on. A session
        // that's been deleted or rotated away does not come back enabled.
        engine.restoreEnablement(sessionExists: { locateSessionFile($0) != nil })
        let recovered = engine.recoverInterruptedInstructions()
        if !recovered.isEmpty {
            let noun = recovered.count == 1 ? "request was" : "requests were"
            startupRecoveryMessage = "\(recovered.count) send-to-agent \(noun) interrupted when Attaché restarted. Review the frozen target and resend."
        }
        refreshLog()
    }

    // MARK: Enable / capability

    func isEnabled(sessionID: String) -> Bool { engine.isTwoWayEnabled(forSessionID: sessionID) }

    func setEnabled(_ enabled: Bool, sessionID: String) { engine.setTwoWayEnabled(enabled, forSessionID: sessionID) }

    // MARK: Submit / confirm / cancel

    /// Create a pending instruction (does not deliver). Throws twoWayDisabled or
    /// rejected(reason) so the UI can surface the reason.
    func prepare(
        text: String,
        sessionID: String,
        sourceKind: String,
        origin: InstructionOrigin = .legacy,
        sourceUtterance: String? = nil,
        targetDisplayName: String? = nil,
        workingDirectory: String? = nil,
        now: Date = Date()
    ) throws -> Instruction {
        let instruction = try engine.submit(
            text: text,
            sessionID: sessionID,
            sourceKind: sourceKind,
            now: now,
            origin: origin,
            sourceUtterance: sourceUtterance,
            targetDisplayName: targetDisplayName,
            workingDirectory: workingDirectory
        )
        primeObservation(sessionID: sessionID, sourceKind: sourceKind, now: now)
        refreshLog()
        return instruction
    }

    /// Confirm an instruction and immediately try to deliver it (delivery still
    /// waits for the session to be idle).
    @discardableResult
    func confirmAndDeliver(id: String, now: Date = Date()) async throws -> [Instruction] {
        _ = try confirm(id: id, now: now)
        return await pump(now: now)
    }

    /// Persist confirmation synchronously before any delivery task is spawned
    /// (INF-343). This gives the direct-send path a deterministic durable gate
    /// and lets callers observe `confirmedAt` immediately without sleeps.
    @discardableResult
    func confirm(id: String, now: Date = Date()) throws -> Instruction {
        let instruction = try engine.confirm(id: id, now: now)
        refreshLog()
        return instruction
    }

    func cancel(id: String) throws {
        try engine.cancel(id: id)
        refreshLog()
    }

    /// The current instruction with `id` for `sessionID`, or nil. The
    /// delivered-reply fallback (INF-396) uses this to re-read fresh state
    /// (including any card the live watcher linked meanwhile) after its grace
    /// window elapses, rather than acting on a stale captured copy.
    func instruction(id: String, sessionID: String) -> Instruction? {
        engine.instructions(forSessionID: sessionID).first { $0.id == id }
    }

    /// True while the instruction is delivered with no reply card correlated yet.
    /// The delivered-reply fallback checks this so it never double-files a card
    /// the live watcher already narrated and linked (INF-396).
    func isDeliveredAwaitingCard(instructionID: String, sessionID: String) -> Bool {
        engine.instructions(forSessionID: sessionID).contains {
            $0.id == instructionID && $0.state == .delivered && $0.resultingCardID == nil
        }
    }

    // MARK: Pump / expiry / linking (driven by AppModel on watcher signals)

    /// Deliver any confirmed instruction whose session is quiet, and expire stale
    /// ones. Call on watcher activity / the refresh timer. Returns BOTH the
    /// instructions this pump expired and the ones it delivered/failed
    /// delivering, so a caller (`AppModel.handleTwoWayDeliveryChanges`) can
    /// surface an expiry the same way it surfaces any other outcome, instead of
    /// the expiry result being silently discarded (INF-248/B3).
    @discardableResult
    func pump(now: Date = Date()) async -> [Instruction] {
        let expired = engine.expireStale(now: now)
        let delivered = await engine.deliverReadyInstructions(
            instructionIsReady: { [weak self] instruction in
                self?.instructionIsReady(instruction, now: now) ?? false
            },
            now: now
        )
        refreshLog()
        return expired + delivered
    }

    /// Debounced entry point for the watcher's `onEvent` callback (INF-255/B4).
    /// Session file activity observed by the watcher no longer waits for the
    /// next periodic refresh timer tick: it schedules a pump after
    /// `eventPumpDebounceInterval` settles, canceling any pump already
    /// scheduled by an earlier event in the same burst so a run of rapid
    /// events collapses to exactly one pump instead of one per event. This is
    /// in ADDITION to the periodic timer, which stays as a backstop for a
    /// session that goes quiet without any further watcher event to trigger
    /// this path (e.g. a session that was already idle). Delegates to the
    /// same `pump(now:)` used everywhere else, so quiet-window and expiry
    /// semantics are unchanged; this only removes sampling latency.
    func scheduleEventDrivenPump() {
        pendingEventPump?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                let changed = await self.pump()
                self.onEventDrivenPump?(changed)
            }
        }
        pendingEventPump = work
        DispatchQueue.main.asyncAfter(deadline: .now() + eventPumpDebounceInterval, execute: work)
    }

    /// Link a freshly-narrated card to the delivered instruction whose reply it
    /// is. Correlation is positional first (INF-245/B2): the first completed
    /// assistant turn found after an instruction's delivery checkpoint belongs
    /// to it, regardless of whether the narrated card carries presentation-
    /// rewritten (paraphrased) text that doesn't match the raw transcript
    /// verbatim. Exact text equality is checked only as a secondary confidence
    /// signal and never blocks a positional match. B1's captured delivery
    /// evidence (`deliveryReplyText`/`deliveryReplyTurnID`) is a second
    /// cross-check: when the transcript slice doesn't show a completed turn yet
    /// (the watcher can lag the delivery), that synchronously-captured evidence
    /// still proves the turn happened and unblocks the link. Every miss for a
    /// session with an outstanding delivered instruction logs a warning with the
    /// reason, so a correlation failure is never silent.
    func linkResponseCard(
        cardID: String,
        sessionID: String,
        eventText: String,
        transcriptEndOffset: Int64?
    ) {
        let delivered = engine.instructions(forSessionID: sessionID)
            .filter { $0.state == .delivered && $0.resultingCardID == nil }
            .sorted { $0.deliveredAt ?? .distantPast < $1.deliveredAt ?? .distantPast }
        guard !delivered.isEmpty else { return }  // no outstanding two-way reply expected for this session

        // opencode (INF-395): no transcript file / byte offset. Route correlation
        // through the SQLite positional path (a session is one source, so all
        // its outstanding instructions share it). The JSONL path below is
        // byte-identical for every other source.
        if delivered.contains(where: { SourceKind(rawValue: $0.sourceKind) == .opencode }) {
            linkOpencodeResponseCard(cardID: cardID, sessionID: sessionID, eventText: eventText, delivered: delivered)
            return
        }

        guard let transcriptEndOffset else {
            AttacheLog.twoWay.warning("Correlation skipped for card \(cardID, privacy: .public) in session \(sessionID, privacy: .public): event carried no transcript end offset.")
            return
        }
        let fileURL = locateSessionFile(sessionID)
        if fileURL == nil {
            AttacheLog.twoWay.warning("Correlation failed for card \(cardID, privacy: .public) in session \(sessionID, privacy: .public): could not locate the session transcript file.")
        }

        for target in delivered {
            guard let checkpoint = target.deliveryCheckpoint, checkpoint < transcriptEndOffset else { continue }
            guard let format = transcriptFormat(for: target.sourceKind) else {
                AttacheLog.twoWay.warning("Correlation failed for instruction \(target.id, privacy: .public): unrecognized source kind \(target.sourceKind, privacy: .public).")
                continue
            }

            let positionalReply = fileURL
                .flatMap { transcriptSlice(fileURL: $0, from: checkpoint, through: transcriptEndOffset) }
                .flatMap { SessionReplyCorrelation.firstCompletedAssistantTurn(transcriptText: $0, format: format) }

            var reply = positionalReply
            var confirmedBy = "position"
            if reply == nil, let evidence = target.deliveryReplyText {
                // The transcript watcher can lag the delivery adapter, which
                // already captured proof of a completed turn synchronously from
                // the resume's own stdout (B1/INF-238). Fall back to that
                // evidence instead of waiting for the next transcript poll.
                reply = evidence
                confirmedBy = "delivery-evidence"
            }
            guard let reply else { continue }

            let textConfirmed = SessionReplyCorrelation.textConfirms(eventText: eventText, replyText: reply)
            engine.linkResponse(instructionID: target.id, cardID: cardID)
            AttacheLog.twoWay.info("""
                Linked card \(cardID, privacy: .public) to instruction \(target.id, privacy: .public) via \
                \(confirmedBy, privacy: .public) (checkpoint \(checkpoint) < offset \(transcriptEndOffset)); \
                exact-text confirms: \(textConfirmed), has turn id: \(target.deliveryReplyTurnID != nil).
                """)
            refreshLog()
            return
        }
        AttacheLog.twoWay.warning("Correlation miss for card \(cardID, privacy: .public) in session \(sessionID, privacy: .public): no outstanding delivered instruction's window (through offset \(transcriptEndOffset)) shows a completed reply yet.")
    }

    private func instructionIsReady(_ instruction: Instruction, now: Date) -> Bool {
        if SourceKind(rawValue: instruction.sourceKind) == .opencode {
            return opencodeInstructionIsReady(instruction, now: now)
        }
        guard let current = observation(sessionID: instruction.sessionID, now: now),
              let format = transcriptFormat(for: instruction.sourceKind) else { return false }
        let previous = observations[instruction.sessionID]
        if previous?.hasSameFileState(as: current) != true {
            observations[instruction.sessionID] = current
            return false
        }
        return SessionDeliveryReadinessClassifier.isReady(
            previous: previous,
            current: current,
            format: format,
            now: now,
            quietWindow: quietWindow
        )
    }

    private func primeObservation(sessionID: String, sourceKind: String, now: Date) {
        // Source-aware so a file source never opens the opencode database and
        // opencode never scans the file transcript trees.
        if SourceKind(rawValue: sourceKind) == .opencode {
            if let messages = opencodeSnapshot(sessionID)?.messages {
                opencodeObservations[sessionID] = OpencodeObservation(messages: messages, observedAt: now)
            }
        } else if let snapshot = observation(sessionID: sessionID, now: now) {
            observations[sessionID] = snapshot
        }
    }

    /// opencode readiness (INF-395): the SQLite analog of the file path above.
    /// It enforces the same two-observation idle-quiet window (the latest
    /// message must be unchanged across `quietWindow` and older than it) and
    /// then defers the "completed assistant turn, no pending tool parts" call
    /// to the pure `OpencodeDeliveryReadiness`.
    private func opencodeInstructionIsReady(_ instruction: Instruction, now: Date) -> Bool {
        guard let snapshot = opencodeSnapshot(instruction.sessionID) else { return false }
        let current = OpencodeObservation(messages: snapshot.messages, observedAt: now)
        let previous = opencodeObservations[instruction.sessionID]
        if previous?.hasSameState(as: current) != true {
            opencodeObservations[instruction.sessionID] = current
            return false
        }
        guard let previous, now.timeIntervalSince(previous.observedAt) >= quietWindow else { return false }
        if current.latestTimeCreatedMillis > 0 {
            let latestSeconds = Double(current.latestTimeCreatedMillis) / 1000
            guard now.timeIntervalSince1970 - latestSeconds >= quietWindow else { return false }
        }
        return OpencodeDeliveryReadiness.isReady(messages: snapshot.messages)
    }

    /// SQLite positional correlation for opencode (INF-395), the analog of the
    /// file path's transcript-slice scan. The first completed assistant turn
    /// after each outstanding instruction's delivery checkpoint is its reply;
    /// the adapter's captured `deliveryReplyText` is the same fallback the file
    /// path uses when the DB read hasn't caught up yet.
    private func linkOpencodeResponseCard(cardID: String, sessionID: String, eventText: String, delivered: [Instruction]) {
        let snapshot = opencodeSnapshot(sessionID)
        if snapshot == nil {
            AttacheLog.twoWay.warning("Correlation for card \(cardID, privacy: .public) in opencode session \(sessionID, privacy: .public): no session snapshot; using delivery evidence if present.")
        }
        for target in delivered {
            guard let checkpoint = target.deliveryCheckpoint else { continue }
            let positionalReply = snapshot.flatMap {
                OpencodeReplyCorrelation.firstCompletedAssistantTurn(messages: $0.messages, afterCheckpoint: checkpoint)?.text
            }
            var reply = positionalReply
            var confirmedBy = "sqlite-position"
            if reply == nil, let evidence = target.deliveryReplyText {
                reply = evidence
                confirmedBy = "delivery-evidence"
            }
            guard let reply else { continue }
            let textConfirmed = SessionReplyCorrelation.textConfirms(eventText: eventText, replyText: reply)
            engine.linkResponse(instructionID: target.id, cardID: cardID)
            AttacheLog.twoWay.info("""
                Linked card \(cardID, privacy: .public) to opencode instruction \(target.id, privacy: .public) via \
                \(confirmedBy, privacy: .public) (checkpoint \(checkpoint)); exact-text confirms: \(textConfirmed).
                """)
            refreshLog()
            return
        }
        AttacheLog.twoWay.warning("Correlation miss for card \(cardID, privacy: .public) in opencode session \(sessionID, privacy: .public): no outstanding delivered instruction shows a completed reply yet.")
    }

    /// The authoritative reply text for a delivered opencode instruction: the
    /// first completed assistant turn after its checkpoint, read from the DB.
    /// `AppModel` narrates this (opencode has no live watcher to surface the
    /// reply as a card), then correlation links that card back here.
    func opencodeReplyText(forInstruction instruction: Instruction) -> String? {
        guard SourceKind(rawValue: instruction.sourceKind) == .opencode,
              let checkpoint = instruction.deliveryCheckpoint,
              let snapshot = opencodeSnapshot(instruction.sessionID) else { return nil }
        return OpencodeReplyCorrelation.firstCompletedAssistantTurn(
            messages: snapshot.messages, afterCheckpoint: checkpoint
        )?.text
    }

    private func observation(sessionID: String, now: Date) -> SessionFileObservation? {
        guard let url = locateSessionFile(sessionID),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modifiedAt = values.contentModificationDate,
              let lines = tailLines(of: url, maxBytes: 128 * 1024) else { return nil }
        return SessionFileObservation(size: Int64(size), modifiedAt: modifiedAt, observedAt: now, tailLines: lines)
    }

    /// Registry-driven (INF-360): an unrecognized raw value, or a recognized
    /// `SourceKind` the registry has no descriptor for, both fall through to
    /// nil, preserving the old fail-safe (two-way delivery refuses an
    /// unrecognized source) exactly.
    private func transcriptFormat(for sourceKind: String) -> TranscriptFormat? {
        guard let kind = SourceKind(rawValue: sourceKind) else { return nil }
        return SessionSourceRegistry.production().transcriptFormat(for: kind)
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
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    private func transcriptSlice(fileURL: URL, from start: Int64, through end: Int64) -> String? {
        guard start >= 0, end > start, end - start <= 4 * 1024 * 1024,
              let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(start))
            let data = try handle.read(upToCount: Int(end - start)) ?? Data()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func refreshLog() { log = engine.log() }
}
