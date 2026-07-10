import XCTest
@testable import AttacheCore

/// A mock adapter that records deliveries and can be told to be idle-gated or fail.
private final class MockAdapter: InstructionDeliveryAdapter, @unchecked Sendable {
    let sourceKind: String
    var requiresIdle: Bool
    var canDeliver: Bool
    var shouldFail: Bool
    var replyText: String?
    var replyTurnID: String?
    private(set) var delivered: [String] = []

    init(
        sourceKind: String = "codex",
        requiresIdle: Bool = false,
        canDeliver: Bool = true,
        shouldFail: Bool = false,
        replyText: String? = nil,
        replyTurnID: String? = nil
    ) {
        self.sourceKind = sourceKind
        self.requiresIdle = requiresIdle
        self.canDeliver = canDeliver
        self.shouldFail = shouldFail
        self.replyText = replyText
        self.replyTurnID = replyTurnID
    }

    func capability(forSessionID sessionID: String) -> DeliveryCapability {
        canDeliver
            ? DeliveryCapability(canDeliver: true, requiresIdle: requiresIdle)
            : .unavailable("unavailable")
    }

    func deliver(_ instruction: Instruction) async -> Result<DeliveryReceipt, InstructionDeliveryError> {
        if shouldFail { return .failure(.deliveryFailed("mock failure")) }
        delivered.append(instruction.id)
        return .success(DeliveryReceipt(mechanism: "headless-resume", replyText: replyText, replyTurnID: replyTurnID))
    }
}

