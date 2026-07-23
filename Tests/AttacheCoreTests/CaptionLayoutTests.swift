import CoreGraphics
import XCTest
@testable import AttacheCore

/// Pure layout math behind the live-call caption line-count scroll feature.
final class CaptionLayoutTests: XCTestCase {

    // MARK: - CaptionLineAdaptation

    func testUnknownHeightHonorsChosenLineCountVerbatim() {
        // Normal-sized windows (budget unknown / infinite) must behave exactly as
        // before: the user's chosen line count wins, at full scale.
        for chosen in 1...5 {
            let fit = CaptionLineAdaptation.fit(
                availableHeight: .infinity,
                chosenLineCount: chosen,
                fontSize: 24,
                maxLineCount: 5
            )
            XCTAssertEqual(fit.visibleLines, chosen)
            XCTAssertEqual(fit.scale, 1, accuracy: 0.0001)
        }
    }

    func testNonPositiveHeightHonorsChosenLineCount() {
        let fit = CaptionLineAdaptation.fit(
            availableHeight: 0, chosenLineCount: 4, fontSize: 24, maxLineCount: 5)
        XCTAssertEqual(fit.visibleLines, 4)
        XCTAssertEqual(fit.scale, 1, accuracy: 0.0001)
    }

    func testGenerousHeightFitsAllChosenLines() {
        // A tall window fits the full chosen count with no scaling.
        let fit = CaptionLineAdaptation.fit(
            availableHeight: 600, chosenLineCount: 5, fontSize: 24, maxLineCount: 5)
        XCTAssertEqual(fit.visibleLines, 5)
        XCTAssertEqual(fit.scale, 1, accuracy: 0.0001)
    }

    func testShortWindowReducesVisibleLinesBelowChosen() {
        // Only room for ~2 lines: the chosen 5 collapses to what fits, at full
        // scale, instead of demanding a taller window.
        let lineH = CaptionLineAdaptation.perLineHeight(fontSize: 24) // ~36.4
        let available = CaptionLineAdaptation.verticalChrome + lineH * 2.4
        let fit = CaptionLineAdaptation.fit(
            availableHeight: available, chosenLineCount: 5, fontSize: 24, maxLineCount: 5)
        XCTAssertEqual(fit.visibleLines, 2)
        XCTAssertEqual(fit.scale, 1, accuracy: 0.0001)
    }

    func testVisibleLinesNeverBelowOne() {
        let fit = CaptionLineAdaptation.fit(
            availableHeight: 10, chosenLineCount: 4, fontSize: 24, maxLineCount: 5)
        XCTAssertEqual(fit.visibleLines, 1)
        XCTAssertLessThan(fit.scale, 1)
        XCTAssertGreaterThanOrEqual(fit.scale, CaptionLineAdaptation.minScale)
    }

    func testTinyWindowScalesFontDownButNotBelowFloor() {
        // Not even one line fits at full size: scale down, clamped at minScale.
        let fit = CaptionLineAdaptation.fit(
            availableHeight: 1, chosenLineCount: 4, fontSize: 24, maxLineCount: 5)
        XCTAssertEqual(fit.visibleLines, 1)
        XCTAssertEqual(fit.scale, CaptionLineAdaptation.minScale, accuracy: 0.0001)
    }

    func testChosenLineCountIsClampedToRange() {
        let over = CaptionLineAdaptation.fit(
            availableHeight: .infinity, chosenLineCount: 99, fontSize: 24, maxLineCount: 5)
        XCTAssertEqual(over.visibleLines, 5)
        let under = CaptionLineAdaptation.fit(
            availableHeight: .infinity, chosenLineCount: 0, fontSize: 24, maxLineCount: 5)
        XCTAssertEqual(under.visibleLines, 1)
    }

