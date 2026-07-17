import AttacheCore
import XCTest

/// INF-365: caption hover-scrub shows a timestamp tooltip on each word. This
/// covers the pure word-index-to-timestamp mapping (a `WordTiming.startMs`
/// formatted as "m:ss") that backs the tooltip text.
final class CaptionTimestampFormatterTests: XCTestCase {
    func testFormatsWholeSeconds() {
        XCTAssertEqual(CaptionTimestampFormatter.format(ms: 0), "0:00")
        XCTAssertEqual(CaptionTimestampFormatter.format(ms: 5000), "0:05")
        XCTAssertEqual(CaptionTimestampFormatter.format(ms: 65_000), "1:05")
    }

    func testTruncatesPartialSeconds() {
        XCTAssertEqual(CaptionTimestampFormatter.format(ms: 5999), "0:05")
    }

    func testPadsSecondsUnderTen() {
        XCTAssertEqual(CaptionTimestampFormatter.format(ms: 61_000), "1:01")
    }

    func testClampsNegativeToZero() {
        XCTAssertEqual(CaptionTimestampFormatter.format(ms: -500), "0:00")
    }

    func testMapsEachWordInAnAlignmentToItsOwnTimestamp() {
        let alignment = CaptionAlignmentBuilder.fallback(text: "one two three", durationMs: 3000)
        let timestamps = alignment.words.map { CaptionTimestampFormatter.format(ms: $0.startMs) }
        // Word order is preserved and every word maps to a monotonically
        // non-decreasing timestamp string derived from its own startMs.
        XCTAssertEqual(timestamps.count, 3)
        XCTAssertEqual(timestamps.first, "0:00")
        XCTAssertEqual(alignment.words.map(\.startMs).sorted(), alignment.words.map(\.startMs))
    }
}