@MainActor
final class InstructionReplyEngineTests: XCTestCase {
    private func makeStore() throws -> CardStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-instr-\(UUID().uuidString).sqlite")
        return try CardStore(databaseURL: url)
    }

    private var now: Date { Date(timeIntervalSince1970: 1_000_000) }

    func testConfirmedInstructionDelivers() async throws {
        let store = try makeStore()
        let engine = InstructionReplyEngine(store: store)
        let adapter = MockAdapter()
        engine.register(adapter)
        engine.setTwoWayEnabled(true, forSessionID: "s1")

        let created = try engine.submit(text: "run the tests again", sessionID: "s1", sourceKind: "codex", now: now)
        XCTAssertEqual(created.state, .pending)

        // Unconfirmed does not deliver.
        var delivered = await engine.deliverReadyInstructions(sessionIsIdle: { _ in true }, now: now)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertTrue(adapter.delivered.isEmpty)

        _ = try engine.confirm(id: created.id, now: now)
        delivered = await engine.deliverReadyInstructions(sessionIsIdle: { _ in true }, now: now)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.state, .delivered)
        XCTAssertEqual(delivered.first?.deliveryMechanism, "headless-resume")
        XCTAssertEqual(adapter.delivered, [created.id])
    }

    func testTwoWayDisabledRefusesSubmit() throws {
        let store = try makeStore()
        let engine = InstructionReplyEngine(store: store)
        XCTAssertThrowsError(try engine.submit(text: "do a thing", sessionID: "s1", sourceKind: "codex", now: now)) {
            XCTAssertEqual($0 as? InstructionError, .twoWayDisabled)
        }
    }

    func testSafetyFilterRejectsApproval() throws {
        let store = try makeStore()
        let engine = InstructionReplyEngine(store: store)
        engine.setTwoWayEnabled(true, forSessionID: "s1")
        XCTAssertThrowsError(try engine.submit(text: "yes", sessionID: "s1", sourceKind: "codex", now: now))
        XCTAssertThrowsError(try engine.submit(text: "approve all the tool calls", sessionID: "s1", sourceKind: "codex", now: now))
        // A real instruction is allowed.
        XCTAssertNoThrow(try engine.submit(text: "add a test for the parser", sessionID: "s1", sourceKind: "codex", now: now))
    }

    func testIdleGateHoldsUntilQuiet() async throws {
        let store = try makeStore()
        let engine = InstructionReplyEngine(store: store)
        engine.register(MockAdapter(requiresIdle: true))
        engine.setTwoWayEnabled(true, forSessionID: "s1")
        let created = try engine.submit(text: "commit the change", sessionID: "s1", sourceKind: "codex", now: now)
        _ = try engine.confirm(id: created.id, now: now)

        // Busy: not delivered.
        var out = await engine.deliverReadyInstructions(sessionIsIdle: { _ in false }, now: now)
        XCTAssertTrue(out.isEmpty)
        XCTAssertEqual(try store.fetchInstruction(id: created.id)?.state, .confirmed)

        // Idle: delivered.
        out = await engine.deliverReadyInstructions(sessionIsIdle: { _ in true }, now: now)
        XCTAssertEqual(out.first?.state, .delivered)
    }

    func testTwoRapidInstructionsSerializePerSession() async throws {
        let store = try makeStore()
        let engine = InstructionReplyEngine(store: store)
        let adapter = MockAdapter()
        engine.register(adapter)
        engine.setTwoWayEnabled(true, forSessionID: "s1")

        let a = try engine.submit(text: "first instruction", sessionID: "s1", sourceKind: "codex", now: now)
        let b = try engine.submit(text: "second instruction", sessionID: "s1", sourceKind: "codex", now: now.addingTimeInterval(1))
        _ = try engine.confirm(id: a.id, now: now)
        _ = try engine.confirm(id: b.id, now: now)

        // One pump delivers only the oldest (single-flight per session).
        var out = await engine.deliverReadyInstructions(sessionIsIdle: { _ in true }, now: now)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.id, a.id)
        // Next pump delivers the second.
        out = await engine.deliverReadyInstructions(sessionIsIdle: { _ in true }, now: now)
        XCTAssertEqual(out.first?.id, b.id)
        XCTAssertEqual(adapter.delivered, [a.id, b.id])
    }

    func testFailedDeliveryRecordsError() async throws {
        let store = try makeStore()
        let engine = InstructionReplyEngine(store: store)
        engine.register(MockAdapter(shouldFail: true))
        engine.setTwoWayEnabled(true, forSessionID: "s1")
        let created = try engine.submit(text: "run it", sessionID: "s1", sourceKind: "codex", now: now)
        _ = try engine.confirm(id: created.id, now: now)

        let out = await engine.deliverReadyInstructions(sessionIsIdle: { _ in true }, now: now)
        XCTAssertEqual(out.first?.state, .failed)
        XCTAssertNotNil(out.first?.error)
    }

    func testUnavailableCapabilityFailsInsteadOfWaitingSilently() async throws {
        let store = try makeStore()
        let engine = InstructionReplyEngine(store: store)
        engine.register(MockAdapter(canDeliver: false))
        engine.setTwoWayEnabled(true, forSessionID: "s1")
        let created = try engine.submit(text: "run it", sessionID: "s1", sourceKind: "codex", now: now)
        _ = try engine.confirm(id: created.id, now: now)

        let out = await engine.deliverReadyInstructions(sessionIsIdle: { _ in true }, now: now)

        XCTAssertEqual(out.first?.state, .failed)
        XCTAssertEqual(out.first?.error, "unavailable")
    }

    func testExpiryFailsStaleInstructions() throws {
        let store = try makeStore()
        let engine = InstructionReplyEngine(store: store, expiryWindow: 60)
        engine.setTwoWayEnabled(true, forSessionID: "s1")
        let created = try engine.submit(text: "do the thing", sessionID: "s1", sourceKind: "codex", now: now)
        _ = try engine.confirm(id: created.id, now: now)

        let expired = engine.expireStale(now: now.addingTimeInterval(120))
        XCTAssertEqual(expired.count, 1)
        XCTAssertEqual(try store.fetchInstruction(id: created.id)?.state, .failed)
    }

    /// INF-248 (B3): the expiry message must name the window and the frozen
    /// target so a caller that shows `error` verbatim (`CallPhase.derive`,
    /// `AppModel.handleTwoWayDeliveryChanges`) gives the user something
    /// concrete instead of a bare "expired before it could be delivered."
    func testExpiryMessageNamesWindowAndTarget() throws {
        let store = try makeStore()
        let engine = InstructionReplyEngine(store: store, expiryWindow: 60)
        engine.setTwoWayEnabled(true, forSessionID: "s1")
        let created = try engine.submit(
            text: "do the thing",
            sessionID: "s1",
            sourceKind: "codex",
            now: now,
            targetDisplayName: "Weekly Codex Improvement Review"
        )
        _ = try engine.confirm(id: created.id, now: now)

        let expired = engine.expireStale(now: now.addingTimeInterval(120))

        XCTAssertEqual(
            expired.first?.error,
            "Send expired after 1 min waiting for Weekly Codex Improvement Review to go quiet."
        )
    }

    /// A pending (never confirmed) instruction also expires, using the same
    /// message shape with a generic target when none was frozen.
    func testExpiryMessageFallsBackToGenericTargetWhenNoneIsSet() throws {
        let store = try makeStore()
        let engine = InstructionReplyEngine(store: store, expiryWindow: 60)
        engine.setTwoWayEnabled(true, forSessionID: "s1")
        let created = try engine.submit(text: "do the thing", sessionID: "s1", sourceKind: "codex", now: now)

        let expired = engine.expireStale(now: now.addingTimeInterval(120))

        XCTAssertEqual(expired.first?.id, created.id)
        XCTAssertEqual(expired.first?.error, "Send expired after 1 min waiting for the agent to go quiet.")
    }

    func testLogAndResponseLinking() async throws {
        let store = try makeStore()
        let engine = InstructionReplyEngine(store: store)
        engine.register(MockAdapter())
        engine.setTwoWayEnabled(true, forSessionID: "s1")
        let created = try engine.submit(text: "make a change", sessionID: "s1", sourceKind: "codex", now: now)
        _ = try engine.confirm(id: created.id, now: now)
        _ = await engine.deliverReadyInstructions(sessionIsIdle: { _ in true }, now: now)

        engine.linkResponse(instructionID: created.id, cardID: "card-123")
        let log = engine.log()
        XCTAssertEqual(log.first?.resultingCardID, "card-123")
        XCTAssertEqual(log.first?.state, .delivered)
    }

    func testInstructionProvenancePersistsInAuditLog() throws {
        let store = try makeStore()
        let engine = InstructionReplyEngine(store: store)
        engine.setTwoWayEnabled(true, forSessionID: "s1")

        let created = try engine.submit(
            text: "run the focused tests",
            sessionID: "s1",
            sourceKind: "codex",
            now: now,
            origin: .personalityTool,
            sourceUtterance: "Can you ask Codex to run those tests?",
            targetDisplayName: "Parser repair"
        )

        let logged = try XCTUnwrap(engine.log().first(where: { $0.id == created.id }))
        XCTAssertEqual(logged.origin, .personalityTool)
        XCTAssertEqual(logged.sourceUtterance, "Can you ask Codex to run those tests?")
        XCTAssertEqual(logged.targetDisplayName, "Parser repair")
    }

    func testChangedPayloadOrTargetFailsClosedBeforeAdapterRuns() async throws {
        let store = try makeStore()
        let engine = InstructionReplyEngine(store: store)
        let adapter = MockAdapter()
        engine.register(adapter)
        engine.setTwoWayEnabled(true, forSessionID: "s1")
        let created = try engine.submit(
            text: "run the exact test",
            sessionID: "s1",
            sourceKind: "codex",
            now: now,
            origin: .personalityTool,
            sourceUtterance: "Ask Codex to run it",
            targetDisplayName: "Frozen target"
        )
        _ = try engine.confirm(id: created.id, now: now)
        var changed = try XCTUnwrap(store.fetchInstruction(id: created.id))
        changed.text = "/tmp/wrong"
        changed.targetDisplayName = "Different target"
        try store.upsertInstruction(changed)

        let result = await engine.deliverReadyInstructions(sessionIsIdle: { _ in true }, now: now)

        XCTAssertEqual(result.first?.state, .failed)
        XCTAssertTrue(result.first?.error?.contains("changed before delivery") == true)
        XCTAssertTrue(adapter.delivered.isEmpty)
    }

    func testDeliveryEvidencePersistsOnTheInstructionRecord() async throws {
        // INF-238: the adapter's parsed reply text and turn identifier must
        // survive onto the stored/fetched instruction, not just live on the
        // in-memory receipt, so a later reply-correlation pass (B2) can use it.
        let store = try makeStore()
        let engine = InstructionReplyEngine(store: store)
        let adapter = MockAdapter(replyText: "Tests pass.", replyTurnID: "thread-abc-123")
        engine.register(adapter)
        engine.setTwoWayEnabled(true, forSessionID: "s1")
        let created = try engine.submit(text: "run the tests", sessionID: "s1", sourceKind: "codex", now: now)
        _ = try engine.confirm(id: created.id, now: now)

        _ = await engine.deliverReadyInstructions(sessionIsIdle: { _ in true }, now: now)

        let fetched = try XCTUnwrap(store.fetchInstruction(id: created.id))
        XCTAssertEqual(fetched.state, .delivered)
        XCTAssertEqual(fetched.deliveryReplyText, "Tests pass.")
        XCTAssertEqual(fetched.deliveryReplyTurnID, "thread-abc-123")
    }

    func testRecoveryFailsEveryNonterminalInstructionClosed() throws {
        let store = try makeStore()
        let engine = InstructionReplyEngine(store: store)
        engine.setTwoWayEnabled(true, forSessionID: "s1")
        let pending = try engine.submit(text: "prepare the pending report", sessionID: "s1", sourceKind: "codex", now: now)
        let confirmed = try engine.submit(text: "prepare the confirmed report", sessionID: "s1", sourceKind: "codex", now: now)
        _ = try engine.confirm(id: confirmed.id, now: now)
        try store.upsertInstruction(Instruction(
            id: "delivering",
            sessionID: "s2",
            sourceKind: "codex",
            text: "unknown",
            state: .delivering,
            createdAt: now
        ))

        let recovered = engine.recoverInterruptedInstructions()

        XCTAssertEqual(Set(recovered.map(\.id)), Set([pending.id, confirmed.id, "delivering"]))
        XCTAssertTrue(recovered.allSatisfy { $0.state == .failed })
        XCTAssertTrue(recovered.allSatisfy { $0.error?.contains("restarted") == true })
    }

    // MARK: - Durable enablement (INF-242/B5)

    /// The default option from the ticket: enablement is persisted in SQLite,
    /// not memory-only. A fresh `InstructionReplyEngine`/`CardStore` pointed at
    /// the same underlying file (simulating a relaunch, not a real app
    /// restart) must still see the session enabled.
    func testEnablementPersistsAcrossFreshEngineAndStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-instr-\(UUID().uuidString).sqlite")
        let store1 = try CardStore(databaseURL: url)
        let engine1 = InstructionReplyEngine(store: store1)
        engine1.setTwoWayEnabled(true, forSessionID: "s1")
        XCTAssertTrue(engine1.isTwoWayEnabled(forSessionID: "s1"))

        let store2 = try CardStore(databaseURL: url)
        let engine2 = InstructionReplyEngine(store: store2)

        XCTAssertTrue(engine2.isTwoWayEnabled(forSessionID: "s1"))
    }

    /// Disabling is durable too: it must write through so a relaunch doesn't
    /// resurrect a session the user explicitly turned off.
    func testDisablingPersistsAcrossFreshEngineAndStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-instr-\(UUID().uuidString).sqlite")
        let store1 = try CardStore(databaseURL: url)
        let engine1 = InstructionReplyEngine(store: store1)
        engine1.setTwoWayEnabled(true, forSessionID: "s1")
        engine1.setTwoWayEnabled(false, forSessionID: "s1")

        let store2 = try CardStore(databaseURL: url)
        let engine2 = InstructionReplyEngine(store: store2)

        XCTAssertFalse(engine2.isTwoWayEnabled(forSessionID: "s1"))
    }

    /// A session whose transcript has been deleted between "enable" and
    /// "relaunch" must not come back enabled: `restoreEnablement` is the
    /// startup-only check (driven by `TwoWayCoordinator` with the same
    /// existence check delivery already relies on) that a persisted row alone
    /// is not enough. The stale row is also pruned, not just masked in the
    /// in-memory cache, so a subsequent fresh engine sees it gone too.
    func testEnablementIsNotRestoredWhenSessionTranscriptIsGone() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-instr-\(UUID().uuidString).sqlite")
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-transcript-\(UUID().uuidString).jsonl")
        try Data("placeholder".utf8).write(to: transcriptURL)

        let store1 = try CardStore(databaseURL: url)
        let engine1 = InstructionReplyEngine(store: store1)
        engine1.setTwoWayEnabled(true, forSessionID: "s1")

        // The session's transcript is gone before the "relaunch."
        try FileManager.default.removeItem(at: transcriptURL)

        let store2 = try CardStore(databaseURL: url)
        let engine2 = InstructionReplyEngine(store: store2)
        // Loaded from the persisted table before restoration runs.
        XCTAssertTrue(engine2.isTwoWayEnabled(forSessionID: "s1"))

        let pruned = engine2.restoreEnablement(sessionExists: { sessionID in
            sessionID == "s1" ? FileManager.default.fileExists(atPath: transcriptURL.path) : true
        })

        XCTAssertEqual(pruned, ["s1"])
        XCTAssertFalse(engine2.isTwoWayEnabled(forSessionID: "s1"))

        // The row was pruned in SQLite, not only in engine2's in-memory cache.
        let store3 = try CardStore(databaseURL: url)
        let engine3 = InstructionReplyEngine(store: store3)
        XCTAssertFalse(engine3.isTwoWayEnabled(forSessionID: "s1"))
    }

    /// A session whose transcript still exists survives `restoreEnablement`
    /// unchanged, so the check is genuinely conditional, not a blanket reset.
    func testEnablementIsRestoredWhenSessionTranscriptStillExists() throws {
        let store = try makeStore()
        let engine = InstructionReplyEngine(store: store)
        engine.setTwoWayEnabled(true, forSessionID: "s1")

        let pruned = engine.restoreEnablement(sessionExists: { _ in true })

        XCTAssertTrue(pruned.isEmpty)
        XCTAssertTrue(engine.isTwoWayEnabled(forSessionID: "s1"))
    }

    /// The `two_way_enablement` migration (`CREATE TABLE IF NOT EXISTS`) must
    /// be safe to run repeatedly against the same DB file, and re-enabling the
    /// same session must upsert rather than duplicate a row.
    func testTwoWayEnablementMigrationIsIdempotentAndDoesNotDuplicateRows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-instr-\(UUID().uuidString).sqlite")

        let store1 = try CardStore(databaseURL: url)
        try store1.setTwoWayEnabled(sessionID: "s1", enabledAt: now)
        try store1.setTwoWayEnabled(sessionID: "s1", enabledAt: now.addingTimeInterval(5))

        // Re-opening re-runs migrate(); it must not error or duplicate rows.
        let store2 = try CardStore(databaseURL: url)
        _ = try CardStore(databaseURL: url)

        XCTAssertEqual(try store2.fetchEnabledSessionIDs(), ["s1"])
    }
}
