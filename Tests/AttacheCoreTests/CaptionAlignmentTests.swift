import AttacheCore
import XCTest

final class CaptionAlignmentTests: XCTestCase {
    func testFallbackAlignmentPreservesWordOrderAndDuration() {
        let text = "Codex finished the storage and playback slice."
        let alignment = CaptionAlignmentBuilder.fallback(text: text, durationMs: 3200)

        XCTAssertEqual(alignment.text, text)
        XCTAssertEqual(alignment.totalDurationMs, 3200)
        XCTAssertEqual(alignment.words.map(\.word), ["Codex", "finished", "the", "storage", "and", "playback", "slice."])
        XCTAssertEqual(alignment.words.first?.startMs, 0)
        XCTAssertEqual(alignment.words.last?.startMs ?? 0, 3200 - (alignment.words.last?.durationMs ?? 0), accuracy: 1000)
    }

    func testActiveWordLookupUsesTimingWindow() {
        let alignment = CaptionAlignmentBuilder.fallback(text: "one two three", durationMs: 3000)

        XCTAssertEqual(alignment.activeWordIndex(at: 100), 0)
        XCTAssertNotNil(alignment.activeWordIndex(at: 1500))
        XCTAssertNil(alignment.activeWordIndex(at: 3100))
    }

    func testCaptionSegmentsHighlightActiveWordInline() {
        let alignment = CaptionAlignmentBuilder.fallback(
            text: "Codex finished the storage slice.",
            durationMs: 3000
        )
        let activeWordIndex = alignment.words.firstIndex { $0.word == "storage" }!
        let currentTimeMs = alignment.words[activeWordIndex].startMs + 10

        let segments = alignment.captionSegments(
            fallbackText: "Codex finished the storage slice.",
            currentTimeMs: currentTimeMs
        )

        XCTAssertEqual(segments.map(\.text).joined(), alignment.text)
        XCTAssertEqual(segments.filter(\.isActive).map(\.text), ["storage"])
        XCTAssertTrue(segments.contains { $0.text.contains("slice.") && !$0.isActive })
    }

    func testWindowedCaptionSegmentsLimitLongResponses() {
        let text = (1...40).map { "word\($0)" }.joined(separator: " ")
        let alignment = CaptionAlignmentBuilder.fallback(text: text, durationMs: 8000)
        let activeWordIndex = 20
        let currentTimeMs = alignment.words[activeWordIndex].startMs + 10

        let segments = alignment.windowedCaptionSegments(
            fallbackText: text,
            currentTimeMs: currentTimeMs,
            leadingWords: 3,
            trailingWords: 4
        )
        let rendered = segments.map(\.text).joined()

        XCTAssertLessThan(rendered.count, text.count)
        XCTAssertTrue(rendered.hasPrefix("..."))
        XCTAssertTrue(rendered.hasSuffix("..."))
        XCTAssertEqual(segments.filter(\.isActive).map(\.text), ["word21"])
        XCTAssertTrue(rendered.contains("word18"))
        XCTAssertTrue(rendered.contains("word25"))
    }
}
