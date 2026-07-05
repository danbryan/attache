import AttacheCore
import XCTest

final class SessionThreadGrouperTests: XCTestCase {
    private func record(_ id: String, thread: String?, minutesAgo: Double) -> SessionRecord {
        SessionRecord(
            id: id,
            title: id,
            project: "/work",
            threadName: thread,
            updatedAt: Date(timeIntervalSinceNow: -minutesAgo * 60),
            archived: false,
            filePath: "/x/\(id).jsonl",
            fileMtime: 0,
            content: ""
        )
    }

    func testTightlySpacedSameThreadFormsAChain() {
        let chains = SessionThreadGrouper.chains(from: [
            record("a", thread: "Audit skills", minutesAgo: 200),
            record("b", thread: "Audit skills", minutesAgo: 80)
        ])
        XCTAssertEqual(chains.count, 1)
        XCTAssertEqual(chains.first?.name, "Audit skills")
        XCTAssertEqual(chains.first?.ids, ["b", "a"], "most-recent first")
    }

    func testDailyAutomationDoesNotCluster() {
        // Same thread name, ~24h apart: a recurring automation, not a continuation.
        let chains = SessionThreadGrouper.chains(from: [
            record("day1", thread: "Daily Brief", minutesAgo: 60),
            record("day2", thread: "Daily Brief", minutesAgo: 60 + 24 * 60),
            record("day3", thread: "Daily Brief", minutesAgo: 60 + 48 * 60)
        ])
        XCTAssertTrue(chains.isEmpty)
    }

    func testNilThreadNameNeverChains() {
        let chains = SessionThreadGrouper.chains(from: [
            record("a", thread: nil, minutesAgo: 10),
            record("b", thread: nil, minutesAgo: 20)
        ])
        XCTAssertTrue(chains.isEmpty)
    }

    func testOnlyTheTightRunWithinAThreadChains() {
        // Two same-day continuations plus a far-future re-run of the same name.
        let chains = SessionThreadGrouper.chains(from: [
            record("x1", thread: "Reconcile", minutesAgo: 300),
            record("x2", thread: "Reconcile", minutesAgo: 240),
            record("x3", thread: "Reconcile", minutesAgo: 300 + 72 * 60)
        ])
        XCTAssertEqual(chains.count, 1)
        XCTAssertEqual(Set(chains.first?.ids ?? []), ["x1", "x2"])
    }
}
