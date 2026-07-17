import AttacheCore
import XCTest

/// INF-364 characterization + regression suite. Each torture fixture is checked
/// against four invariants of `CaptionAlignmentBuilder.fallback` output:
///
///   1. monotonic    - words never overlap in time (each word's end <= the next
///                      word's start)
///   2. spans         - the last word ends exactly at totalDurationMs
///   3. nonZero       - no word has a zero (or negative) duration
///   4. withinBounds  - no single word's duration exceeds the utterance's total
///                      duration
///
/// Characterization table (recorded before the INF-364 fixes; the fixtures and
/// this table were built first, against the unmodified `CaptionAlignmentBuilder`
/// and `CaptionWordView`, per the ticket's testing-first requirement):
///
/// | Fixture                              | monotonic | spans | nonZero | withinBounds | notes |
/// |---------------------------------------|:---:|:---:|:---:|:---:|-------|
/// | 64-char hex checksum                  | PASS | PASS | PASS | PASS | one giant WordTiming for the checksum; display fills the box (fixed by CaptionTokenLayout + subWordFragments, not an invariant failure) |
/// | full https URL with query params      | PASS | PASS | PASS | PASS | technicalSegments splits at `/`, `?`, `&`, `=`, `.`; timing invariants already held |
/// | long camelCase identifier             | PASS | PASS | PASS | PASS | technicalSegments already splits at case boundaries |
/// | long decimal number string            | PASS | PASS | PASS | PASS | technicalSegments splits at the digit/`.` boundary |
/// | emoji sequence                        | PASS | PASS | PASS | PASS | no whitespace between glyphs, but the run is short in Character count so it clears without splitting; no invariant break |
/// | Korean text (ko localization)         | PASS | PASS | PASS | PASS | Korean is a spaced language (eojeol); ordinary whitespace splitting already produces multiple caption words, no CJK-specific path involved |
/// | Chinese text, spaceless run            | PASS | PASS | PASS | PASS | timing invariants held even though segmentation was broken: with `enumerateSubstrings(options: [.byWords, .localized])`, the WHOLE 33-character run came back as a single caption word (verified by first running this suite against the unmodified segmenter). That is audit item (d)'s FAIL case: genuinely spaceless CJK script (Chinese/Japanese), not Korean, is where it bites. Fixed by switching the spaceless-run segmenter to `NLTokenizer`, which has dictionary-based word breaking for Chinese/Japanese/Thai (see testCJKSegmentationProducesMultipleUnits below, now passing against the fixed segmenter) |
/// | Spanish accented text                 | PASS | PASS | PASS | PASS | whitespace-delimited, accents do not affect Character-based ranges |
/// | mixed English plus checksum sentence  | PASS | PASS | PASS | PASS | same as the standalone checksum case |
/// | word longer than any caption line     | PASS | PASS | PASS | PASS | no separators or case boundaries at all, so it stays one WordTiming; display fills/overflows the box (fixed by CaptionTokenLayout, not an invariant failure) |
///
/// All ten fixtures pass the four *timing data* invariants (monotonic, spans,
/// nonZero, withinBounds), both before and after the fixes in this ticket: the
/// alignment builder never produced overlapping, zero-duration, or
/// bounds-exceeding words, even for the spaceless Chinese fixture. What WAS
/// broken, found by running this exact suite against the unmodified segmenter
/// before making any fix, was CJK word segmentation itself (audit item 4d):
/// the spaceless Chinese fixture collapsed into a single 33-character caption
/// token instead of multiple caption units, because
/// `String.enumerateSubstrings(options: [.byWords, .localized])` does not
/// sub-segment a CJK run with no dictionary-based analysis. That is fixed by
/// switching the spaceless-run segmenter to `NLTokenizer` in
/// `CaptionAlignmentBuilder.segmented`, per this ticket's explicit fallback
/// instruction; `NLTokenizer` has dictionary-based word breaking for Chinese,
/// Japanese, and Thai. Korean is a spaced language (eojeol boundaries carry
/// spaces in normal writing) and was never broken: the Korean fixture already
/// produces multiple caption words from ordinary whitespace splitting. An
/// artificially space-stripped Hangul run was also tried during
/// characterization, and neither the old segmenter nor `NLTokenizer` (with or
/// without an explicit Korean language hint) can sub-segment it: unspaced
/// Korean word segmentation needs morphological analysis, not word-boundary
/// tokenization, which is out of scope here for the same reason phoneme-level
/// alignment is (see the REVIEW NEEDED note posted to INF-364). The checksum
/// and too-long-word fixtures separately surface a *display* bug (a single
/// caption token can fill or overflow the box) and a *pacing* bug (that
/// single token highlights as one frozen block for its whole, possibly long,
/// duration). Those are steps 2 and 3 of this ticket, fixed and tested
/// separately in CaptionOversizedTokenLayoutTests and
/// CaptionSubWordProgressTests, not by changing the invariants above.
final class CaptionTortureFixtureTests: XCTestCase {
    private func assertInvariants(
        _ fixture: CaptionTortureFixtures.Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let alignment = CaptionAlignmentBuilder.fallback(text: fixture.text, durationMs: 6000)
        let words = alignment.words
        guard !words.isEmpty else {
            XCTFail("\(fixture.name): produced no words at all", file: file, line: line)
            return
        }

        // 1. monotonic
        for pair in zip(words, words.dropFirst()) {
            XCTAssertLessThanOrEqual(
                pair.0.startMs + pair.0.durationMs, pair.1.startMs,
                "\(fixture.name): words overlap in time", file: file, line: line
            )
        }

        // 2. spans the full utterance
        let last = words[words.count - 1]
        XCTAssertEqual(
            last.startMs + last.durationMs, alignment.totalDurationMs,
            "\(fixture.name): timings do not cover the full utterance span",
            file: file, line: line
        )

        // 3. no zero-duration words
        for word in words {
            XCTAssertGreaterThan(
                word.durationMs, 0,
                "\(fixture.name): word '\(word.word)' has zero duration",
                file: file, line: line
            )
        }

        // 4. no word exceeds the utterance's total duration
        for word in words {
            XCTAssertLessThanOrEqual(
                word.durationMs, alignment.totalDurationMs,
                "\(fixture.name): word '\(word.word)' exceeds the total utterance duration",
                file: file, line: line
            )
        }

        // Fragments always losslessly cover the original text: no character is
        // dropped or duplicated by segmentation, regardless of fixture.
        let recombined = words.map(\.word).joined(separator: "")
        let sourceCollapsed = fixture.text.replacingOccurrences(of: " ", with: "")
        XCTAssertEqual(
            recombined.replacingOccurrences(of: " ", with: ""),
            sourceCollapsed,
            "\(fixture.name): segmentation lost or duplicated characters",
            file: file, line: line
        )
    }

