import XCTest
@testable import AttacheApp

final class MiniCompanionFrameTests: XCTestCase {
    private let laptop = NSRect(x: 0, y: 0, width: 1512, height: 982)
    private let external = NSRect(x: 1512, y: 0, width: 2560, height: 1440)
    private let size = MiniCompanionWindowController.defaultSize

    func testSavedFrameOnACurrentScreenIsKept() {
        let saved = NSRect(x: 1600, y: 300, width: 280, height: 300)
        let resolved = MiniCompanionWindowController.resolvedFrame(
            saved: saved, screens: [laptop, external], size: size
        )
        XCTAssertEqual(resolved, saved)
    }

    func testSavedFrameOnAVanishedDisplayFallsBackOnScreen() {
        let savedOnExternal = NSRect(x: 3000, y: 600, width: 280, height: 300)
        let resolved = MiniCompanionWindowController.resolvedFrame(
            saved: savedOnExternal, screens: [laptop], size: size
        )
        XCTAssertTrue(laptop.contains(resolved), "the companion must never strand offscreen")
        XCTAssertEqual(resolved.size, savedOnExternal.size, "the chosen size survives the move")
    }

    func testBarelyOverlappingFrameCountsAsOffscreen() {
        let sliver = NSRect(x: laptop.maxX - 20, y: 300, width: 280, height: 300)
        let resolved = MiniCompanionWindowController.resolvedFrame(
            saved: sliver, screens: [laptop], size: size
        )
        XCTAssertTrue(laptop.contains(resolved))
        XCTAssertNotEqual(resolved.origin, sliver.origin)
    }

    func testNoSavedFrameLandsBottomRightOfThePrimaryScreen() {
        let resolved = MiniCompanionWindowController.resolvedFrame(
            saved: nil, screens: [laptop], size: size
        )
        XCTAssertTrue(laptop.contains(resolved))
        XCTAssertGreaterThan(resolved.midX, laptop.midX)
        XCTAssertLessThan(resolved.midY, laptop.midY)
    }

    func testArrangementKeyIsStableAndOrderIndependent() {
        let keyA = MiniCompanionWindowController.arrangementKey(for: [laptop, external])
        let keyB = MiniCompanionWindowController.arrangementKey(for: [external, laptop])
        let laptopOnly = MiniCompanionWindowController.arrangementKey(for: [laptop])
        XCTAssertEqual(keyA, keyB)
        XCTAssertNotEqual(keyA, laptopOnly)
    }
}
