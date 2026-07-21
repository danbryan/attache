import AttacheCore
import XCTest

final class CaptionRenderDecisionTests: XCTestCase {
    func testCaptionsOffHidesRegardlessOfStyleOrProvenance() {
        for style in CaptionStyle.allCases {
            for provenance in [CaptionTimingProvenance.exactFromEngine, .exactFromAlignment, .estimated] {
                XCTAssertEqual(
                    CaptionRenderDecision.mode(captionsEnabled: false, style: style, provenance: provenance),
                    .hidden
                )
            }
        }
    }

    func testEstimatedKaraokeDegradesToPlain() {
        XCTAssertEqual(
            CaptionRenderDecision.mode(captionsEnabled: true, style: .karaoke, provenance: .estimated),
            .plain
        )
    }

    func testExactKaraokeRendersKaraoke() {
        XCTAssertEqual(
            CaptionRenderDecision.mode(captionsEnabled: true, style: .karaoke, provenance: .exactFromEngine),
            .karaoke
        )
        XCTAssertEqual(
            CaptionRenderDecision.mode(captionsEnabled: true, style: .karaoke, provenance: .exactFromAlignment),
            .karaoke
        )
    }

    func testPlainStyleAlwaysRendersPlainEvenWhenExact() {
        XCTAssertEqual(
            CaptionRenderDecision.mode(captionsEnabled: true, style: .plain, provenance: .exactFromEngine),
            .plain
        )
        XCTAssertEqual(
            CaptionRenderDecision.mode(captionsEnabled: true, style: .plain, provenance: .estimated),
            .plain
        )
    }

    func testProvenanceIsExactFlag() {
        XCTAssertTrue(CaptionTimingProvenance.exactFromEngine.isExact)
        XCTAssertTrue(CaptionTimingProvenance.exactFromAlignment.isExact)
        XCTAssertFalse(CaptionTimingProvenance.estimated.isExact)
    }
}

final class CaptionAlignmentProvenanceCodingTests: XCTestCase {
    func testFallbackAlignmentIsEstimated() {
        let alignment = CaptionAlignmentBuilder.fallback(text: "one two three", durationMs: 1500)
        XCTAssertEqual(alignment.provenance, .estimated)
    }

    func testRoundTripPreservesProvenance() throws {
        let alignment = CaptionAlignment(
            text: "one two",
            words: [
                WordTiming(word: "one", startMs: 0, durationMs: 500, charStart: 0, charEnd: 3),
                WordTiming(word: "two", startMs: 500, durationMs: 500, charStart: 4, charEnd: 7)
            ],
            totalDurationMs: 1000,
            provenance: .exactFromAlignment
        )
        let data = try JSONEncoder().encode(alignment)
        let decoded = try JSONDecoder().decode(CaptionAlignment.self, from: data)
        XCTAssertEqual(decoded, alignment)
        XCTAssertEqual(decoded.provenance, .exactFromAlignment)
    }

    func testLegacyJSONWithoutProvenanceDecodesAsEstimated() throws {
        // A payload persisted before provenance existed.
        let json = """
        {"text":"hi there","total_duration_ms":900,"words":[{"word":"hi","start_ms":0,"duration_ms":400,"char_start":0,"char_end":2},{"word":"there","start_ms":400,"duration_ms":500,"char_start":3,"char_end":8}]}
        """
        let decoded = try JSONDecoder().decode(CaptionAlignment.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.provenance, .estimated)
        XCTAssertEqual(decoded.words.count, 2)
    }

    func testFromCharacterTimingsIsExactFromEngine() throws {
        // "hi bye": characters with per-character timings (ElevenLabs shape).
        let characters = ["h", "i", " ", "b", "y", "e"]
        let starts = [0.0, 0.1, 0.2, 0.3, 0.5, 0.7]
        let ends = [0.1, 0.2, 0.3, 0.5, 0.7, 0.9]
        let alignment = try XCTUnwrap(CaptionAlignmentBuilder.fromCharacterTimings(
            text: "hi bye",
            characters: characters,
            startTimesSec: starts,
            endTimesSec: ends
        ))
        XCTAssertEqual(alignment.provenance, .exactFromEngine)
        XCTAssertEqual(alignment.words.map(\.word), ["hi", "bye"])
        XCTAssertEqual(alignment.words[0].startMs, 0)
        XCTAssertEqual(alignment.words[1].startMs, 300)
        XCTAssertEqual(alignment.totalDurationMs, 900)
    }

    func testFromCharacterTimingsRejectsMismatchedArrays() {
        XCTAssertNil(CaptionAlignmentBuilder.fromCharacterTimings(
            text: "hi",
            characters: ["h", "i"],
            startTimesSec: [0.0],
            endTimesSec: [0.1, 0.2]
        ))
    }
}