    func testAllTortureFixturesSatisfyTimingInvariants() {
        for fixture in CaptionTortureFixtures.all {
            assertInvariants(fixture)
        }
    }

    func testCJKSegmentationProducesMultipleUnits() {
        // Audit check (d): CJK/spaceless-script segmentation must not collapse
        // into one giant caption token. This locks in the NLTokenizer-based
        // spaceless-run splitter's behavior on the genuinely spaceless Chinese
        // fixture (the case that was actually broken; see the characterization
        // table above).
        let alignment = CaptionAlignmentBuilder.fallback(
            text: CaptionTortureFixtures.spacelessCJKText.text,
            durationMs: 6000
        )
        XCTAssertGreaterThan(
            alignment.words.count, 1,
            "spaceless Chinese text collapsed into a single caption unit: \(alignment.words.map(\.word))"
        )
    }

    func testKoreanSpacedTextSegmentsOnWhitespaceLikeAnyOtherLanguage() {
        let alignment = CaptionAlignmentBuilder.fallback(
            text: CaptionTortureFixtures.cjkText.text,
            durationMs: 6000
        )
        XCTAssertGreaterThan(
            alignment.words.count, 1,
            "spaced Korean text unexpectedly stayed a single caption unit: \(alignment.words.map(\.word))"
        )
    }

    func testChecksumStillProducesASingleOversizedWordTiming() {
        // Documents the known weak spot precisely: the alignment builder does
        // not (and per this ticket's scope, should not) split a checksum by
        // timing data, because it has no separators or case boundaries for the
        // technical segmenter to use. The display and pacing fixes operate on
        // this single WordTiming instead of trying to fabricate word
        // boundaries that do not exist in the source text.
        let alignment = CaptionAlignmentBuilder.fallback(
            text: CaptionTortureFixtures.hexChecksum.text,
            durationMs: 6000
        )
        let checksumWord = alignment.words.first { $0.word.count > 40 }
        XCTAssertNotNil(checksumWord, "expected the checksum to remain a single long WordTiming")
    }

    func testWordLongerThanAnyCaptionLineStillProducesASingleOversizedWordTiming() {
        let alignment = CaptionAlignmentBuilder.fallback(
            text: CaptionTortureFixtures.wordLongerThanAnyCaptionLine.text,
            durationMs: 6000
        )
        XCTAssertEqual(alignment.words.count, 1, "expected the unbroken word to remain a single WordTiming")
        XCTAssertGreaterThan(alignment.words[0].word.count, 90)
    }
}
