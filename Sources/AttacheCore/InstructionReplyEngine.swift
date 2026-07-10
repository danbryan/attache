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
    /// Fast in-memory cache of two-way-enabled sessions, backed by the
    /// persisted `two_way_enablement` table (INF-242/B5): loaded from `store`
    /// in `init` and kept in sync by `setTwoWayEnabled`, so the hot
    /// `isTwoWayEnabled` read path never touches SQLite.
    private var enabledSessions: Set<String>
    private var submittedSnapshots: [String: Instruction] = [:]

    /// Default `expiryWindow` (docs/two-way.md: "Instructions expire (fail)
    /// after a bounded window (default 30 minutes)"). Exposed so callers that
    /// only have a session-level coordinator (`TwoWayCoordinator`) can still
    /// reference the production default when overriding it for a fast-expiry
    /// test, the same way `AgentResumeDeliveryAdapter.defaultProcessTimeout`
    /// documents its own override seam (INF-248/B3).
    public static let defaultExpiryWindow: TimeInterval = 30 * 60

    /// How long a confirmed/pending instruction may wait before it is failed as
    /// expired rather than firing much later.
    public var expiryWindow: TimeInterval

    /// Default `deliveringStrandTimeout`: slightly longer than
    /// `AgentResumeDeliveryAdapter.defaultProcessTimeout` (5 minutes, INF-248/B1)
    /// since a real delivery attempt should never legitimately run longer than
    /// that adapter-level timeout. Anything still `.delivering` past this window
    /// is presumed stuck (a bug, an adapter call that never returned despite
    /// B1's timeout, or a crash-recovered scenario the engine hasn't seen) and
    /// is failed at runtime by `deliverReadyInstructions`, not just at the next
    /// app launch (INF-249/B6).
    public static let defaultDeliveringStrandTimeout: TimeInterval = 6 * 60

    /// How long a `.delivering` instruction may sit without a terminal result
    /// before the runtime backstop (as opposed to startup's
    /// `recoverInterruptedInstructions`) fails it closed.
    public var deliveringStrandTimeout: TimeInterval

    public init(
        store: CardStore,
        expiryWindow: TimeInterval = InstructionReplyEngine.defaultExpiryWindow,
        deliveringStrandTimeout: TimeInterval = InstructionReplyEngine.defaultDeliveringStrandTimeout,
        idGenerator: @escaping () -> String = { UUID().uuidString }
    ) {
        self.store = store
        self.expiryWindow = expiryWindow
        self.deliveringStrandTimeout = deliveringStrandTimeout
        self.idGenerator = idGenerator
        // Durable enablement (INF-242/B5): a fresh engine pointed at the same
        // SQLite file restores whatever was persisted, instead of every
        // session starting off. `restoreEnablement` below then prunes any
        // session whose transcript no longer exists.
        self.enabledSessions = Set((try? store.fetchEnabledSessionIDs()) ?? [])
    }

    // MARK: Adapters

    public func register(_ adapter: InstructionDeliveryAdapter) {
        adapters[adapter.sourceKind] = adapter
    }

    // MARK: Per-session enable (off by default, persisted; docs/two-way.md, INF-242/B5)

    public func isTwoWayEnabled(forSessionID sessionID: String) -> Bool {
        enabledSessions.contains(sessionID)
    }

    /// Enabling/disabling is durable: it is written through to the
    /// `two_way_enablement` table so a relaunch's fresh engine (see `init`)
    /// restores it. This replaces the former memory-only gate; restart still
    /// fails in-flight instructions closed (`recoverInterruptedInstructions`),
    /// which is unrelated and unchanged.
    public func setTwoWayEnabled(_ enabled: Bool, forSessionID sessionID: String) {
        if enabled {
            enabledSessions.insert(sessionID)
            try? store.setTwoWayEnabled(sessionID: sessionID, enabledAt: Date())
        } else {
            enabledSessions.remove(sessionID)
            try? store.clearTwoWayEnabled(sessionID: sessionID)
        }
    }

    /// Startup-only: prune persisted enablement for any session whose
    /// transcript no longer exists, so a deleted or rotated-away session
    /// cannot silently come back enabled just because its row survived in
    /// SQLite (docs/two-way.md, "Off by default, per session"; INF-242/B5).
    /// The core knows nothing about vendor session files, so the caller
    /// supplies the existence check; `TwoWayCoordinator` calls this once at
    /// init with the same `locateSessionFile` it already uses for delivery.
    /// Stale rows are cleaned up eagerly here (deleted from
    /// `two_way_enablement`), not left for a lazy pass later. Returns the
    /// pruned session ids.
    @discardableResult
    public func restoreEnablement(sessionExists: (String) -> Bool) -> [String] {
        let stale = enabledSessions.filter { !sessionExists($0) }
        for sessionID in stale {
            enabledSessions.remove(sessionID)
            try? store.clearTwoWayEnabled(sessionID: sessionID)
        }
        return Array(stale)
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
    ///
    /// Also runs the runtime strand-recovery backstop (INF-249/B6): any
    /// `.delivering` instruction older than `deliveringStrandTimeout` is failed
    /// here, during normal pump operation, rather than only at the next app
    /// launch (`recoverInterruptedInstructions`, which stays fail-closed and
    /// unchanged).
    @discardableResult
    public func deliverReadyInstructions(
        instructionIsReady: (Instruction) -> Bool,
        now: Date
    ) async -> [Instruction] {
        let confirmed = (try? store.fetchInstructions(inStates: [.confirmed])) ?? []
        let delivering = (try? store.fetchInstructions(inStates: [.delivering])) ?? []
        var changed: [Instruction] = []

        // Runtime strand recovery: a `.delivering` instruction stuck past the
        // timeout is presumed dead and failed closed; a session it frees up can
        // then take its next confirmed instruction in this same pump.
        var handledSessions: Set<String> = []
        for instruction in delivering {
            let since = instruction.deliveringAt ?? instruction.confirmedAt ?? instruction.createdAt
            if now.timeIntervalSince(since) > deliveringStrandTimeout {
                changed.append(markFailed(instruction, error: Self.strandedDeliveryMessage(
                    timeout: deliveringStrandTimeout,
                    target: instruction.targetDisplayName
                )))
            } else {
                handledSessions.insert(instruction.sessionID)  // genuinely still in flight
            }
        }

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

            // Persist single-flight before the async gap so a concurrent pump sees
            // it. This write is the single-flight guarantee's actual enforcement
            // point: if it fails, we must NOT proceed to `adapter.deliver` (a
            // concurrent pump could not have seen this instruction as
            // `.delivering` and might double-deliver it), so fail closed instead
            // and never call the adapter.
            var inFlight = instruction
            inFlight.state = .delivering
            inFlight.deliveringAt = now
            do {
                try store.upsertInstruction(inFlight)
            } catch {
                changed.append(markFailed(instruction, error: Self.storageFailureMessage(error)))
                continue
            }

            switch await adapter.deliver(inFlight) {
            case .success(let receipt):
                inFlight.state = .delivered
                inFlight.deliveredAt = now
                inFlight.deliveryMechanism = receipt.mechanism
                inFlight.deliveryCheckpoint = receipt.transcriptCheckpoint
                inFlight.deliveryReplyText = receipt.replyText
                inFlight.deliveryReplyTurnID = receipt.replyTurnID
                inFlight.error = nil
            case .failure(let error):
                inFlight.state = .failed
                inFlight.error = Self.describe(error)
            }

            do {
                try store.upsertInstruction(inFlight)
                submittedSnapshots.removeValue(forKey: inFlight.id)
                changed.append(inFlight)
            } catch {
                // The delivery attempt genuinely completed (in memory `inFlight`
                // holds its real outcome), but persisting the final state failed.
                // Do not leave it silently stuck showing `.delivering` in SQLite:
                // mark it failed (best effort; if that write also fails there is
                // no further fallback, but this call's returned `changed` still
                // makes the failure visible to the caller instead of vanishing).
                changed.append(markFailed(inFlight, error: Self.storageFailureMessage(error)))
            }
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
    /// undeliverable instruction doesn't fire hours later. The message names the
    /// window and the frozen target so a caller that surfaces `error` verbatim
    /// (`CallPhase.derive`, `AppModel.handleTwoWayDeliveryChanges`) shows the
    /// user something concrete instead of a bare "expired" (INF-248/B3;
    /// docs/two-way.md's "Waiting and expiry are invisible" fix).
    @discardableResult
    public func expireStale(now: Date) -> [Instruction] {
        let candidates = (try? store.fetchInstructions(inStates: [.pending, .confirmed])) ?? []
        var expired: [Instruction] = []
        for instruction in candidates where now.timeIntervalSince(instruction.createdAt) > expiryWindow {
            let minutes = max(1, Int((expiryWindow / 60).rounded()))
            let target = instruction.targetDisplayName ?? "the agent"
            expired.append(markFailed(
                instruction,
                error: "Send expired after \(minutes) min waiting for \(target) to go quiet."
            ))
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

    /// Message for a `try? store.upsertInstruction` that would have silently
    /// swallowed a write failure at a delivery-state transition (INF-249/B6).
    /// Used both when the pre-delivery "mark as delivering" write fails (so the
    /// adapter is never called) and when the post-delivery final-state write
    /// fails (so a delivery that genuinely completed doesn't vanish silently).
    /// Stable substring for callers/tests to key off of: "storage error".
    private static func storageFailureMessage(_ error: Error) -> String {
        "Could not save the delivery state (storage error: \(error)). Marked failed; review and resend."
    }

    /// Message for the runtime strand-recovery backstop: a `.delivering`
    /// instruction discovered stuck past `deliveringStrandTimeout` during a
    /// normal pump call, as opposed to `recoverInterruptedInstructions`'s
    /// startup-only "Attaché restarted before delivery completed" message.
    /// Stable substring: "interrupted".
    private static func strandedDeliveryMessage(timeout: TimeInterval, target: String?) -> String {
        let minutes = max(1, Int((timeout / 60).rounded()))
        let name = target ?? "the agent"
        return "Delivery to \(name) was interrupted: still in progress after \(minutes) min with no result. Review and resend."
    }
}
