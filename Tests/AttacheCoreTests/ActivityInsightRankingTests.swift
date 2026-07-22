import XCTest
@testable import AttacheCore

/// INF: the optional smart-ranking pass over activity labels. These pin the
/// pure pieces: distinct-by-identity dedup, the trigger threshold, the
/// names-and-counts-only prompt, and mapping the model's answer back.
final class ActivityInsightRankingTests: XCTestCase {
    func testDistinctByIdentityCollapsesRepeatsIntoOneCandidate() {
        // "50 Coinbase calls" is ONE candidate, not fifty.
        let raw = Array(repeating: ActivityRankingCandidate(label: "checking Coinbase", count: 1), count: 50)
            + [ActivityRankingCandidate(label: "checking Slack", count: 3)]
        let distinct = ActivityInsightRanking.distinctCandidates(from: raw)
        XCTAssertEqual(distinct.count, 2)
        XCTAssertEqual(distinct.first?.label, "checking Coinbase")
        XCTAssertEqual(distinct.first?.count, 50)
    }

    func testShouldRankOnlyAboveDisplayCap() {
        XCTAssertFalse(ActivityInsightRanking.shouldRank(candidateCount: 5))
        XCTAssertTrue(ActivityInsightRanking.shouldRank(candidateCount: 6))
    }

    func testPromptContainsOnlyLabelsAndCountsNoArgumentsOrResults() {
        let sentinel = "SUPER_SECRET_ARGUMENT_abc123"
        let candidates = [
            ActivityRankingCandidate(label: "checking Slack", count: 4),
            ActivityRankingCandidate(label: "checking Coinbase", count: 2),
            ActivityRankingCandidate(label: "editing files", count: 7),
        ]
        let prompt = ActivityInsightRanking.prompt(for: candidates)
        let whole = prompt.system + "\n" + prompt.user
        // The sentinel is a stand-in for anything that could ride in a tool's
        // arguments or results; it must NEVER be constructable into the prompt.
        XCTAssertFalse(whole.contains(sentinel))
        XCTAssertTrue(prompt.user.contains("checking Slack (4)"))
        XCTAssertTrue(prompt.user.contains("editing files (7)"))
        // Only the labels and counts we passed appear; nothing else numeric or
        // service-like leaks in.
        XCTAssertFalse(whole.lowercased().contains("argument"))
        XCTAssertFalse(whole.lowercased().contains("result"))
    }

    func testParseAndSelectMapsModelAnswerBackToKnownLabels() {
        let candidates = ["checking Slack", "checking Coinbase", "editing files", "reading files"]
        let modelText = """
        1. checking Coinbase
        - editing files
        checking Slack
        """
        let ordered = ActivityInsightRanking.parseRankedLabels(modelText)
        XCTAssertEqual(ordered, ["checking Coinbase", "editing files", "checking Slack"])
        let selected = ActivityInsightRanking.selectRanked(orderedLabels: ordered, from: candidates)
        XCTAssertEqual(selected, ["checking Coinbase", "editing files", "checking Slack"])
    }

    func testSelectRankedNeverInventsALabelAndCapsAtLimit() {
        let candidates = ["checking Slack", "editing files"]
        let selected = ActivityInsightRanking.selectRanked(
            orderedLabels: ["deleting production database", "checking Slack", "editing files", "editing files"],
            from: candidates,
            limit: 1
        )
        XCTAssertEqual(selected, ["checking Slack"])
    }
}
