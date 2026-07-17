import AttacheCore
import XCTest

/// INF-364 step 2 (display fix): given a fixed caption box width and a 64-char
/// unbreakable token, `CaptionTokenLayout` must split it into fragments that
/// each fit, so the rendering view can wrap mid-token instead of overflowing or
/// collapsing the box.
final class CaptionOversizedTokenLayoutTests: XCTestCase {
    private let checksum = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b85" // 64 hex chars

    func testSixtyFourCharTokenSplitsIntoFragmentsThatEachFit() {
        let boxWidth = 320.0
        let fontSize = 24.0
        let maxChars = CaptionTokenLayout.fragmentCharacterCount(boxWidth: boxWidth, fontSize: fontSize)

        let fragments = CaptionTokenLayout.fragments(for: checksum, boxWidth: boxWidth, fontSize: fontSize)

        XCTAssertGreaterThan(fragments.count, 1, "a 64-char token in a 320pt box should require wrapping")
        for fragment in fragments {
            XCTAssertLessThanOrEqual(
                fragment.count, maxChars,
                "fragment '\(fragment)' does not fit the estimated \(maxChars)-character budget"
            )
            XCTAssertFalse(fragment.isEmpty)
        }
    }

    func testFragmentsLosslesslyRecombineToTheOriginalToken() {
        let fragments = CaptionTokenLayout.fragments(for: checksum, boxWidth: 320, fontSize: 24)
        XCTAssertEqual(fragments.joined(), checksum)
    }

    func testTokenThatAlreadyFitsIsReturnedUnsplit() {
        let shortToken = "hello"
        let fragments = CaptionTokenLayout.fragments(for: shortToken, boxWidth: 700, fontSize: 24)
        XCTAssertEqual(fragments, [shortToken])
    }

    func testNarrowerBoxProducesMoreFragmentsForTheSameToken() {
        let wideBoxFragments = CaptionTokenLayout.fragments(for: checksum, boxWidth: 640, fontSize: 24)
        let narrowBoxFragments = CaptionTokenLayout.fragments(for: checksum, boxWidth: 220, fontSize: 24)
        XCTAssertGreaterThanOrEqual(narrowBoxFragments.count, wideBoxFragments.count)
    }

    func testTinyOrZeroBoxWidthNeverProducesAnEmptyFragmentOrCrashes() {
        // Defends against a collapsed box: the layout must still terminate and
        // never hand back an empty piece that would render as nothing.
        for width in [0.0, 1.0, -5.0] {
            let fragments = CaptionTokenLayout.fragments(for: checksum, boxWidth: width, fontSize: 24)
            XCTAssertFalse(fragments.isEmpty)
            XCTAssertTrue(fragments.allSatisfy { !$0.isEmpty })
            XCTAssertEqual(fragments.joined(), checksum)
        }
    }

    func testWordLongerThanAnyCaptionLineAlsoWrapsWithoutOverflow() {
        let longWord = CaptionTortureFixtures.wordLongerThanAnyCaptionLine.text
        let boxWidth = 700.0
        let fontSize = 24.0
        let maxChars = CaptionTokenLayout.fragmentCharacterCount(boxWidth: boxWidth, fontSize: fontSize)
        let fragments = CaptionTokenLayout.fragments(for: longWord, boxWidth: boxWidth, fontSize: fontSize)

        XCTAssertGreaterThan(fragments.count, 1)
        XCTAssertTrue(fragments.allSatisfy { $0.count <= maxChars })
        XCTAssertEqual(fragments.joined(), longWord)
    }
}
