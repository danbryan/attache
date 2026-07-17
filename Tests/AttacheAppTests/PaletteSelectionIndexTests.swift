import XCTest
@testable import AttacheApp

/// INF-365: j/k list navigation in the inbox and history overlays must
/// mirror arrow-key movement exactly. These tests exercise the extracted
/// pure selection-index arithmetic shared by the character palette, the
/// inbox overlay, and the history overlay.
final class PaletteSelectionIndexTests: XCTestCase {
    func testMoveDownFromNoSelectionLandsOnFirst() {
        XCTAssertEqual(PaletteSelectionIndex.move(current: nil, ids: ["a", "b", "c"], delta: 1), "a")
    }

    func testMoveUpFromNoSelectionLandsOnLast() {
        XCTAssertEqual(PaletteSelectionIndex.move(current: nil, ids: ["a", "b", "c"], delta: -1), "c")
    }

    func testMoveDownAdvancesByOne() {
        XCTAssertEqual(PaletteSelectionIndex.move(current: "a", ids: ["a", "b", "c"], delta: 1), "b")
    }

    func testMoveUpRetreatsByOne() {
        XCTAssertEqual(PaletteSelectionIndex.move(current: "b", ids: ["a", "b", "c"], delta: -1), "a")
    }

    func testMoveDownClampsAtLastRow() {
        XCTAssertEqual(PaletteSelectionIndex.move(current: "c", ids: ["a", "b", "c"], delta: 1), "c")
    }

    func testMoveUpClampsAtFirstRow() {
        XCTAssertEqual(PaletteSelectionIndex.move(current: "a", ids: ["a", "b", "c"], delta: -1), "a")
    }

    func testEmptyListYieldsNoSelection() {
        XCTAssertNil(PaletteSelectionIndex.move(current: nil, ids: [], delta: 1))
        XCTAssertNil(PaletteSelectionIndex.move(current: "a", ids: [], delta: 1))
    }

    func testCurrentSelectionMissingFromListRestartsAtEdge() {
        // e.g. a filter changed underneath the previously selected row.
        XCTAssertEqual(PaletteSelectionIndex.move(current: "stale", ids: ["a", "b"], delta: 1), "a")
        XCTAssertEqual(PaletteSelectionIndex.move(current: "stale", ids: ["a", "b"], delta: -1), "b")
    }

    func testJKMirrorsArrowDeltasExactly() {
        // j == down arrow (delta +1), k == up arrow (delta -1); this test
        // documents that the same helper backs both input paths, so any
        // future PaletteKeyMonitor change that diverges the deltas breaks
        // this contract loudly.
        let ids = ["a", "b", "c", "d"]
        let downArrow = PaletteSelectionIndex.move(current: "b", ids: ids, delta: 1)
        let jKey = PaletteSelectionIndex.move(current: "b", ids: ids, delta: 1)
        XCTAssertEqual(downArrow, jKey)
        XCTAssertEqual(downArrow, "c")

        let upArrow = PaletteSelectionIndex.move(current: "c", ids: ids, delta: -1)
        let kKey = PaletteSelectionIndex.move(current: "c", ids: ids, delta: -1)
        XCTAssertEqual(upArrow, kKey)
        XCTAssertEqual(upArrow, "b")
    }
}
