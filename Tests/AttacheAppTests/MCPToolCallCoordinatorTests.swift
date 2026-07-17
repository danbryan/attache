import AttacheCore
import XCTest
@testable import AttacheApp

final class MCPToolCallCoordinatorTests: XCTestCase {
    private func descriptor(readOnly: Bool, tool: String = "lookup") -> MCPToolDescriptor {
        MCPToolDescriptor(
            serverName: "srv", toolName: tool, description: "",
            schemaJSON: "", isReadOnly: readOnly
        )
    }

    func testAskFirstDenyReturnsDeclinedMessageWithoutExecuting() async {
        let executed = LockedBox(false)
        let coordinator = MCPToolCallCoordinator(
            approvalHandler: { _, _ in .deny },
            performCall: { _, _ in executed.set(true); return "ran" },
            persistGrant: { _, _ in }
        )
        let result = await coordinator.execute(
            descriptor: descriptor(readOnly: true),
            grant: .askFirst,
            isPrivateCall: false,
            argumentsJSON: "{}"
        )
        XCTAssertEqual(result, "The user declined the lookup lookup.")
        XCTAssertFalse(executed.get(), "the tool must not run when the user declines")
    }

    func testAllowOnceRunsWithoutPersisting() async {
        let persisted = LockedBox<[String]>([])
        let coordinator = MCPToolCallCoordinator(
            approvalHandler: { _, _ in .allowOnce },
            performCall: { _, _ in "ran" },
            persistGrant: { name, _ in persisted.mutate { $0.append(name) } }
        )
        let result = await coordinator.execute(
            descriptor: descriptor(readOnly: true),
            grant: .askFirst,
            isPrivateCall: false,
            argumentsJSON: "{}"
        )
        XCTAssertEqual(result, "ran")
        XCTAssertTrue(persisted.get().isEmpty)
    }

    func testAlwaysAllowPersistsForReadOnlyOnly() async {
        // Read-only: persists alwaysAllow.
        let readOnlyGrants = LockedBox<[String: MCPToolPermission]>([:])
        let readOnly = descriptor(readOnly: true)
        let roCoordinator = MCPToolCallCoordinator(
            approvalHandler: { _, _ in .alwaysAllow },
            performCall: { _, _ in "ran" },
            persistGrant: { name, perm in readOnlyGrants.mutate { $0[name] = perm } }
        )
        _ = await roCoordinator.execute(
            descriptor: readOnly, grant: .askFirst, isPrivateCall: false, argumentsJSON: "{}"
        )
        XCTAssertEqual(readOnlyGrants.get()[readOnly.namespacedName], .alwaysAllow)

        // Effectful: alwaysAllow is rejected (never persisted), but the single
        // call still runs.
        let effectfulGrants = LockedBox<[String: MCPToolPermission]>([:])
        let effectful = descriptor(readOnly: false, tool: "write")
        let ranBox = LockedBox(false)
        let efCoordinator = MCPToolCallCoordinator(
            approvalHandler: { _, _ in .alwaysAllow },
            performCall: { _, _ in ranBox.set(true); return "ran" },
            persistGrant: { name, perm in effectfulGrants.mutate { $0[name] = perm } }
        )
        let result = await efCoordinator.execute(
            descriptor: effectful, grant: .askFirst, isPrivateCall: false, argumentsJSON: "{}"
        )
        XCTAssertEqual(result, "ran")
        XCTAssertTrue(ranBox.get())
        XCTAssertTrue(effectfulGrants.get().isEmpty, "effectful tools never persist always-allow")
    }

    func testAlwaysAllowGrantRunsWithoutPrompting() async {
        let prompted = LockedBox(false)
        let coordinator = MCPToolCallCoordinator(
            approvalHandler: { _, _ in prompted.set(true); return .deny },
            performCall: { _, _ in "ran" },
            persistGrant: { _, _ in }
        )
        let result = await coordinator.execute(
            descriptor: descriptor(readOnly: true),
            grant: .alwaysAllow,
            isPrivateCall: false,
            argumentsJSON: "{}"
        )
        XCTAssertEqual(result, "ran")
        XCTAssertFalse(prompted.get(), "an always-allow read-only tool never prompts")
    }

    func testPrivateCallEffectfulToolIsNotAvailable() async {
        let executed = LockedBox(false)
        let coordinator = MCPToolCallCoordinator(
            approvalHandler: { _, _ in .allowOnce },
            performCall: { _, _ in executed.set(true); return "ran" },
            persistGrant: { _, _ in }
        )
        let result = await coordinator.execute(
            descriptor: descriptor(readOnly: false, tool: "write"),
            grant: .askFirst,
            isPrivateCall: true,
            argumentsJSON: "{}"
        )
        XCTAssertEqual(result, "The write tool is not available in this conversation.")
        XCTAssertFalse(executed.get())
    }
}

/// A tiny thread-safe box for capturing side effects from the injected
/// closures without data-race warnings.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    func mutate(_ body: (inout Value) -> Void) { lock.lock(); body(&value); lock.unlock() }
}