    /// The whole point of BUG 1: adaptation depends only on available height,
    /// font, and the chosen ceiling. There is no path by which a larger chosen
    /// line count demands more room than a smaller one at the same window size,
    /// so the caption never needs to push the window's minimum up.
    func testMoreChosenLinesNeverNeedMoreRoomThanFewerAtSameHeight() {
        let height: CGFloat = 150
        var previous = 0
        for chosen in 1...5 {
            let fit = CaptionLineAdaptation.fit(
                availableHeight: height, chosenLineCount: chosen, fontSize: 24, maxLineCount: 5)
            // Visible lines are monotonic non-decreasing but capped by what fits;
            // the fit is always satisfiable at THIS height (scale stays 1 here).
            XCTAssertGreaterThanOrEqual(fit.visibleLines, previous)
            XCTAssertEqual(fit.scale, 1, accuracy: 0.0001,
                           "a taller chosen count must not force a smaller window to scale")
            previous = fit.visibleLines
        }
    }

    // MARK: - CaptionScrollHitRegion

    func testMaxBandHeightGrowsWithLinesAndFont() {
        let small = CaptionScrollHitRegion.maxBandHeight(fontSize: 24, maxLineCount: 5)
        let taller = CaptionScrollHitRegion.maxBandHeight(fontSize: 34, maxLineCount: 5)
        let fewer = CaptionScrollHitRegion.maxBandHeight(fontSize: 24, maxLineCount: 2)
        XCTAssertGreaterThan(taller, small)
        XCTAssertGreaterThan(small, fewer)
    }

    func testStableRegionAnchorsAtBottomAndExtendsUpward() {
        // A 1-line caption box, bottom-anchored in window coords (y up).
        let smallBox = CGRect(x: 100, y: 80, width: 400, height: 44)
        let band = CaptionScrollHitRegion.maxBandHeight(fontSize: 24, maxLineCount: 5)
        let region = CaptionScrollHitRegion.stableRegion(
            captionFrame: smallBox, maxBandHeight: band)

        // Bottom edge is preserved (the stable anchor).
        XCTAssertEqual(region.minY, smallBox.minY, accuracy: 0.0001)
        // Region is at least the full band height, extended upward.
        XCTAssertEqual(region.height, band, accuracy: 0.0001)
        XCTAssertGreaterThan(region.maxY, smallBox.maxY)
    }

    func testPointerStaysInRegionAcrossEveryLineCountStep() {
        // A pointer resting at a fixed y that sits within a 4-line caption. As the
        // box grows 1 -> 5 (and shrinks back), the same window point must remain
        // inside the stable region every step, so N scrolls need no re-homing.
        let band = CaptionScrollHitRegion.maxBandHeight(fontSize: 24, maxLineCount: 5)
        let lineH = CaptionLineAdaptation.perLineHeight(fontSize: 24)
        let bottomY: CGFloat = 80
        // Pointer hovering where the 3rd line of a tall caption would render.
        let pointer = CGPoint(x: 300, y: bottomY + lineH * 2.5)

        for lines in [1, 2, 3, 4, 5, 4, 3, 2, 1] {
            let boxHeight = CaptionLineAdaptation.verticalChrome + lineH * CGFloat(lines)
            let box = CGRect(x: 100, y: bottomY, width: 400, height: boxHeight)
            let region = CaptionScrollHitRegion.stableRegion(
                captionFrame: box, maxBandHeight: band)
            XCTAssertTrue(region.contains(pointer),
                          "pointer fell outside stable region at \(lines) lines")
        }
    }

    func testRegionNeverShrinksBelowMaxBandEvenForTallCaption() {
        // If the caption is somehow taller than the band, the region tracks the
        // caption (never smaller than either).
        let box = CGRect(x: 0, y: 0, width: 300, height: 999)
        let region = CaptionScrollHitRegion.stableRegion(
            captionFrame: box, maxBandHeight: 200)
        XCTAssertEqual(region.height, 999, accuracy: 0.0001)
    }
}
