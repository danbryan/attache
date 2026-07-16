import XCTest
import AppKit
@testable import AttacheApp
import AttacheCore

@MainActor
final class ActivitySimulatorPresentationTests: XCTestCase {
    func testClosingSimulatorReturnsToLiveActivity() throws {
        _ = NSApplication.shared
        let model = try AppModel(store: CardStore.inMemory())

        model.showActivitySimulator()
        model.simulatedActivity = AttacheActivityState(
            phase: .toolRunning,
            activeAgent: .codex,
            toolKind: .shell
        )
        model.simulatedFleetFocusID = "sim-codex-1"

        XCTAssertTrue(model.activitySimulatorEnabled)
        XCTAssertNotNil(model.simulatedActivity)
        XCTAssertEqual(model.simulatedFleetFocusID, "sim-codex-1")

        model.hideActivitySimulator()

        XCTAssertFalse(model.activitySimulatorEnabled)
        XCTAssertNil(model.simulatedActivity)
        XCTAssertNil(model.simulatedFleetFocusID)
    }
}
