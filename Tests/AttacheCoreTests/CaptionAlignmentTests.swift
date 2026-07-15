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

    func testTechnicalIdentifierIsSplitIntoSpeakableKaraokePieces() {
        let text = "Called AttachePresentationModelService.fetchModels(provider:baseURLText:apiKey:)."
        let alignment = CaptionAlignmentBuilder.fallback(text: text, durationMs: 6200)
        let pieces = alignment.words.map(\.word)

        XCTAssertGreaterThan(pieces.count, 8, "\(pieces)")
        XCTAssertTrue(pieces.contains { $0.contains("Attache") }, "\(pieces)")
        XCTAssertTrue(pieces.contains { $0.contains("Presentation") }, "\(pieces)")
        XCTAssertTrue(pieces.contains { $0.contains("URL") }, "\(pieces)")
        XCTAssertEqual(
            pieces.joined(separator: " ").replacingOccurrences(of: " ", with: ""),
            text.replacingOccurrences(of: " ", with: "")
        )
    }

    func testFallbackTimingsNeverOverlapAndCoverFullDuration() {
        let text = "Verified api.x.ai/v1/models and qwen3:14b-instruct_q4_K_M successfully."
        let alignment = CaptionAlignmentBuilder.fallback(text: text, durationMs: 4700)

        for pair in zip(alignment.words, alignment.words.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.startMs + pair.0.durationMs, pair.1.startMs)
            XCTAssertLessThan(pair.0.charStart, pair.0.charEnd)
        }
        let last = try! XCTUnwrap(alignment.words.last)
        XCTAssertEqual(last.startMs + last.durationMs, 4700)
        XCTAssertEqual(
            alignment.words.map(\.word).joined(separator: " ").replacingOccurrences(of: " ", with: ""),
            text.replacingOccurrences(of: " ", with: "")
        )
    }
}
