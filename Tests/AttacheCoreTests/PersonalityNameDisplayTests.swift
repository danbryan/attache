import XCTest
@testable import AttacheCore

/// Pure display rules for the History row's authoring-personality label (the
/// generic-source case that replaces the "Generic" badge). No SwiftUI here.
final class PersonalityNameDisplayTests: XCTestCase {
    func testMissingNameShowsNothing() {
        XCTAssertNil(PersonalityNameDisplay.label(for: nil))
    }

    func testEmptyOrWhitespaceNameShowsNothing() {
        XCTAssertNil(PersonalityNameDisplay.label(for: ""))
        XCTAssertNil(PersonalityNameDisplay.label(for: "   \n"))
    }

    func testShortNamePassesThroughTrimmed() {
        XCTAssertEqual(PersonalityNameDisplay.label(for: "  Jessica  "), "Jessica")
    }

    func testNameAtLimitIsNotTruncated() {
        // Exactly 12 characters stays whole.
        XCTAssertEqual(PersonalityNameDisplay.label(for: "Jessica Rabb"), "Jessica Rabb")
    }

    func testLongNameIsTruncatedWithEllipsis() {
        XCTAssertEqual(
            PersonalityNameDisplay.label(for: "Jessica Rabbit"),
            "Jessica Rabb…"
        )
    }

    func testCustomLimit() {
        XCTAssertEqual(PersonalityNameDisplay.label(for: "Attaché", limit: 3), "Att…")
    }
}
