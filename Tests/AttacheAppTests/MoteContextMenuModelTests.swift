import XCTest
@testable import AttacheApp

/// INF-375: the pure "which items appear" logic behind a watched-session
/// mote's right-click context menu.
final class MoteContextMenuModelTests: XCTestCase {
    func testUnfocusedMoteShowsOnlyStopWatching() {
        let model = MoteContextMenuModel(
            title: "Operations", source: "Codex", isFocused: false, canUnfocus: true
        )
        XCTAssertEqual(model.items, [.stopWatching])
    }

    func testFocusedMoteShowsUnfocusThenStopWatchingWhenSupported() {
        let model = MoteContextMenuModel(
            title: "Operations", source: "Codex", isFocused: true, canUnfocus: true
        )
        XCTAssertEqual(model.items, [.unfocus, .stopWatching])
    }

    func testFocusedMoteHidesUnfocusWhenUnsupported() {
        let model = MoteContextMenuModel(
            title: "Operations", source: "Codex", isFocused: true, canUnfocus: false
        )
        XCTAssertEqual(model.items, [.stopWatching])
    }

    func testStopWatchingAlwaysPresent() {
        for focused in [true, false] {
            for canUnfocus in [true, false] {
                let model = MoteContextMenuModel(
                    title: "S", source: "Claude Code", isFocused: focused, canUnfocus: canUnfocus
                )
                XCTAssertTrue(model.items.contains(.stopWatching))
            }
        }
    }

    func testHeaderCombinesTitleAndSource() {
        let model = MoteContextMenuModel(
            title: "Maryland Lien", source: "Claude Code", isFocused: false, canUnfocus: false
        )
        XCTAssertEqual(model.header, "Maryland Lien · Claude Code")
    }

    func testHeaderFallsBackToTitleWhenSourceEmpty() {
        let model = MoteContextMenuModel(
            title: "Untitled session", source: "", isFocused: false, canUnfocus: false
        )
        XCTAssertEqual(model.header, "Untitled session")
    }
}
