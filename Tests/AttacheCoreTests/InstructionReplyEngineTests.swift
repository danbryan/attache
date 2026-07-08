import XCTest
@testable import AttacheCore

/// A mock adapter that records deliveries and can be told to be idle-gated or fail.
private final class MockAdapter: InstructionDeliveryAdapter, @unchecked Sendable {
    let sourceKind: String
    var requiresIdle: Bool
    var canDeliver: Bool
    var shouldFail: Bool
    private(set) var delivered: [String] = []

    init(sourceKind: String = "codex", requiresIdle: Bool = false, canDeliver: Bool = true, shouldFail: Bool = false) {
        self.sourceKind = sourceKind
        self.requiresIdle = requiresIdle
        self.canDeliver = canDeliver
        self.shouldFail = shouldFail
    }

    func capability(forSessionID sessionID: String) -> DeliveryCapability {
        canDeliver
            ? DeliveryCapability(canDeliver: true, requiresIdle: requiresIdle)
            : .unavailable("unavailable")
    }

    func deliver(_ instruction: Instruction) async -> Result<DeliveryReceipt, InstructionDeliveryError> {
        if shouldFail { return .failure(.deliveryFailed("mock failure")) }
        delivered.append(instruction.id)
        return .success(DeliveryReceipt(mechanism: "headless-resume"))
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
}
