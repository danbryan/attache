import XCTest
@testable import AttacheApp

final class MiniAttacheFrameTests: XCTestCase {
    private let laptop = NSRect(x: 0, y: 0, width: 1512, height: 982)
    private let external = NSRect(x: 1512, y: 0, width: 2560, height: 1440)
    private let size = MiniAttacheWindowController.defaultSize

    func testSavedFrameOnACurrentScreenIsKept() {
        let saved = NSRect(x: 1600, y: 300, width: 280, height: 300)
        let resolved = MiniAttacheWindowController.resolvedFrame(
            saved: saved, screens: [laptop, external], size: size
        )
        XCTAssertEqual(resolved, saved)
    }

    func testSavedFrameOnAVanishedDisplayFallsBackOnScreen() {
        let savedOnExternal = NSRect(x: 3000, y: 600, width: 280, height: 300)
        let resolved = MiniAttacheWindowController.resolvedFrame(
            saved: savedOnExternal, screens: [laptop], size: size
        )
        XCTAssertTrue(laptop.contains(resolved), "the attache must never strand offscreen")
        XCTAssertEqual(resolved.size, savedOnExternal.size, "the chosen size survives the move")
    }

    func testBarelyOverlappingFrameCountsAsOffscreen() {
        let sliver = NSRect(x: laptop.maxX - 20, y: 300, width: 280, height: 300)
        let resolved = MiniAttacheWindowController.resolvedFrame(
            saved: sliver, screens: [laptop], size: size
        )
        XCTAssertTrue(laptop.contains(resolved))
        XCTAssertNotEqual(resolved.origin, sliver.origin)
    }

    func testNoSavedFrameLandsBottomRightOfThePrimaryScreen() {
        let resolved = MiniAttacheWindowController.resolvedFrame(
            saved: nil, screens: [laptop], size: size
        )
        XCTAssertTrue(laptop.contains(resolved))
        XCTAssertGreaterThan(resolved.midX, laptop.midX)
        XCTAssertLessThan(resolved.midY, laptop.midY)
    }

    func testArrangementKeyIsStableAndOrderIndependent() {
        let keyA = MiniAttacheWindowController.arrangementKey(for: [laptop, external])
        let keyB = MiniAttacheWindowController.arrangementKey(for: [external, laptop])
        let laptopOnly = MiniAttacheWindowController.arrangementKey(for: [laptop])
        XCTAssertEqual(keyA, keyB)
        XCTAssertNotEqual(keyA, laptopOnly)
    }
}
