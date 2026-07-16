import AttacheCore
import XCTest

final class SessionTaggerTests: XCTestCase {
    func testParsesPlainJSONArray() {
        let response = #"[{"id":"ABC","tag":"Taxes"},{"id":"def","tag":"Penumbra"}]"#
        let tags = SessionTagger.parse(response)
        XCTAssertEqual(tags["abc"], "Taxes")
        XCTAssertEqual(tags["def"], "Penumbra")
    }

    func testParsesThroughCodeFencesAndProse() {
        let response = """
        Sure! Here are the tags:
        ```json
        [{"id":"x1","tag":"infra"}]
        ```
        Hope that helps.
        """
        XCTAssertEqual(SessionTagger.parse(response)["x1"], "Infra")
    }

    func testParseIgnoresMalformedEntries() {
        let response = #"[{"id":"keep","tag":"Billing"},{"tag":"no id"},{"id":"blank","tag":"  "}]"#
        let tags = SessionTagger.parse(response)
        XCTAssertEqual(tags, ["keep": "Billing"])
    }

    func testNormalizeTagTitleCasesAndCapsWords() {
        XCTAssertEqual(SessionTagger.normalizeTag("  tax PREP for 2025 "), "Tax Prep")
        XCTAssertEqual(SessionTagger.normalizeTag("\"penumbra\""), "Penumbra")
    }

    func testNormalizeTagPreservesShortAcronyms() {
        XCTAssertEqual(SessionTagger.normalizeTag("HSA contributions"), "HSA Contributions")
    }

    func testUserPromptIncludesIDsAndCapsSnippet() {
        let items = [SessionTagger.Item(id: "id-1", title: "Daily Brief", snippet: String(repeating: "a", count: 400))]
        let prompt = SessionTagger.userPrompt(for: items, snippetCap: 50)
        XCTAssertTrue(prompt.contains("id: id-1"))
        XCTAssertTrue(prompt.contains("Daily Brief"))
        XCTAssertFalse(prompt.contains(String(repeating: "a", count: 400)))
    }

    func testLocalTaggingUsesMetadataWithoutSnippetOrModel() {
        let item = SessionTagger.Item(
            id: "one",
            title: "Fix personality manager layout",
            snippet: "private transcript text that must not affect the label",
            project: "Attaché"
        )
        XCTAssertEqual(SessionTagger.localTag(for: item), "Personality Manager")
        XCTAssertEqual(
            SessionTagger.localTag(for: item, knownTags: ["Personality"]),
            "Personality"
        )
    }
}
