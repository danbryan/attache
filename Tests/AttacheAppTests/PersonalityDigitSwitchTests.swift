import XCTest
@testable import AttacheApp

/// INF-365: number-key personality switch in the ⇧⌘P palette. Digit N maps
/// to the Nth visible (possibly filtered) row, but only while the search
/// field is empty; with search text, digits must fall through to filtering.
final class PersonalityDigitSwitchTests: XCTestCase {
    private func personality(_ id: String, _ name: String) -> Personality {
        Personality(id: id, name: name, prompt: "test", isBuiltIn: false)
    }

    func testDigitMapsToNthVisibleRow() {
        let list = [personality("a", "Alpha"), personality("b", "Beta"), personality("c", "Gamma")]
        XCTAssertEqual(PersonalityDigitSwitch.resolve(digit: 1, visible: list, searchIsEmpty: true)?.id, "a")
        XCTAssertEqual(PersonalityDigitSwitch.resolve(digit: 2, visible: list, searchIsEmpty: true)?.id, "b")
        XCTAssertEqual(PersonalityDigitSwitch.resolve(digit: 3, visible: list, searchIsEmpty: true)?.id, "c")
    }

    func testDigitMapsToNthRowUnderFilter() {
        // Simulates a filtered list: only the personalities that survived
        // the search term are visible, so digit 2 should hit the second
        // *filtered* entry, not the second entry of some unfiltered set.
        let filtered = [personality("b", "Beta"), personality("c", "Gamma")]
        XCTAssertEqual(PersonalityDigitSwitch.resolve(digit: 2, visible: filtered, searchIsEmpty: true)?.id, "c")
    }

    func testDigitOutOfRangeResolvesToNil() {
        let list = [personality("a", "Alpha")]
        XCTAssertNil(PersonalityDigitSwitch.resolve(digit: 5, visible: list, searchIsEmpty: true))
    }

    func testDigitDoesNotSwitchWhenSearchHasText() {
        let list = [personality("a", "Alpha"), personality("b", "Beta")]
        XCTAssertNil(PersonalityDigitSwitch.resolve(digit: 1, visible: list, searchIsEmpty: false))
    }

    func testOnlyFirstNineRowsAreReachable() {
        let list = (0..<12).map { personality("id\($0)", "Name\($0)") }
        XCTAssertEqual(PersonalityDigitSwitch.resolve(digit: 9, visible: list, searchIsEmpty: true)?.id, "id8")
        // Digit 0 and negative/above-9 digits are not part of the 1-9 contract.
        XCTAssertNil(PersonalityDigitSwitch.resolve(digit: 0, visible: list, searchIsEmpty: true))
    }
}
