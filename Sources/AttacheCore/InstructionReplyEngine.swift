import Foundation

public enum InstructionError: Error, Equatable {
    case twoWayDisabled
    case rejected(String)
    case notFound
    case notConfirmable(InstructionState)
    case notCancelable
}

/// The agent-agnostic core of two-way (docs/two-way.md, INF-159). It owns the
/// instruction lifecycle between "user confirmed" and "an adapter delivered it":
/// the per-session enable gate, the safety filter, confirmation, single-flight
/// FIFO queue-until-idle delivery, expiry, and the audit log. It knows nothing
/// about vendors; delivery goes through registered `InstructionDeliveryAdapter`s.
///
/// Used only from the main thread (the store it shares with the app is not
/// thread-safe); the only suspension point is `adapter.deliver`, whose caller
/// keeps it on the main actor. Marked `@unchecked Sendable` to reflect that
/// main-only contract rather than static isolation.
public final class InstructionReplyEngine: @unchecked Sendable {
    private let store: CardStore
    private let idGenerator: () -> String
    private var adapters: [String: InstructionDeliveryAdapter] = [:]
    private var enabledSessions: Set<String> = []
    private var submittedSnapshots: [String: Instruction] = [:]

    /// How long a confirmed/pending instruction may wait before it is failed as
    /// expired rather than firing much later.
    public var expiryWindow: TimeInterval

    public init(
        store: CardStore,
        expiryWindow: TimeInterval = 30 * 60,
        idGenerator: @escaping () -> String = { UUID().uuidString }
    ) {
        self.store = store
        self.expiryWindow = expiryWindow
        self.idGenerator = idGenerator
    }

    // MARK: Adapters

    public func register(_ adapter: InstructionDeliveryAdapter) {
        adapters[adapter.sourceKind] = adapter
    }

    // MARK: Per-session enable (off by default)

    public func isTwoWayEnabled(forSessionID sessionID: String) -> Bool {
        enabledSessions.contains(sessionID)
    }

    public func setTwoWayEnabled(_ enabled: Bool, forSessionID sessionID: String) {
        if enabled { enabledSessions.insert(sessionID) } else { enabledSessions.remove(sessionID) }
    }

    // MARK: Submit / confirm / cancel

    /// Create a pending instruction. Fails closed if two-way is off for the session
    /// or the text is an agent-side approval. Nothing is delivered here.
    @discardableResult
    public func submit(
        text: String,
        sessionID: String,
        sourceKind: String,
        now: Date,
        origin: InstructionOrigin = .legacy,
        sourceUtterance: String? = nil,
        targetDisplayName: String? = nil
    ) throws -> Instruction {
        guard isTwoWayEnabled(forSessionID: sessionID) else { throw InstructionError.twoWayDisabled }
        if let reason = InstructionSafetyFilter.rejectionReason(for: text) {
            throw InstructionError.rejected(reason)
        }
        let instruction = Instruction(
            id: idGenerator(),
            sessionID: sessionID,
            sourceKind: sourceKind,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            state: .pending,
            createdAt: now,
            origin: origin,
            sourceUtterance: sourceUtterance,
            targetDisplayName: targetDisplayName
        )
        try store.upsertInstruction(instruction)
        submittedSnapshots[instruction.id] = instruction
        return instruction
    }

    /// The confirmation gate: only a pending instruction can be confirmed, and
    /// only a confirmed instruction is ever delivered.
    @discardableResult
    public func confirm(id: String, now: Date) throws -> Instruction {
        guard var instruction = try store.fetchInstruction(id: id) else { throw InstructionError.notFound }
        guard instruction.state == .pending else { throw InstructionError.notConfirmable(instruction.state) }
        instruction.state = .confirmed
        instruction.confirmedAt = now
        try store.upsertInstruction(instruction)
        return instruction
    }

    public func cancel(id: String) throws {
        guard var instruction = try store.fetchInstruction(id: id) else { throw InstructionError.notFound }
        guard !instruction.isTerminal, instruction.state != .delivering else { throw InstructionError.notCancelable }
        instruction.state = .canceled
        try store.upsertInstruction(instruction)
        submittedSnapshots.removeValue(forKey: id)
    }

    // MARK: Delivery

