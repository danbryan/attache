import AppKit
import AttacheCore
import SwiftUI
import XCTest
@testable import AttacheApp

/// BUG 1/BUG 2 regression guards: the caption line-count choice must never grow
/// the window's minimum size, and `adjustCaptionLines` must clamp to its range.
@MainActor
final class CaptionLineCountWindowTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private var savedLineCount: Any?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        savedLineCount = defaults.object(forKey: AttachePreferenceKey.captionLineCount)
        defaults.removeObject(forKey: AttachePreferenceKey.captionLineCount)
    }

    override func tearDown() {
        if let savedLineCount { defaults.set(savedLineCount, forKey: AttachePreferenceKey.captionLineCount) }
        else { defaults.removeObject(forKey: AttachePreferenceKey.captionLineCount) }
        super.tearDown()
    }

    func testAdjustCaptionLinesClampsToRange() throws {
        let model = try AppModel(store: CardStore.inMemory())
        let range = AppModel.captionLineRange

        // Drive well past the top; it must stop at the ceiling.
        for _ in 0..<20 { model.adjustCaptionLines(by: 1) }
        XCTAssertEqual(model.captionLineCount, range.upperBound)

        // Drive well past the bottom; it must stop at the floor.
        for _ in 0..<20 { model.adjustCaptionLines(by: -1) }
        XCTAssertEqual(model.captionLineCount, range.lowerBound)

        // A single mid-range step moves by exactly one.
        model.captionLineCount = 2
        model.adjustCaptionLines(by: 1)
        XCTAssertEqual(model.captionLineCount, 3)
        model.adjustCaptionLines(by: -1)
        XCTAssertEqual(model.captionLineCount, 2)
    }

    func testWindowMinimumSizeIsConstantAcrossLineCounts() throws {
        // Build the real window controller at each line count and confirm the
        // window minimum never changes: the caption choice is a ceiling, not a
        // reserve. Sizing is decoupled from SwiftUI content, so line count can
        // never pin the window narrower or shorter.
        var minSizes: [NSSize] = []
        for lines in AppModel.captionLineRange {
            let model = try AppModel(store: CardStore.inMemory())
            model.captionLineCount = lines
            let controller = AttacheWindowController(model: model)
            let minSize = try XCTUnwrap(controller.window?.minSize)
            minSizes.append(minSize)
        }
        for size in minSizes {
            XCTAssertEqual(size.width, AttacheWindowController.minimumWindowSize.width, accuracy: 0.0001)
            XCTAssertEqual(size.height, AttacheWindowController.minimumWindowSize.height, accuracy: 0.0001)
        }
    }

    func testHostingViewDoesNotPropagateContentSizeToWindow() throws {
        // sizingOptions must stay empty; otherwise NSHostingView writes the
        // content's (line-count-dependent) intrinsic minimum into the window.
        let model = try AppModel(store: CardStore.inMemory())
        let controller = AttacheWindowController(model: model)
        let hosting = try XCTUnwrap(controller.window?.contentView as? NSHostingView<AttacheRootView>)
        XCTAssertTrue(hosting.sizingOptions.isEmpty)
    }
}
