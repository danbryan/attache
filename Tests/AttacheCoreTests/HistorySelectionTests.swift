import XCTest
@testable import AttacheCore

/// Pure set-math backing the History overlay's multi-select. No SwiftUI here;
/// these prove toggle, select-all-visible, retain-on-scope-change, and the
/// Command-delete target rule in isolation.
final class HistorySelectionTests: XCTestCase {
    func testToggleAddsThenRemoves() {
        var selection: Set<String> = []
        selection = HistorySelection.toggle("a", in: selection)
        XCTAssertEqual(selection, ["a"])
        selection = HistorySelection.toggle("b", in: selection)
        XCTAssertEqual(selection, ["a", "b"])
        selection = HistorySelection.toggle("a", in: selection)
        XCTAssertEqual(selection, ["b"])
    }

    func testSelectAllUnionsVisibleWithoutDroppingPriorChecks() {
        let selection: Set<String> = ["x"]
        let next = HistorySelection.selectAll(visible: ["a", "b", "c"], in: selection)
        XCTAssertEqual(next, ["x", "a", "b", "c"])
    }

    func testRetainingDropsChecksThatLeftTheVisibleSet() {
        // Scope/filter change: only ids still on screen survive.
        let selection: Set<String> = ["a", "b", "gone"]
        let next = HistorySelection.retaining(selection, visible: ["a", "b", "c"])
        XCTAssertEqual(next, ["a", "b"])
    }

    func testRetainingWithNoOverlapClearsSelection() {
        let next = HistorySelection.retaining(["a", "b"], visible: ["c", "d"])
        XCTAssertTrue(next.isEmpty)
    }

    func testDeletionTargetsPrefersCheckedAndVisibleInVisibleOrder() {
        let targets = HistorySelection.deletionTargets(
            checked: ["c", "a"],
            visible: ["a", "b", "c"],
            focused: "b"
        )
        // Checked wins over the focused row, ordered by the visible list.
        XCTAssertEqual(targets, ["a", "c"])
    }

    func testDeletionTargetsFallsBackToFocusedRowWhenNothingChecked() {
        let targets = HistorySelection.deletionTargets(
            checked: [],
            visible: ["a", "b", "c"],
            focused: "b"
        )
        XCTAssertEqual(targets, ["b"])
    }

    func testDeletionTargetsIgnoresCheckedIdsNoLongerVisible() {
        let targets = HistorySelection.deletionTargets(
            checked: ["ghost"],
            visible: ["a", "b"],
            focused: "a"
        )
        // A stale check that is off screen must not delete; nothing checked
        // that is visible, so fall back to the focused row.
        XCTAssertEqual(targets, ["a"])
    }

    func testDeletionTargetsEmptyWhenNothingCheckedAndNoFocus() {
        XCTAssertTrue(HistorySelection.deletionTargets(checked: [], visible: ["a"], focused: nil).isEmpty)
        XCTAssertTrue(HistorySelection.deletionTargets(checked: [], visible: ["a"], focused: "off-screen").isEmpty)
    }
}
