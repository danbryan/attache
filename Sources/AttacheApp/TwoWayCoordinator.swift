import Foundation
import AttacheCore

/// Wires the agent-agnostic reply engine (INF-171) to the vendor adapters
/// (INF-172) and the app: registers the adapters, derives each session's idle
/// state from the transcript file's activity, drives delivery when a session goes
/// quiet, and exposes the delivery log to the UI. AppModel owns one of these.
/// Used only from the main thread (shared store isn't thread-safe);
/// `@unchecked Sendable` reflects that contract.
final class TwoWayCoordinator: ObservableObject, @unchecked Sendable {
    private let engine: InstructionReplyEngine
    private let locateSessionFile: @Sendable (String) -> URL?
    private let quietWindow: TimeInterval

    /// Recent instructions, newest first, for the delivery-log surface.
    @Published private(set) var log: [Instruction] = []

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
        refreshLog()
    }

    // MARK: Enable / capability

    func isEnabled(sessionID: String) -> Bool { engine.isTwoWayEnabled(forSessionID: sessionID) }

    func setEnabled(_ enabled: Bool, sessionID: String) { engine.setTwoWayEnabled(enabled, forSessionID: sessionID) }

    // MARK: Submit / confirm / cancel

    /// Create a pending instruction (does not deliver). Throws twoWayDisabled or
    /// rejected(reason) so the UI can surface the reason.
    func prepare(text: String, sessionID: String, sourceKind: String, now: Date = Date()) throws -> Instruction {
        let instruction = try engine.submit(text: text, sessionID: sessionID, sourceKind: sourceKind, now: now)
        refreshLog()
        return instruction
    }

    /// Confirm an instruction and immediately try to deliver it (delivery still
    /// waits for the session to be idle).
    func confirmAndDeliver(id: String, now: Date = Date()) async throws {
        _ = try engine.confirm(id: id, now: now)
        refreshLog()
        await pump(now: now)
    }

    func cancel(id: String) throws {
        try engine.cancel(id: id)
        refreshLog()
    }

    // MARK: Pump / expiry / linking (driven by AppModel on watcher signals)

    /// Deliver any confirmed instruction whose session is quiet, and expire stale
    /// ones. Call on watcher activity / the refresh timer.
    func pump(now: Date = Date()) async {
        _ = engine.expireStale(now: now)
        _ = await engine.deliverReadyInstructions(
            sessionIsIdle: { [weak self] sessionID in self?.sessionIsIdle(sessionID, now: now) ?? false },
            now: now
        )
        refreshLog()
    }

    /// Link a freshly-narrated card to the most recent delivered instruction for
    /// its session, so the log can jump to the agent's reply.
    func linkResponseCard(cardID: String, sessionID: String) {
        let delivered = engine.instructions(forSessionID: sessionID)
            .filter { $0.state == .delivered && $0.resultingCardID == nil }
        guard let target = delivered.max(by: { $0.deliveredAt ?? .distantPast < $1.deliveredAt ?? .distantPast }) else {
            return
        }
        engine.linkResponse(instructionID: target.id, cardID: cardID)
        refreshLog()
    }

    /// True when the session's transcript file hasn't been appended to for the
    /// quiet window (matches docs/two-way.md's idle definition).
    private func sessionIsIdle(_ sessionID: String, now: Date) -> Bool {
        guard let url = locateSessionFile(sessionID) else { return false }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        return SessionActivityClassifier.isIdle(lastModified: modified, now: now, quietWindow: quietWindow)
    }

    private func refreshLog() { log = engine.log() }
}
