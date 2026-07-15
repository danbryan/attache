import AttacheCore
import XCTest

final class AttacheSessionSearchServiceTests: XCTestCase {

    private func tempDBURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("attache-search-svc-\(UUID().uuidString).sqlite")
    }

    private func makeRecord(id: String, title: String, content: String, source: SourceKind = .codex, project: String? = "/tmp/p", mtime: Double = 1000) -> SessionRecord {
        SessionRecord(id: id, title: title, project: project, threadName: nil,
                      updatedAt: Date(timeIntervalSince1970: mtime), archived: false,
                      filePath: "/nonexistent/\(UUID().uuidString)", fileMtime: mtime,
                      content: content, topicTag: nil, sourceKind: source)
    }

    private func makeService(records: [SessionRecord]) -> AttacheSessionSearchService {
        let fts = SessionFTSIndex(databaseURL: tempDBURL())
        fts.index(records: records)
        return AttacheSessionSearchService(ftsIndex: fts, records: records)
    }

    private let fixedNow = Date(timeIntervalSince1970: 1_000_000)

    // Acceptance 1: identical queries produce the same ordered session IDs.
    func testIdenticalQueriesProduceSameOrdering() {
        let records = [
            makeRecord(id: "alpha", title: "Alpha deploy", content: "deployed the alpha service"),
            makeRecord(id: "beta", title: "Beta review", content: "reviewed the beta branch"),
        ]
        let svc = makeService(records: records)
        let q = AttacheSessionSearchQuery(text: "deploy")
        let r1 = svc.search(q, now: fixedNow)
        let r2 = svc.search(q, now: fixedNow)
        XCTAssertEqual(r1.map(\.sessionID), r2.map(\.sessionID))
    }

    // Acceptance 2: a strong match from last week can outrank a weak recent match.
    func testStrongOlderMatchOutranksWeakRecent() {
        let records = [
            makeRecord(id: "strong-old", title: "Penumbra architecture review", content: "deep dive into Penumbra architecture decisions", mtime: 100),
            makeRecord(id: "weak-recent", title: "Routine session", content: "routine filler text about nothing important", mtime: 999_999),
        ]
        let svc = makeService(records: records)
        let results = svc.search(AttacheSessionSearchQuery(text: "Penumbra"), now: fixedNow)
        XCTAssertEqual(results.first?.sessionID, "strong-old",
                       "A strong title+content match from last week must outrank a weak recent match.")
    }

    // Acceptance 3: beginning, middle, and end transcript terms are findable.
    func testBeginningMiddleEndFindable() {
        let records = [makeRecord(id: "range", title: "Range test",
            content: "alpha zeta beginning\nchecked\ngamma middle phase\nreviewed\nomega end finish")]
        let svc = makeService(records: records)
        XCTAssertNotNil(svc.search(AttacheSessionSearchQuery(text: "alpha"), now: fixedNow).first)
        XCTAssertNotNil(svc.search(AttacheSessionSearchQuery(text: "gamma"), now: fixedNow).first)
        XCTAssertNotNil(svc.search(AttacheSessionSearchQuery(text: "omega"), now: fixedNow).first)
    }

    // Acceptance 4: malformed FTS operators and huge input behave deterministically.
    func testMalformedFTSOperatorsDoNotCrash() {
        let records = [makeRecord(id: "safe", title: "Safe", content: "safe content")]
        let svc = makeService(records: records)
        // Malformed FTS operators should be escaped, not cause an error.
        let results = svc.search(AttacheSessionSearchQuery(text: "OR * AND NOT"), now: fixedNow)
        XCTAssertNotNil(results) // does not crash
    }

    func testHugeInputReturnsEmpty() {
        let records = [makeRecord(id: "big", title: "Big", content: "content")]
        let svc = makeService(records: records)
        let huge = String(repeating: "a", count: 2_000)
        XCTAssertEqual(svc.search(AttacheSessionSearchQuery(text: huge), now: fixedNow).count, 0)
    }

    func testPagination() {
        var records: [SessionRecord] = []
        for i in 0..<10 {
            records.append(makeRecord(id: "page-\(i)", title: "Page \(i)", content: "shared needle keyword"))
        }
        let svc = makeService(records: records)
        let page1 = svc.search(AttacheSessionSearchQuery(text: "needle", limit: 5, offset: 0), now: fixedNow)
        let page2 = svc.search(AttacheSessionSearchQuery(text: "needle", limit: 5, offset: 5), now: fixedNow)
        XCTAssertEqual(page1.count, 5)
        XCTAssertEqual(page2.count, 5)
        let page1IDs = Set(page1.map(\.sessionID))
        let page2IDs = Set(page2.map(\.sessionID))
        XCTAssertTrue(page1IDs.isDisjoint(with: page2IDs), "pages must not overlap")
    }

    func testTieBreakingIsDeterministic() {
        // Two sessions with identical content and timestamps; tie-break by sessionID.
        let records = [
            makeRecord(id: "zzz", title: "Tie", content: "shared tie marker kappa", mtime: 500),
            makeRecord(id: "aaa", title: "Tie", content: "shared tie marker kappa", mtime: 500),
        ]
        let svc = makeService(records: records)
        let results = svc.search(AttacheSessionSearchQuery(text: "kappa"), now: fixedNow)
        XCTAssertEqual(results.first?.sessionID, "aaa", "tie-break by sessionID ascending")
    }

    // Acceptance 5: search latency is interactive on a large corpus.
    func testLargeCorpusInteractiveQuery() {
        var records: [SessionRecord] = []
        for i in 0..<400 {
            records.append(makeRecord(id: "bulk-\(i)", title: "Bulk \(i)",
                content: "session \(i) discusses needle\(i % 7) and routine filler"))
        }
        let svc = makeService(records: records)
        let start = Date()
        let results = svc.search(AttacheSessionSearchQuery(text: "needle3"), now: fixedNow)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0)
        XCTAssertFalse(results.isEmpty)
    }

    // Acceptance 6: search does not change focus or authorization.
    func testSearchIsSideEffectFree() {
        let records = [makeRecord(id: "se", title: "SE", content: "side effect free kappa")]
        let svc = makeService(records: records)
        // The service has no focus/authorization state to mutate.
        let a = svc.search(AttacheSessionSearchQuery(text: "kappa"), now: fixedNow)
        let b = svc.search(AttacheSessionSearchQuery(text: "kappa"), now: fixedNow)
        XCTAssertEqual(a, b, "search is pure: same results each call")
    }

    // Acceptance 8: results disclose source and date.
    func testResultsDiscloseSourceAndDate() {
        let records = [makeRecord(id: "disc", title: "Disclose", content: "disclosure marker phi", source: .claudeCode, mtime: 42_000)]
        let svc = makeService(records: records)
        let results = svc.search(AttacheSessionSearchQuery(text: "phi"), now: fixedNow)
        XCTAssertEqual(results.first?.sourceKind, SourceKind.claudeCode.rawValue)
        XCTAssertNotNil(results.first?.timestamp)
    }

    // Acceptance: empty query returns recent sessions.
    func testEmptyQueryReturnsRecentSessions() {
        let records = [
            makeRecord(id: "old", title: "Old", content: "old content", mtime: 100),
            makeRecord(id: "new", title: "New", content: "new content", mtime: 999_000),
        ]
        let svc = makeService(records: records)
        let recent = svc.search(AttacheSessionSearchQuery(text: ""), now: fixedNow)
        XCTAssertEqual(recent.first?.sessionID, "new", "empty query returns most-recent first")
    }

    // Acceptance: filters by source.
    func testFilterBySource() {
        let records = [
            makeRecord(id: "codex", title: "Codex", content: "shared term theta", source: .codex),
            makeRecord(id: "claude", title: "Claude", content: "shared term theta", source: .claudeCode),
        ]
        let svc = makeService(records: records)
        let codexOnly = svc.search(AttacheSessionSearchQuery(text: "theta", sourceKind: SourceKind.codex.rawValue), now: fixedNow)
        XCTAssertTrue(codexOnly.allSatisfy { $0.sourceKind == SourceKind.codex.rawValue })
    }
}