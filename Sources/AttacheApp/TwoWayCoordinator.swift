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
    private let quietWindow: TimeInterval
    private var observations: [String: SessionFileObservation] = [:]

    /// Recent instructions, newest first, for the delivery-log surface.
    @Published private(set) var log: [Instruction] = []
    private(set) var startupRecoveryMessage: String?

    init(
        store: CardStore,
        locateSessionFile: @escaping @Sendable (String) -> URL?,
        quietWindow: TimeInterval = 6,
        adapters: [InstructionDeliveryAdapter]? = nil
    ) {
        self.engine = InstructionReplyEngine(store: store)
        self.locateSessionFile = locateSessionFile
        self.quietWindow = quietWindow
        let resolved = adapters ?? [
            AgentResumeDeliveryAdapter(vendor: .claude, locateSessionFile: locateSessionFile),
            AgentResumeDeliveryAdapter(vendor: .codex, locateSessionFile: locateSessionFile)
        ]
        resolved.forEach { engine.register($0) }
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
        now: Date = Date()
    ) throws -> Instruction {
        let instruction = try engine.submit(
            text: text,
            sessionID: sessionID,
            sourceKind: sourceKind,
            now: now,
            origin: origin,
            sourceUtterance: sourceUtterance,
            targetDisplayName: targetDisplayName
        )
        primeObservation(sessionID: sessionID, now: now)
        refreshLog()
        return instruction
    }

    /// Confirm an instruction and immediately try to deliver it (delivery still
    /// waits for the session to be idle).
    @discardableResult
    func confirmAndDeliver(id: String, now: Date = Date()) async throws -> [Instruction] {
        _ = try engine.confirm(id: id, now: now)
        refreshLog()
        return await pump(now: now)
    }

    func cancel(id: String) throws {
        try engine.cancel(id: id)
        refreshLog()
    }

    // MARK: Pump / expiry / linking (driven by AppModel on watcher signals)

    /// Deliver any confirmed instruction whose session is quiet, and expire stale
    /// ones. Call on watcher activity / the refresh timer.
    @discardableResult
    func pump(now: Date = Date()) async -> [Instruction] {
        _ = engine.expireStale(now: now)
        let changed = await engine.deliverReadyInstructions(
            instructionIsReady: { [weak self] instruction in
                self?.instructionIsReady(instruction, now: now) ?? false
            },
            now: now
        )
        refreshLog()
        return changed
    }

    /// Link a freshly-narrated card only when the transcript after the delivery
    /// checkpoint proves the resumed user turn and its completed assistant reply.
    func linkResponseCard(
        cardID: String,
        sessionID: String,
        eventText: String,
        transcriptEndOffset: Int64?
    ) {
        guard let transcriptEndOffset,
              let fileURL = locateSessionFile(sessionID) else { return }
        let delivered = engine.instructions(forSessionID: sessionID)
            .filter { $0.state == .delivered && $0.resultingCardID == nil }
            .sorted { $0.deliveredAt ?? .distantPast < $1.deliveredAt ?? .distantPast }
        for target in delivered {
            guard let checkpoint = target.deliveryCheckpoint,
                  checkpoint < transcriptEndOffset,
                  let transcript = transcriptSlice(
                    fileURL: fileURL,
                    from: checkpoint,
                    through: transcriptEndOffset
                  ),
                  let format = transcriptFormat(for: target.sourceKind),
                  SessionReplyCorrelation.matches(
                    instructionText: target.text,
                    eventText: eventText,
                    transcriptText: transcript,
                    format: format
                  ) else { continue }
            engine.linkResponse(instructionID: target.id, cardID: cardID)
            refreshLog()
            return
        }
    }

    private func instructionIsReady(_ instruction: Instruction, now: Date) -> Bool {
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

    private func primeObservation(sessionID: String, now: Date) {
        if let snapshot = observation(sessionID: sessionID, now: now) {
            observations[sessionID] = snapshot
        }
    }

    private func observation(sessionID: String, now: Date) -> SessionFileObservation? {
        guard let url = locateSessionFile(sessionID),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modifiedAt = values.contentModificationDate,
              let lines = tailLines(of: url, maxBytes: 128 * 1024) else { return nil }
        return SessionFileObservation(size: Int64(size), modifiedAt: modifiedAt, observedAt: now, tailLines: lines)
    }

    private func transcriptFormat(for sourceKind: String) -> TranscriptFormat? {
        switch SourceKind(rawValue: sourceKind) {
        case .codex: return .codex
        case .claudeCode: return .claude
        default: return nil
        }
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
