import XCTest
import AttacheCore
@testable import AttacheApp

private final class StubAdapter: InstructionDeliveryAdapter, @unchecked Sendable {
    let sourceKind = "codex"
    var result: Result<DeliveryReceipt, InstructionDeliveryError> = .success(DeliveryReceipt(mechanism: "headless-resume"))

    init(result: Result<DeliveryReceipt, InstructionDeliveryError> = .success(DeliveryReceipt(mechanism: "headless-resume"))) {
        self.result = result
    }

    func capability(forSessionID sessionID: String) -> DeliveryCapability {
        DeliveryCapability(canDeliver: true, requiresIdle: true)
    }
    func deliver(_ instruction: Instruction) async -> Result<DeliveryReceipt, InstructionDeliveryError> {
        result
    }
}

@MainActor
final class TwoWayCoordinatorTests: XCTestCase {
    private func makeStore() throws -> CardStore {
        try CardStore(databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-coord-\(UUID().uuidString).sqlite"))
    }

    func testPrepareShowsInLogAndDeliversWhenIdle() async throws {
        let store = try makeStore()
        let sessionFile = FileManager.default.temporaryDirectory.appendingPathComponent("sess-\(UUID().uuidString).jsonl")
        try Data("{}".utf8).write(to: sessionFile)
        let coordinator = TwoWayCoordinator(
            store: store,
            locateSessionFile: { _ in sessionFile },
            quietWindow: 0,
            adapters: [StubAdapter()]
        )
        coordinator.setEnabled(true, sessionID: "s1")
        let instruction = try coordinator.prepare(text: "run the suite", sessionID: "s1", sourceKind: "codex")
        XCTAssertEqual(coordinator.log.first?.id, instruction.id)
        XCTAssertEqual(coordinator.log.first?.state, .pending)

        // Confirm+deliver with an idle session (quietWindow default 6, file mtime is old).
        try await coordinator.confirmAndDeliver(id: instruction.id)
        XCTAssertEqual(coordinator.log.first?.state, .delivered)
    }

    func testConfirmAndDeliverReturnsFailureForVisibleStatus() async throws {
        let store = try makeStore()
        let sessionFile = FileManager.default.temporaryDirectory.appendingPathComponent("sess-\(UUID().uuidString).jsonl")
        try Data("{}".utf8).write(to: sessionFile)
        let coordinator = TwoWayCoordinator(
            store: store,
            locateSessionFile: { _ in sessionFile },
            quietWindow: 0,
            adapters: [StubAdapter(result: .failure(.deliveryFailed("env: node: No such file or directory")))]
        )
        coordinator.setEnabled(true, sessionID: "s1")
        let instruction = try coordinator.prepare(text: "run the suite", sessionID: "s1", sourceKind: "codex")

        let changed = try await coordinator.confirmAndDeliver(id: instruction.id)

        XCTAssertEqual(changed.first?.id, instruction.id)
        XCTAssertEqual(changed.first?.state, .failed)
        XCTAssertEqual(changed.first?.error, "Delivery failed: env: node: No such file or directory")
        XCTAssertEqual(coordinator.log.first?.state, .failed)
    }

    func testLinkResponseCardTiesReplyToInstruction() async throws {
        let store = try makeStore()
        let sessionFile = FileManager.default.temporaryDirectory.appendingPathComponent("sess-\(UUID().uuidString).jsonl")
        try Data("{}".utf8).write(to: sessionFile)
        let coordinator = TwoWayCoordinator(
            store: store,
            locateSessionFile: { _ in sessionFile },
            quietWindow: 0,
            adapters: [StubAdapter()]
        )
        coordinator.setEnabled(true, sessionID: "s1")
        let instruction = try coordinator.prepare(text: "make a change", sessionID: "s1", sourceKind: "codex")
        try await coordinator.confirmAndDeliver(id: instruction.id)

        coordinator.linkResponseCard(cardID: "card-1", sessionID: "s1")
        XCTAssertEqual(coordinator.log.first(where: { $0.id == instruction.id })?.resultingCardID, "card-1")
    }

    func testDisabledSessionRefusesPrepare() throws {
        let store = try makeStore()
        let coordinator = TwoWayCoordinator(
            store: store,
            locateSessionFile: { _ in nil },
            adapters: [StubAdapter()]
        )
        XCTAssertThrowsError(try coordinator.prepare(text: "go", sessionID: "s1", sourceKind: "codex"))
    }
}
