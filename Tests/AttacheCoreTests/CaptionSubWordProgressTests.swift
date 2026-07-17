import AttacheCore
import XCTest

/// INF-364 step 3 (timing fix): tokens whose spoken duration exceeds
/// `WordTiming.subWordProgressThresholdMs` (1.2s) get sub-word fragments and a
/// proportional active-fragment index, so a long checksum shows progressive
/// highlight instead of one frozen block.
final class CaptionSubWordProgressTests: XCTestCase {
    private func checksumWord(durationMs: Int) -> WordTiming {
        WordTiming(
            word: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b85",
            startMs: 1000,
            durationMs: durationMs,
            charStart: 0,
            charEnd: 64
        )
    }

    func testShortWordBelowThresholdStaysASingleFragment() {
        let word = checksumWord(durationMs: 900) // below the 1200ms threshold
        let fragments = word.subWordFragments()
        XCTAssertEqual(fragments, [0..<64])
    }

    func testLongWordAboveThresholdSplitsIntoMultipleFragments() {
        let word = checksumWord(durationMs: 2400) // above the threshold
        let fragments = word.subWordFragments(maxFragmentChars: 10)
        XCTAssertGreaterThan(fragments.count, 1)
    }

    func testFragmentsCoverTheFullTokenWithNoGapOrOverlap() {
        let word = checksumWord(durationMs: 2400)
        let fragments = word.subWordFragments(maxFragmentChars: 10)

        XCTAssertEqual(fragments.first?.lowerBound, word.charStart)
        XCTAssertEqual(fragments.last?.upperBound, word.charEnd)
        for pair in zip(fragments, fragments.dropFirst()) {
            XCTAssertEqual(pair.0.upperBound, pair.1.lowerBound, "fragment boundaries must be contiguous")
        }
    }

    func testFragmentCountScalesWithTokenLength() {
        let shortToken = WordTiming(word: "abcdefghijk", startMs: 0, durationMs: 1500, charStart: 0, charEnd: 11)
        let longToken = checksumWord(durationMs: 2400) // 64 chars

        let shortFragments = shortToken.subWordFragments(maxFragmentChars: 10)
        let longFragments = longToken.subWordFragments(maxFragmentChars: 10)

        XCTAssertGreaterThan(longFragments.count, shortFragments.count)
    }

    func testActiveFragmentIndexIsMonotonicNonDecreasingAsTimeElapses() {
        let word = checksumWord(durationMs: 2400)
        let fragments = word.subWordFragments(maxFragmentChars: 10)
        XCTAssertGreaterThan(fragments.count, 1, "test assumes a multi-fragment token")

        var lastIndex = -1
        for elapsed in stride(from: 0, through: word.durationMs, by: 50) {
            let index = word.activeSubWordFragmentIndex(elapsedMsSinceWordStart: elapsed, fragments: fragments)
            XCTAssertGreaterThanOrEqual(index, lastIndex, "active fragment index must never move backward")
            XCTAssertGreaterThanOrEqual(index, 0)
            XCTAssertLessThan(index, fragments.count)
            lastIndex = index
        }
    }

    func testActiveFragmentIndexReachesTheLastFragmentByTheEndOfTheWord() {
        let word = checksumWord(durationMs: 2400)
        let fragments = word.subWordFragments(maxFragmentChars: 10)
        let index = word.activeSubWordFragmentIndex(elapsedMsSinceWordStart: word.durationMs, fragments: fragments)
        XCTAssertEqual(index, fragments.count - 1)
    }

    func testActiveFragmentIndexStartsAtZeroAtWordStart() {
        let word = checksumWord(durationMs: 2400)
        let fragments = word.subWordFragments(maxFragmentChars: 10)
        let index = word.activeSubWordFragmentIndex(elapsedMsSinceWordStart: 0, fragments: fragments)
        XCTAssertEqual(index, 0)
    }

    func testActiveFragmentIndexClampsOutOfRangeElapsedTime() {
        let word = checksumWord(durationMs: 2400)
        let fragments = word.subWordFragments(maxFragmentChars: 10)
        XCTAssertEqual(
            word.activeSubWordFragmentIndex(elapsedMsSinceWordStart: -500, fragments: fragments),
            0
        )
        XCTAssertEqual(
            word.activeSubWordFragmentIndex(elapsedMsSinceWordStart: 100_000, fragments: fragments),
            fragments.count - 1
        )
    }

    func testSingleFragmentAlwaysReportsIndexZero() {
        let word = checksumWord(durationMs: 900)
        let fragments = word.subWordFragments() // below threshold: one fragment
        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(word.activeSubWordFragmentIndex(elapsedMsSinceWordStart: 450, fragments: fragments), 0)
    }
}
