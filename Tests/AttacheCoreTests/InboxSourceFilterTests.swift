import XCTest
@testable import AttacheCore

final class InboxSourceFilterTests: XCTestCase {
    func testOnlyPresentSourcesBecomeChips() {
        let sources = InboxSourceFilter.availableSources(
            fromCardSourceKinds: [SourceKind.codex.rawValue, SourceKind.codex.rawValue]
        )
        XCTAssertEqual(sources, [.codex], "a Codex-only fleet offers no Claude Code chip")
    }

    func testAllFourLiveSourcesAppearInStableOrder() {
        // Deliberately shuffled input; the chips must come back in allCases order.
        let raw = [
            SourceKind.opencode.rawValue,
            SourceKind.claudeCode.rawValue,
            SourceKind.grokBuild.rawValue,
            SourceKind.codex.rawValue,
        ]
        XCTAssertEqual(
            InboxSourceFilter.availableSources(fromCardSourceKinds: raw),
            [.codex, .claudeCode, .grokBuild, .opencode]
        )
    }

    func testNoCardsMeansNoChips() {
        XCTAssertEqual(InboxSourceFilter.availableSources(fromCardSourceKinds: []), [])
    }

    func testDuplicatesCollapseToOneChipEach() {
        let raw = Array(repeating: SourceKind.claudeCode.rawValue, count: 5)
            + Array(repeating: SourceKind.codex.rawValue, count: 3)
        XCTAssertEqual(
            InboxSourceFilter.availableSources(fromCardSourceKinds: raw),
            [.codex, .claudeCode]
        )
    }

    func testUnknownRawValueIsIgnored() {
        let raw = ["not_a_source", SourceKind.codex.rawValue]
        XCTAssertEqual(InboxSourceFilter.availableSources(fromCardSourceKinds: raw), [.codex])
    }
}
