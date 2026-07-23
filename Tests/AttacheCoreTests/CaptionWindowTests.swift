import AttacheCore
import XCTest

/// Regression tests for the bottom karaoke caption window (INF-caption-window).
///
/// The bug: the bottom caption kept its window position in view `@State` that was
/// only nudged from an `onChange(currentTimeMs)` side effect, so when that update
/// was skipped the window stranded at word 0 while the clock (and the full-message
/// transcript panel, which derives its highlight purely) kept advancing. The window
/// is now a pure function of the clock; these tests pin that behavior.
final class CaptionWindowTests: XCTestCase {
    private func alignment(sentenceCount: Int, wordsPerSentence: Int) -> CaptionAlignment {
        var words: [WordTiming] = []
        var cursor = 0
        var t = 0
        for s in 0..<sentenceCount {
            for w in 0..<wordsPerSentence {
                let text = "s\(s)w\(w)"
                let start = cursor
                let end = cursor + text.count
                words.append(WordTiming(word: text, startMs: t, durationMs: 200, charStart: start, charEnd: end))
                cursor = end + 1
                t += 200
            }
        }
        return CaptionAlignment(
            text: words.map(\.word).joined(separator: " "),
            words: words,
            totalDurationMs: t,
            provenance: .exactFromAlignment
        )
    }

    // MARK: - Pure window math

    func testShortMessageNeverPagesAndStaysAtZero() {
        // Whole message fits in the window: always show from the start.
        for anchor in 0..<10 {
            XCTAssertEqual(CaptionWindow.start(wordCount: 10, windowSize: 15, anchor: anchor), 0)
        }
    }

    func testHoldsAtStartWhileAnchorInsideFirstWindow() {
        // Anchor 0..<(windowSize - trigger) holds the window at 0.
        for anchor in 0..<13 {
            XCTAssertEqual(CaptionWindow.start(wordCount: 120, windowSize: 15, anchor: anchor), 0)
        }
    }

    func testLateAnchorProducesWindowContainingIt() {
        // The core regression: a late active word must be inside the window, never
        // stranded behind it at word 0.
        let count = 120, windowSize = 15
        for anchor in [13, 20, 40, 60, 90, 119] {
            let start = CaptionWindow.start(wordCount: count, windowSize: windowSize, anchor: anchor)
            XCTAssertGreaterThan(start, 0, "anchor \(anchor) should have paged past the start")
            XCTAssert(start <= anchor && anchor < start + windowSize,
                      "anchor \(anchor) not inside window [\(start), \(start + windowSize))")
        }
    }

    func testWindowNeverExceedsMaxStart() {
        let count = 30, windowSize = 15
        let maxStart = count - windowSize
        for anchor in 0..<count {
            let start = CaptionWindow.start(wordCount: count, windowSize: windowSize, anchor: anchor)
            XCTAssert(start >= 0 && start <= maxStart, "start \(start) out of [0, \(maxStart)] for anchor \(anchor)")
            XCTAssert(start <= anchor && anchor < start + windowSize,
                      "anchor \(anchor) not inside window [\(start), \(start + windowSize))")
        }
    }

    func testWindowPagesRatherThanScrollingEveryWord() {
        // Consecutive anchors inside the same page share a window start (paging),
        // and the start is monotonic as the anchor advances (never jumps back).
        let count = 200, windowSize = 15
        var previous = -1
        var distinctStarts = Set<Int>()
        for anchor in 0..<count {
            let start = CaptionWindow.start(wordCount: count, windowSize: windowSize, anchor: anchor)
            XCTAssertGreaterThanOrEqual(start, previous, "window moved backward at anchor \(anchor)")
            previous = start
            distinctStarts.insert(start)
        }
        // Far fewer distinct positions than words: it pages, it does not scroll.
        XCTAssertLessThan(distinctStarts.count, count / 3)
    }

    func testAnchorClampedForOutOfRangeInput() {
        XCTAssertEqual(CaptionWindow.start(wordCount: 120, windowSize: 15, anchor: -5), 0)
        let start = CaptionWindow.start(wordCount: 120, windowSize: 15, anchor: 999)
        XCTAssertEqual(start, 120 - 15)
    }

    func testZeroWindowSizeIsSafe() {
        XCTAssertEqual(CaptionWindow.start(wordCount: 120, windowSize: 0, anchor: 40), 0)
    }

    // MARK: - End to end from the clock (exact timings)

    func testWindowTracksActiveWordDrivenByClock() {
        // Build a multi-sentence message with exact timings, drive the clock to a
        // late word, and assert the derived window contains that active word,
        // reproducing the reported scenario at the unit level.
        let a = alignment(sentenceCount: 6, wordsPerSentence: 10) // 60 words
        let windowSize = 15

        // Late word: index 42 -> starts at 42 * 200ms.
        let lateTimeMs = 42 * 200 + 50
        let anchor = a.captionAnchorIndex(at: lateTimeMs)
        XCTAssertEqual(anchor, 42)
        let start = CaptionWindow.start(wordCount: a.words.count, windowSize: windowSize, anchor: anchor)
        XCTAssert(start <= 42 && 42 < start + windowSize, "late active word 42 not in window [\(start), \(start + windowSize))")
        XCTAssertGreaterThan(start, 0, "window should have advanced well past the first sentence")
    }

    func testWindowTracksAcrossSentenceBoundaries() {
        let a = alignment(sentenceCount: 6, wordsPerSentence: 10)
        let windowSize = 15
        var lastStart = 0
        // Step the clock across the whole message; the active word must always be
        // visible and the window must be monotonic.
        for index in 0..<a.words.count {
            let t = index * 200 + 10
            let anchor = a.captionAnchorIndex(at: t)
            let start = CaptionWindow.start(wordCount: a.words.count, windowSize: windowSize, anchor: anchor)
            XCTAssert(start <= anchor && anchor < start + windowSize,
                      "active word \(anchor) not in window [\(start), \(start + windowSize)) at t=\(t)")
            XCTAssertGreaterThanOrEqual(start, lastStart)
            lastStart = start
        }
    }

    func testFreshAppearanceMidMessageIsNotStrandedAtZero() {
        // The stranding case: the karaoke window first appears when the clock is
        // already deep into the message (captions toggled on, or estimated->exact
        // upgrade). A pure derivation shows the right window immediately; there is
        // no @State to be stuck at 0.
        let a = alignment(sentenceCount: 6, wordsPerSentence: 10)
        let windowSize = 15
        let midTimeMs = 35 * 200 + 20
        let anchor = a.captionAnchorIndex(at: midTimeMs)
        let start = CaptionWindow.start(wordCount: a.words.count, windowSize: windowSize, anchor: anchor)
        XCTAssertGreaterThan(start, 0)
        XCTAssert(start <= anchor && anchor < start + windowSize)
    }

    func testAnchorBeforeAnyWordStartIsZero() {
        let a = alignment(sentenceCount: 6, wordsPerSentence: 10)
        XCTAssertEqual(a.captionAnchorIndex(at: -100), 0)
        XCTAssertEqual(CaptionWindow.start(wordCount: a.words.count, windowSize: 15, anchor: 0), 0)
    }
}
