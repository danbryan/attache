import AttacheCore
import XCTest

final class SessionSearchRankerTests: XCTestCase {
    private func record(_ id: String, _ title: String, content: String = "", daysAgo: Double = 1, archived: Bool = false) -> SessionRecord {
        SessionRecord(
            id: id,
            title: title,
            project: "/work",
            threadName: title,
            updatedAt: Date(timeIntervalSinceNow: -daysAgo * 86_400),
            archived: archived,
            filePath: "/x/\(id).jsonl",
            fileMtime: 0,
            content: content.lowercased()
        )
    }

    func testTitleMatchRanksAboveContentMatch() {
        let records = [
            record("a", "Daily Brief", content: "we discussed penumbra delegation today"),
            record("b", "Penumbra delegation status")
        ]
        let hits = SessionSearchRanker.search("penumbra", in: records)
        XCTAssertEqual(hits.first?.record.id, "b", "title hit should outrank content hit")
        XCTAssertEqual(hits.count, 2)
    }

    func testPlainLanguageMatchesOnDistinctiveWords() {
        let records = [
            record("a", "Morning Email Brief", content: "checked the inbox"),
            record("b", "Check Andy's delegation", content: "staked tokens to the penumbra validator")
        ]
        let hits = SessionSearchRanker.search("bring up the session where we did penumbra", in: records)
        XCTAssertEqual(hits.first?.record.id, "b")
        XCTAssertTrue(hits.first?.matchedContent ?? false)
        XCTAssertNotNil(hits.first?.snippet)
    }

    func testPinnedSortsFirstAndEmptyQueryIsRecency() {
        let records = [
            record("old", "Older session", daysAgo: 10),
            record("new", "Newer session", daysAgo: 1)
        ]
        let recency = SessionSearchRanker.search("", in: records)
        XCTAssertEqual(recency.map(\.record.id), ["new", "old"])

        let pinned = SessionSearchRanker.search("", in: records, pinned: ["old"])
        XCTAssertEqual(pinned.first?.record.id, "old")
    }

    func testArchivedCanBeExcluded() {
        let records = [record("live", "Live one"), record("gone", "Archived one", archived: true)]
        let hits = SessionSearchRanker.search("one", in: records, includeArchived: false)
        XCTAssertEqual(hits.map(\.record.id), ["live"])
    }
}