    /// Deliver whatever is ready: for each session with a confirmed instruction,
    /// if the transcript is safe to resume and no delivery is already in flight,
    /// deliver the oldest one (FIFO, single-flight per session). Returns the
    /// instructions whose state changed.
    @discardableResult
    public func deliverReadyInstructions(
        instructionIsReady: (Instruction) -> Bool,
        now: Date
    ) async -> [Instruction] {
        let confirmed = (try? store.fetchInstructions(inStates: [.confirmed])) ?? []
        let alreadyDelivering = Set(((try? store.fetchInstructions(inStates: [.delivering])) ?? []).map(\.sessionID))
        var handledSessions = alreadyDelivering
        var changed: [Instruction] = []

        for instruction in confirmed {   // created_at ASC = FIFO
            let session = instruction.sessionID
            guard !handledSessions.contains(session) else { continue }  // one per session per pump
            handledSessions.insert(session)

            guard let snapshot = submittedSnapshots[instruction.id],
                  Self.hasSameFrozenDeliveryContent(instruction, snapshot) else {
                changed.append(markFailed(
                    instruction,
                    error: "The stored instruction or target changed before delivery. Review and resend."
                ))
                continue
            }

            guard let adapter = adapters[instruction.sourceKind] else {
                changed.append(markFailed(instruction, error: "No delivery adapter for \(instruction.sourceKind)."))
                continue
            }
            let capability = adapter.capability(forSessionID: session)
            guard capability.canDeliver else {
                changed.append(markFailed(instruction, error: capability.reason ?? "Delivery unavailable."))
                continue
            }
            if capability.requiresIdle && !instructionIsReady(instruction) { continue }

            // Persist single-flight before the async gap so a concurrent pump sees it.
            var inFlight = instruction
            inFlight.state = .delivering
            try? store.upsertInstruction(inFlight)

            switch await adapter.deliver(inFlight) {
            case .success(let receipt):
                inFlight.state = .delivered
                inFlight.deliveredAt = now
                inFlight.deliveryMechanism = receipt.mechanism
                inFlight.deliveryCheckpoint = receipt.transcriptCheckpoint
                inFlight.error = nil
            case .failure(let error):
                inFlight.state = .failed
                inFlight.error = Self.describe(error)
            }
            try? store.upsertInstruction(inFlight)
            submittedSnapshots.removeValue(forKey: inFlight.id)
            changed.append(inFlight)
        }
        return changed
    }

    /// Compatibility seam for callers that only have a session-level idle signal.
    @discardableResult
    public func deliverReadyInstructions(sessionIsIdle: (String) -> Bool, now: Date) async -> [Instruction] {
        await deliverReadyInstructions(instructionIsReady: { sessionIsIdle($0.sessionID) }, now: now)
    }

    /// A previous process cannot prove whether a persisted nonterminal instruction
    /// was delivered. Fail it closed so relaunch never duplicates or surprises.
    @discardableResult
    public func recoverInterruptedInstructions() -> [Instruction] {
        let interrupted = (try? store.fetchInstructions(inStates: [.pending, .confirmed, .delivering])) ?? []
        return interrupted.map {
            markFailed($0, error: "Attaché restarted before delivery completed. Review the target and resend.")
        }
    }

    /// Fail any pending/confirmed instruction older than the expiry window, so an
    /// undeliverable instruction doesn't fire hours later.
    @discardableResult
    public func expireStale(now: Date) -> [Instruction] {
        let candidates = (try? store.fetchInstructions(inStates: [.pending, .confirmed])) ?? []
        var expired: [Instruction] = []
        for instruction in candidates where now.timeIntervalSince(instruction.createdAt) > expiryWindow {
            expired.append(markFailed(instruction, error: "Expired before it could be delivered."))
        }
        return expired
    }

    /// Link the narration card the agent produced in reply, for the audit log.
    public func linkResponse(instructionID: String, cardID: String) {
        guard var instruction = try? store.fetchInstruction(id: instructionID) else { return }
        instruction.resultingCardID = cardID
        try? store.upsertInstruction(instruction)
    }

    // MARK: Log

    public func log(limit: Int = 100) -> [Instruction] {
        (try? store.fetchInstructionLog(limit: limit)) ?? []
    }

    public func instructions(forSessionID sessionID: String) -> [Instruction] {
        (try? store.fetchInstructions(forSessionID: sessionID)) ?? []
    }

    // MARK: Helpers

    @discardableResult
    private func markFailed(_ instruction: Instruction, error: String) -> Instruction {
        var failed = instruction
        failed.state = .failed
        failed.error = error
        try? store.upsertInstruction(failed)
        submittedSnapshots.removeValue(forKey: instruction.id)
        return failed
    }

    private static func hasSameFrozenDeliveryContent(_ persisted: Instruction, _ snapshot: Instruction) -> Bool {
        persisted.id == snapshot.id
            && persisted.sessionID == snapshot.sessionID
            && persisted.sourceKind == snapshot.sourceKind
            && persisted.text == snapshot.text
            && persisted.origin == snapshot.origin
            && persisted.sourceUtterance == snapshot.sourceUtterance
            && persisted.targetDisplayName == snapshot.targetDisplayName
    }

    private static func describe(_ error: InstructionDeliveryError) -> String {
        switch error {
        case .notDeliverable(let reason): return "Not deliverable: \(reason)"
        case .sessionGone: return "The target session was deleted or archived."
        case .deliveryFailed(let reason): return "Delivery failed: \(reason)"
        }
    }
}
