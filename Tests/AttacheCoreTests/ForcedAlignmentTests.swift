import AttacheCore
import XCTest

final class ForcedAlignmentTests: XCTestCase {
    private func recognized(_ pairs: [(String, Int)]) -> [RecognizedWord] {
        // Each recognized word starts at the given ms; duration runs to the next
        // word (or +400ms for the last), which is all the mapper reads.
        pairs.enumerated().map { index, pair in
            let end = index + 1 < pairs.count ? pairs[index + 1].1 : pair.1 + 400
            return RecognizedWord(text: pair.0, startMs: pair.1, durationMs: max(1, end - pair.1))
        }
    }

    func testPerfectMatchAnchorsEveryWordToRecognizedTiming() {
        let script = "one two three four five"
        let rec = recognized([("one", 0), ("two", 500), ("three", 1000), ("four", 1500), ("five", 2000)])
        let result = ForcedAlignment.align(scriptText: script, recognized: rec, totalDurationMs: 2400)

        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.confidence, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.alignment.provenance, .exactFromAlignment)
        XCTAssertEqual(result.alignment.words.map(\.word), ["one", "two", "three", "four", "five"])
        XCTAssertEqual(result.alignment.words.map(\.startMs), [0, 500, 1000, 1500, 2000])
    }

    func testSubstitutedWordIsInterpolatedBetweenAnchors() {
        // The recognizer misheard "two" as "blue"; the script word stays "two"
        // and its time is interpolated between its anchored neighbors.
        let script = "one two three"
        let rec = recognized([("one", 0), ("blue", 500), ("three", 1000)])
        let result = ForcedAlignment.align(scriptText: script, recognized: rec, totalDurationMs: 1400)

        XCTAssertEqual(result.confidence, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.alignment.words[0].startMs, 0)
        XCTAssertEqual(result.alignment.words[2].startMs, 1000)
        // "two" interpolated to the midpoint between 0 and 1000.
        XCTAssertEqual(result.alignment.words[1].startMs, 500, accuracy: 1)
    }

    func testDroppedRecognitionWordStillInterpolates() {
        // The recognizer missed "two" entirely.
        let script = "one two three"
        let rec = recognized([("one", 0), ("three", 1000)])
        let result = ForcedAlignment.align(scriptText: script, recognized: rec, totalDurationMs: 1400)

        XCTAssertEqual(result.confidence, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(result.alignment.words.map(\.word), ["one", "two", "three"])
        XCTAssertEqual(result.alignment.words[0].startMs, 0)
        XCTAssertEqual(result.alignment.words[2].startMs, 1000)
        XCTAssertGreaterThan(result.alignment.words[1].startMs, 0)
        XCTAssertLessThan(result.alignment.words[1].startMs, 1000)
    }

    func testInsertedRecognitionWordIsIgnored() {
        // The recognizer inserted "and" that is not in the script.
        let script = "one three"
        let rec = recognized([("one", 0), ("and", 500), ("three", 1000)])
        let result = ForcedAlignment.align(scriptText: script, recognized: rec, totalDurationMs: 1400)

        XCTAssertEqual(result.confidence, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.alignment.words.map(\.startMs), [0, 1000])
    }

    func testTimingsAreMonotonicEvenWhenRecognizerReportsOutOfOrder() {
        let script = "alpha beta gamma"
        // beta reported slightly before alpha (recognizer jitter).
        let rec = recognized([("alpha", 600), ("beta", 400), ("gamma", 1200)])
        let result = ForcedAlignment.align(scriptText: script, recognized: rec, totalDurationMs: 1600)
        let starts = result.alignment.words.map(\.startMs)
        XCTAssertEqual(starts, starts.sorted(), "caption times must never move backward")
    }

    func testConfidenceThresholdBoundaryAcceptsAtThreshold() {
        // 3 of 5 script words anchor -> exactly 0.6, accepted.
        let script = "one two three four five"
        let rec = recognized([("one", 0), ("X", 400), ("three", 800), ("Y", 1200), ("five", 1600)])
        let result = ForcedAlignment.align(scriptText: script, recognized: rec, totalDurationMs: 2000)
        XCTAssertEqual(result.confidence, 0.6, accuracy: 0.0001)
        XCTAssertTrue(result.accepted)
    }

    func testConfidenceBelowThresholdIsRejected() {
        // Only 2 of 5 anchor -> 0.4, rejected.
        let script = "one two three four five"
        let rec = recognized([("one", 0), ("X", 400), ("Y", 800), ("Z", 1200), ("five", 1600)])
        let result = ForcedAlignment.align(scriptText: script, recognized: rec, totalDurationMs: 2000)
        XCTAssertEqual(result.confidence, 0.4, accuracy: 0.0001)
        XCTAssertFalse(result.accepted)
    }

    func testEmptyRecognitionIsRejected() {
        let result = ForcedAlignment.align(scriptText: "one two three", recognized: [], totalDurationMs: 1500)
        XCTAssertEqual(result.confidence, 0)
        XCTAssertFalse(result.accepted)
        // Still produces a plausible, monotonic fallback timeline.
        let starts = result.alignment.words.map(\.startMs)
        XCTAssertEqual(starts, starts.sorted())
    }

    func testGarbageRecognitionIsRejected() {
        let script = "alpha beta gamma"
        let rec = recognized([("zzz", 0), ("yyy", 500), ("www", 1000)])
        let result = ForcedAlignment.align(scriptText: script, recognized: rec, totalDurationMs: 1500)
        XCTAssertEqual(result.confidence, 0)
        XCTAssertFalse(result.accepted)
    }

    func testEmptyScriptProducesNoWords() {
        let result = ForcedAlignment.align(scriptText: "   ", recognized: recognized([("hi", 0)]), totalDurationMs: 500)
        XCTAssertTrue(result.alignment.words.isEmpty)
        XCTAssertFalse(result.accepted)
    }

    func testPunctuationDoesNotBlockAnchoring() {
        let script = "Codex finished, storage ready."
        let rec = recognized([("codex", 0), ("finished", 400), ("storage", 900), ("ready", 1300)])
        let result = ForcedAlignment.align(scriptText: script, recognized: rec, totalDurationMs: 1800)
        XCTAssertEqual(result.confidence, 1.0, accuracy: 0.0001)
        XCTAssertTrue(result.accepted)
    }
}
