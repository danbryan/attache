import AppKit
import AttacheCore
import XCTest
@testable import AttacheApp

@MainActor
final class MCPApprovalHangUpTests: XCTestCase {
    private func descriptor() -> MCPToolDescriptor {
        MCPToolDescriptor(
            serverName: "srv", toolName: "lookup", description: "",
            schemaJSON: "", isReadOnly: true
        )
    }

    /// Hanging up while an ask-first confirmation is pending must resolve it as
    /// deny so the suspended tool call unblocks and the sheet clears, rather
    /// than lingering into the next call (INF-373 phase 2).
    func testHangUpResolvesPendingApprovalAsDeny() async throws {
        _ = NSApplication.shared
        let model = try AppModel(store: CardStore.inMemory())

        async let decision = model.requestMCPApprovalInteractively(
            descriptor: descriptor(), arguments: "{}"
        )

        // Wait for the interactive approval to publish its pending state.
        var published = false
        for _ in 0..<200 where !published {
            if model.pendingMCPApproval != nil { published = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(published, "the pending approval should be published")

        model.endConversation()

        let result = await decision
        XCTAssertEqual(result, .deny)
        XCTAssertNil(model.pendingMCPApproval)
    }
}
