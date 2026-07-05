import XCTest
@testable import AttacheCore

final class InboxDigestTests: XCTestCase {
    func testEmptyIsCaughtUp() {
        XCTAssertEqual(InboxDigest.text(slices: []), "You're all caught up.")
    }

    func testCountsSessionsAndLatestSummary() {
        let digest = InboxDigest.text(slices: [
            .init(title: "attache", unheardCount: 4, latestSummary: "Tests are green"),
            .init(title: "web", unheardCount: 2, latestSummary: "Deploy finished"),
            .init(title: "tax", unheardCount: 1, latestSummary: "")
        ])
        XCTAssertTrue(digest.hasPrefix("7 updates across 3 sessions: attache (4), web (2), tax (1)."))
        XCTAssertTrue(digest.contains("Latest from attache: Tests are green"))
    }

    func testSingularForms() {
        let digest = InboxDigest.text(slices: [
            .init(title: "attache", unheardCount: 1, latestSummary: "")
        ])
        XCTAssertTrue(digest.hasPrefix("1 update across 1 session: attache (1)."))
    }

    func testOverflowNamesTopThree() {
        let slices = (1...5).map {
            InboxDigest.SessionSlice(title: "s\($0)", unheardCount: $0, latestSummary: "")
        }
        let digest = InboxDigest.text(slices: slices)
        XCTAssertTrue(digest.contains("s5 (5), s4 (4), s3 (3) and 2 more."))
    }

    func testDecisionCallout() {
        let digest = InboxDigest.text(slices: [
            .init(title: "attache", unheardCount: 2, latestSummary: "Blocked on schema choice", needsDecision: true),
            .init(title: "web", unheardCount: 1, latestSummary: "")
        ])
        XCTAssertTrue(digest.contains("attache needs a decision from you."))
    }
}
