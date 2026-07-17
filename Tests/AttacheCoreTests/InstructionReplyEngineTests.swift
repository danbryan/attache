import XCTest
import SQLite3
@testable import AttacheCore

/// A mock adapter that records deliveries and can be told to be idle-gated or fail.
private final class MockAdapter: InstructionDeliveryAdapter, @unchecked Sendable {
    let sourceKind: String
    var requiresIdle: Bool
    var canDeliver: Bool
    var shouldFail: Bool
    var replyText: String?
    var replyTurnID: String?
    /// Invoked at the start of `deliver`, before it returns a result. Lets a
    /// test simulate storage breaking mid-delivery (INF-249/B6): the write
    /// marking the instruction `.delivering` has already succeeded by the time
    /// this runs, so it isolates a failure in the POST-delivery final-state
    /// write from a failure in the PRE-delivery one.
    var onDeliver: (() -> Void)?
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
        onDeliver?()
        if shouldFail { return .failure(.deliveryFailed("mock failure")) }
        delivered.append(instruction.id)
        return .success(DeliveryReceipt(mechanism: "headless-resume", replyText: replyText, replyTurnID: replyTurnID))
    }
}

/// Forces the next WRITE through a `CardStore` under test to fail, without any
/// filesystem-permission trick: a `CardStore` keeps one SQLite connection open
/// for its whole lifetime, and an already-open, already-writable file
/// descriptor keeps writing successfully even after `chflags`/`chmod` locks the
/// path down (verified empirically; permission bits and immutability flags are
/// enforced at `open()`, not on every `write()`). Instead, open an independent
/// second connection to the same on-disk file and install `BEFORE
/// INSERT`/`BEFORE UPDATE` triggers that always abort, so the next
/// `upsertInstruction` (an INSERT ... ON CONFLICT DO UPDATE) fails with a real,
/// surfaced SQLite error (INF-249/B6's failure-injection seam) while ordinary
/// SELECT reads on the store under test keep working (dropping the table
/// outright was tried first and rejected: `fetchInstructions` also reads
/// through `try?`, so it silently returns an empty array once the table is
/// gone, which starves the pump before it ever reaches the write path).
private func breakInstructionWrites(atPath path: String) {
    var handle: OpaquePointer?
    guard sqlite3_open(path, &handle) == SQLITE_OK else {
        XCTFail("failed to open a second connection to \(path)")
        return
    }
    defer { sqlite3_close(handle) }
    let sql = """
        CREATE TRIGGER test_break_instructions_insert BEFORE INSERT ON instructions
        BEGIN SELECT RAISE(ABORT, 'induced write failure'); END;
        CREATE TRIGGER test_break_instructions_update BEFORE UPDATE ON instructions
        BEGIN SELECT RAISE(ABORT, 'induced write failure'); END;
        """
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
        let message = handle.flatMap { sqlite3_errmsg($0).map { String(cString: $0) } } ?? "unknown"
        XCTFail("failed to install write-breaking triggers: \(message)")
        return
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

    /// INF-361 safety criterion: Grok Build is registered for watching/
    /// narration in `SessionSourceRegistry`, but `TwoWayCoordinator` never
    /// registers a delivery adapter for it (no adapter exists yet). Proves the
    /// engine's existing fail-safe (`deliverReadyInstructions`'s
    /// `guard let adapter = adapters[instruction.sourceKind] else { markFailed... }`)
    /// covers a source with zero adapters registered at all, not just an
    /// adapter that explicitly reports itself unavailable: a confirmed
    /// instruction for a "grok_build" session fails closed with a clear error
    /// and is never silently sent.
    func testConfirmedInstructionForSourceWithNoRegisteredAdapterFailsClosed() async throws {
        let store = try makeStore()
        let engine = InstructionReplyEngine(store: store)
        // Only "codex" has an adapter, mirroring production's real registration
        // (TwoWayCoordinator registers claude + codex, never grok_build).
        engine.register(MockAdapter(sourceKind: "codex"))
        engine.setTwoWayEnabled(true, forSessionID: "grok-s1")

        let created = try engine.submit(text: "run the tests again", sessionID: "grok-s1", sourceKind: "grok_build", now: now)
        _ = try engine.confirm(id: created.id, now: now)

        let delivered = await engine.deliverReadyInstructions(sessionIsIdle: { _ in true }, now: now)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.state, .failed)
        XCTAssertEqual(delivered.first?.error, "No delivery adapter for grok_build.")
        XCTAssertEqual(try store.fetchInstruction(id: created.id)?.state, .failed)
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

    /// INF-256 (E4): `ATTACHE_TWO_WAY_EXPIRY_SECONDS` must be structurally
    /// inert without `ATTACHE_UI_TEST=1` also present, so it can never be a
    /// way to shrink a real user's 30-minute expiry window by itself. This is
    /// the explicit non-bypass proof the ticket's success criteria requires,
    /// not just a convention.
    func testExpiryWindowOverrideRequiresUITestFlag() {
        let withoutUITest = InstructionReplyEngine.expiryWindow(fromEnvironment: [
            "ATTACHE_TWO_WAY_EXPIRY_SECONDS": "2"
        ])
        XCTAssertEqual(withoutUITest, InstructionReplyEngine.defaultExpiryWindow)

        let withUITest = InstructionReplyEngine.expiryWindow(fromEnvironment: [
            "ATTACHE_UI_TEST": "1",
            "ATTACHE_TWO_WAY_EXPIRY_SECONDS": "2"
        ])
        XCTAssertEqual(withUITest, 2)

        // A near-miss value ("true" instead of "1") must not count either:
        // the gate is the exact string the harness sets, not any truthy value.
        let nearMiss = InstructionReplyEngine.expiryWindow(fromEnvironment: [
            "ATTACHE_UI_TEST": "true",
            "ATTACHE_TWO_WAY_EXPIRY_SECONDS": "2"
        ])
        XCTAssertEqual(nearMiss, InstructionReplyEngine.defaultExpiryWindow)
    }

    /// With the flag present, a missing, non-numeric, or non-positive override
    /// value still falls back to the production default rather than crashing
    /// or disabling expiry outright.
    func testExpiryWindowOverrideIgnoresInvalidOrMissingValue() {
        XCTAssertEqual(
            InstructionReplyEngine.expiryWindow(fromEnvironment: ["ATTACHE_UI_TEST": "1"]),
            InstructionReplyEngine.defaultExpiryWindow
        )
        XCTAssertEqual(
            InstructionReplyEngine.expiryWindow(fromEnvironment: [
                "ATTACHE_UI_TEST": "1",
                "ATTACHE_TWO_WAY_EXPIRY_SECONDS": "not-a-number"
            ]),
            InstructionReplyEngine.defaultExpiryWindow
        )
        XCTAssertEqual(
            InstructionReplyEngine.expiryWindow(fromEnvironment: [
                "ATTACHE_UI_TEST": "1",
                "ATTACHE_TWO_WAY_EXPIRY_SECONDS": "0"
            ]),
            InstructionReplyEngine.defaultExpiryWindow
        )
        XCTAssertEqual(
            InstructionReplyEngine.expiryWindow(fromEnvironment: [:]),
            InstructionReplyEngine.defaultExpiryWindow
        )
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

    // MARK: - Transaction integrity: no silent `try?` on state transitions (INF-249/B6)

    /// If the write that marks an instruction `.delivering` (the single-flight
    /// guarantee's actual enforcement point) fails, the engine must not proceed
    /// to call the adapter at all, and must surface the instruction as `.failed`
    /// in the pump's returned `changed` array instead of silently leaving it
    /// `.confirmed` forever.
    func testStorageWriteFailureBeforeDeliveringFailsClosedWithoutCallingAdapter() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-instr-\(UUID().uuidString).sqlite")
        let store = try CardStore(databaseURL: url)
        let engine = InstructionReplyEngine(store: store)
        let adapter = MockAdapter()
        engine.register(adapter)
        engine.setTwoWayEnabled(true, forSessionID: "s1")

        let created = try engine.submit(text: "run it", sessionID: "s1", sourceKind: "codex", now: now)
        _ = try engine.confirm(id: created.id, now: now)

        breakInstructionWrites(atPath: store.databasePath)

        let out = await engine.deliverReadyInstructions(sessionIsIdle: { _ in true }, now: now)

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.id, created.id)
        XCTAssertEqual(out.first?.state, .failed)
        XCTAssertTrue(out.first?.error?.contains("storage error") == true, "got: \(out.first?.error ?? "nil")")
        XCTAssertTrue(adapter.delivered.isEmpty, "the adapter must never be called once the delivering write fails")
    }

    /// If the write that persists the FINAL state (`.delivered`/`.failed`) after
    /// the adapter genuinely ran fails, the delivery attempt already happened
    /// for real (the adapter recorded it), but the DB may still show the
    /// instruction as `.delivering`. The failure must still be visible through
    /// the pump's returned `changed` array (best effort at persisting `.failed`
    /// too), matching the "surfaced through `changed`" contract the coordinator
    /// and `AppModel` already rely on for expiry (B3).
    func testStorageWriteFailureAfterDeliveryStillSurfacesFailureInChanged() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-instr-\(UUID().uuidString).sqlite")
        let store = try CardStore(databaseURL: url)
        let engine = InstructionReplyEngine(store: store)
        let adapter = MockAdapter()
        adapter.onDeliver = { breakInstructionWrites(atPath: store.databasePath) }
        engine.register(adapter)
        engine.setTwoWayEnabled(true, forSessionID: "s1")

        let created = try engine.submit(text: "run it", sessionID: "s1", sourceKind: "codex", now: now)
        _ = try engine.confirm(id: created.id, now: now)

        let out = await engine.deliverReadyInstructions(sessionIsIdle: { _ in true }, now: now)

        // The adapter really ran: the delivery attempt genuinely completed.
        XCTAssertEqual(adapter.delivered, [created.id])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.id, created.id)
        XCTAssertEqual(out.first?.state, .failed)
        XCTAssertTrue(out.first?.error?.contains("storage error") == true, "got: \(out.first?.error ?? "nil")")
    }

    /// A `.delivering` instruction stuck past `deliveringStrandTimeout` is
    /// recovered by a normal pump call (`deliverReadyInstructions`), not just by
    /// `recoverInterruptedInstructions`/a fresh engine construction, so a stuck
    /// delivery doesn't require a full app restart to clear.
    func testStrandedDeliveringInstructionIsRecoveredAtRuntimeDuringPump() async throws {
        let store = try makeStore()
        let engine = InstructionReplyEngine(store: store, deliveringStrandTimeout: 60)
        engine.setTwoWayEnabled(true, forSessionID: "s1")

        try store.upsertInstruction(Instruction(
            id: "stuck-1",
            sessionID: "s1",
            sourceKind: "codex",
            text: "run the tests",
            state: .delivering,
            createdAt: now,
            confirmedAt: now,
            deliveringAt: now,
            targetDisplayName: "Weekly Codex Improvement Review"
        ))

        // 2 minutes later, well past the 60s test timeout, via a normal pump call.
        let out = await engine.deliverReadyInstructions(
            sessionIsIdle: { _ in true },
            now: now.addingTimeInterval(120)
        )

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.id, "stuck-1")
        XCTAssertEqual(out.first?.state, .failed)
        XCTAssertTrue(out.first?.error?.contains("interrupted") == true, "got: \(out.first?.error ?? "nil")")
        XCTAssertTrue(out.first?.error?.contains("Weekly Codex Improvement Review") == true)

        // Persisted, not just returned in-memory.
        XCTAssertEqual(try store.fetchInstruction(id: "stuck-1")?.state, .failed)
    }

    /// A `.delivering` instruction younger than the timeout is left alone (not
    /// a false-positive strand recovery) and still enforces single-flight: a
    /// freshly confirmed instruction in the same session does not deliver while
    /// it's genuinely still in flight.
    func testRecentDeliveringInstructionIsNotRecoveredAndStillBlocksSingleFlight() async throws {
        let store = try makeStore()
        let engine = InstructionReplyEngine(store: store, deliveringStrandTimeout: 300)
        let adapter = MockAdapter()
        engine.register(adapter)
        engine.setTwoWayEnabled(true, forSessionID: "s1")

        try store.upsertInstruction(Instruction(
            id: "in-flight-1",
            sessionID: "s1",
            sourceKind: "codex",
            text: "already going",
            state: .delivering,
            createdAt: now,
            confirmedAt: now,
            deliveringAt: now
        ))

        let queued = try engine.submit(text: "second one", sessionID: "s1", sourceKind: "codex", now: now)
        _ = try engine.confirm(id: queued.id, now: now)

        let out = await engine.deliverReadyInstructions(
            sessionIsIdle: { _ in true },
            now: now.addingTimeInterval(10)
        )

        XCTAssertTrue(out.isEmpty)
        XCTAssertTrue(adapter.delivered.isEmpty)
        XCTAssertEqual(try store.fetchInstruction(id: "in-flight-1")?.state, .delivering)
        XCTAssertEqual(try store.fetchInstruction(id: queued.id)?.state, .confirmed)
    }

    /// A normal successful delivery records when it entered `.delivering`, so
    /// the runtime strand-recovery check above has real data to compare
    /// against instead of falling back to `confirmedAt`/`createdAt`.
    func testDeliveringAtIsRecordedWhenDeliveryBegins() async throws {
        let store = try makeStore()
        let engine = InstructionReplyEngine(store: store)
        engine.register(MockAdapter())
        engine.setTwoWayEnabled(true, forSessionID: "s1")
        let created = try engine.submit(text: "run the deploy script", sessionID: "s1", sourceKind: "codex", now: now)
        _ = try engine.confirm(id: created.id, now: now)

        _ = await engine.deliverReadyInstructions(sessionIsIdle: { _ in true }, now: now)

        let fetched = try XCTUnwrap(store.fetchInstruction(id: created.id))
        XCTAssertEqual(fetched.state, .delivered)
        XCTAssertEqual(fetched.deliveringAt, now)
    }

    /// Sanity check on the chosen default: the runtime strand timeout should be
    /// longer than `AgentResumeDeliveryAdapter.defaultProcessTimeout` (5 min,
    /// INF-248/B1), since a real delivery attempt should never legitimately run
    /// longer than that adapter-level timeout.
    func testDefaultDeliveringStrandTimeoutIsLongerThanTheProcessTimeout() {
        XCTAssertGreaterThan(InstructionReplyEngine.defaultDeliveringStrandTimeout, 5 * 60)
    }
}
