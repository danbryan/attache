import XCTest
@testable import AttacheCore

final class PipelineOrderingTests: XCTestCase {
    func testISORoundTrip() {
        let s = "2026-07-02T10:00:01.000Z"
        let d = PipelineOrdering.date(from: s)
        XCTAssertNotNil(d)
        // Whole-second form also parses.
        XCTAssertNotNil(PipelineOrdering.date(from: "2026-07-02T10:00:01Z"))
    }

    func testStableIDIsDeterministicForSameTurn() {
        let a = PipelineOrdering.stableCardID(source: "codex", sessionID: "s1", sourceTime: "2026-07-02T10:00:01.000Z", content: "Hello")
        let b = PipelineOrdering.stableCardID(source: "codex", sessionID: "s1", sourceTime: "2026-07-02T10:00:01.000Z", content: "Hello")
        XCTAssertEqual(a, b)
    }

    func testStableIDDiffersByContentSessionAndTime() {
        let base = PipelineOrdering.stableCardID(source: "codex", sessionID: "s1", sourceTime: "2026-07-02T10:00:01.000Z", content: "Hello")
        XCTAssertNotEqual(base, PipelineOrdering.stableCardID(source: "codex", sessionID: "s1", sourceTime: "2026-07-02T10:00:01.000Z", content: "Hello world"))
        XCTAssertNotEqual(base, PipelineOrdering.stableCardID(source: "codex", sessionID: "s2", sourceTime: "2026-07-02T10:00:01.000Z", content: "Hello"))
        XCTAssertNotEqual(base, PipelineOrdering.stableCardID(source: "codex", sessionID: "s1", sourceTime: "2026-07-02T10:00:02.000Z", content: "Hello"))
    }

    func testStalenessThreshold() {
        let newest = PipelineOrdering.date(from: "2026-07-02T10:05:00.000Z")!
        // An event 3 minutes older than the newest spoken is stale (default 120s).
        let old = PipelineOrdering.date(from: "2026-07-02T10:02:00.000Z")!
        XCTAssertTrue(PipelineOrdering.isStale(eventTime: old, newestSpokenTime: newest))
        // A near-current event is not stale.
        let recent = PipelineOrdering.date(from: "2026-07-02T10:04:30.000Z")!
        XCTAssertFalse(PipelineOrdering.isStale(eventTime: recent, newestSpokenTime: newest))
        // Nothing spoken yet -> never stale.
        XCTAssertFalse(PipelineOrdering.isStale(eventTime: old, newestSpokenTime: nil))
    }
}
