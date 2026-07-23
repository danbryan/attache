import Foundation
import NaturalLanguage

public struct WordTiming: Codable, Equatable, Identifiable {
    public var id: String { "\(charStart)-\(charEnd)-\(word)" }
    public var word: String
    public var startMs: Int
    public var durationMs: Int
    public var charStart: Int
    public var charEnd: Int

    public init(word: String, startMs: Int, durationMs: Int, charStart: Int, charEnd: Int) {
        self.word = word
        self.startMs = startMs
        self.durationMs = durationMs
        self.charStart = charStart
        self.charEnd = charEnd
    }

    enum CodingKeys: String, CodingKey {
        case word
        case startMs = "start_ms"
        case durationMs = "duration_ms"
        case charStart = "char_start"
        case charEnd = "char_end"
    }
}

/// Where a caption's word timings came from, so the renderer can decide whether
/// karaoke word-highlighting is honest for this clip. `estimated` timing drifts
/// against the spoken audio and must not drive a per-word bounce; exact timing
/// (either supplied by the TTS engine or recovered by on-device forced
/// alignment) may. See `CaptionRenderDecision`.
public enum CaptionTimingProvenance: String, Codable, Equatable, Sendable {
    /// Real per-character/word timing the synthesis engine returned (ElevenLabs
    /// with-timestamps). Exact.
    case exactFromEngine = "exact_from_engine"
    /// Timing recovered by running on-device speech recognition over the
    /// synthesized clip and mapping recognized words back onto the known script.
    /// Exact.
    case exactFromAlignment = "exact_from_alignment"
    /// Heuristic timing derived from the text alone (`CaptionAlignmentBuilder`).
    /// Not exact; karaoke degrades to plain until an exact timeline is available.
    case estimated

    /// True when the timing is trustworthy enough to karaoke word by word.
    public var isExact: Bool { self != .estimated }
}

public struct CaptionAlignment: Codable, Equatable {
    public var text: String
    public var words: [WordTiming]
    public var totalDurationMs: Int
    /// How this alignment's word timings were produced. Defaults to `estimated`
    /// and is decoded leniently so alignments persisted before this field
    /// existed load as estimated rather than failing to decode.
    public var provenance: CaptionTimingProvenance

    public init(
        text: String,
        words: [WordTiming],
        totalDurationMs: Int,
        provenance: CaptionTimingProvenance = .estimated
    ) {
        self.text = text
        self.words = words
        self.totalDurationMs = totalDurationMs
        self.provenance = provenance
    }

    enum CodingKeys: String, CodingKey {
        case text
        case words
        case totalDurationMs = "total_duration_ms"
        case provenance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        words = try container.decode([WordTiming].self, forKey: .words)
        totalDurationMs = try container.decode(Int.self, forKey: .totalDurationMs)
        provenance = try container.decodeIfPresent(CaptionTimingProvenance.self, forKey: .provenance) ?? .estimated
    }

    public func activeWordIndex(at currentTimeMs: Int) -> Int? {
        words.firstIndex { word in
            let end = word.startMs + max(80, word.durationMs)
            return currentTimeMs >= word.startMs && currentTimeMs < end
        }
    }

    /// The word the karaoke caption window should track at `currentTimeMs`: the
    /// active word, else the last word already started (so the window still
    /// tracks in the silent gaps between words), else the first word. Pure so the
    /// bottom caption can derive its window straight from the clock the same way
    /// the full-message transcript derives its highlight, rather than accumulating
    /// a window position through view side effects that can be stranded.
    public func captionAnchorIndex(at currentTimeMs: Int) -> Int {
        activeWordIndex(at: currentTimeMs)
            ?? words.lastIndex { currentTimeMs >= $0.startMs }
            ?? 0
    }

    public func captionSegments(fallbackText: String, currentTimeMs: Int) -> [CaptionSegment] {
        let sourceText = text.isEmpty ? fallbackText : text
        guard !words.isEmpty else {
            return sourceText.isEmpty ? [] : [CaptionSegment(text: sourceText, isActive: false)]
        }

        let activeIndex = activeWordIndex(at: currentTimeMs)
        var cursor = 0
        var segments: [CaptionSegment] = []

        for (index, word) in words.enumerated() {
            let safeStart = max(0, min(sourceText.count, word.charStart))
            let safeEnd = max(safeStart, min(sourceText.count, word.charEnd))

            if safeStart > cursor {
                appendSegment(sourceText.characterSlice(from: cursor, to: safeStart), active: false, to: &segments)
            }

            let wordText = sourceText.characterSlice(from: safeStart, to: safeEnd)
            appendSegment(wordText.isEmpty ? word.word : wordText, active: index == activeIndex, to: &segments)
            cursor = safeEnd
        }

        if cursor < sourceText.count {
            appendSegment(sourceText.characterSlice(from: cursor, to: sourceText.count), active: false, to: &segments)
        }

        return segments
    }

    public func windowedCaptionSegments(
        fallbackText: String,
        currentTimeMs: Int,
        leadingWords: Int = 8,
        trailingWords: Int = 12
    ) -> [CaptionSegment] {
        let sourceText = text.isEmpty ? fallbackText : text
        guard !sourceText.isEmpty else { return [] }
        guard !words.isEmpty else {
            return [CaptionSegment(text: sourceText, isActive: false)]
        }

        let activeIndex = activeWordIndex(at: currentTimeMs)
        let anchor = activeIndex
            ?? words.lastIndex { currentTimeMs >= $0.startMs }
            ?? 0
        let startWord = max(0, anchor - max(0, leadingWords))
        let endWord = min(words.count - 1, anchor + max(0, trailingWords))
        let startChar = max(0, min(sourceText.count, words[startWord].charStart))
        let endChar = max(startChar, min(sourceText.count, words[endWord].charEnd))

        var cursor = startChar
        var segments: [CaptionSegment] = []
        if startWord > 0 {
            appendSegment("... ", active: false, to: &segments)
        }

        for index in startWord...endWord {
            let word = words[index]
            let safeStart = max(startChar, min(endChar, word.charStart))
            let safeEnd = max(safeStart, min(endChar, word.charEnd))

            if safeStart > cursor {
                appendSegment(sourceText.characterSlice(from: cursor, to: safeStart), active: false, to: &segments)
            }

            let wordText = sourceText.characterSlice(from: safeStart, to: safeEnd)
            appendSegment(wordText.isEmpty ? word.word : wordText, active: index == activeIndex, to: &segments)
            cursor = safeEnd
        }

        if endWord < words.count - 1 {
            appendSegment(" ...", active: false, to: &segments)
        } else if cursor < sourceText.count {
            appendSegment(sourceText.characterSlice(from: cursor, to: sourceText.count), active: false, to: &segments)
        }

        return segments
    }

    private func appendSegment(_ text: String, active: Bool, to segments: inout [CaptionSegment]) {
        guard !text.isEmpty else { return }
        segments.append(CaptionSegment(text: text, isActive: active))
    }

    /// The same sliding window as `windowedCaptionSegments`, but as individual
    /// word timings so the UI can make each word tappable (click to seek to it).
    public func windowedWords(
        currentTimeMs: Int,
        leadingWords: Int = 7,
        trailingWords: Int = 10
    ) -> CaptionWordWindow {
        guard !words.isEmpty else {
            return CaptionWordWindow(words: [], activeID: nil, hasLeading: false, hasTrailing: false)
        }
        let activeIndex = activeWordIndex(at: currentTimeMs)
        let anchor = activeIndex
            ?? words.lastIndex { currentTimeMs >= $0.startMs }
            ?? 0
        let startWord = max(0, anchor - max(0, leadingWords))
        let endWord = min(words.count - 1, anchor + max(0, trailingWords))
        return CaptionWordWindow(
            words: Array(words[startWord...endWord]),
            activeID: activeIndex.map { words[$0].id },
            hasLeading: startWord > 0,
            hasTrailing: endWord < words.count - 1
        )
    }
}

public extension WordTiming {
    /// Spoken duration above which a token gets sub-word progressive highlighting
    /// instead of being treated as a single frozen highlight block (INF-364). A
    /// long checksum or URL can legitimately take over a second to read; without
    /// this the whole token lights up at once and stays lit for that whole time.
    static let subWordProgressThresholdMs = 1200

    /// Splits this token's character range into roughly equal fragments so a long
    /// unbreakable token (checksum, URL, identifier) can be highlighted
    /// progressively as it is read, rather than as a single block. Only tokens
    /// whose spoken duration exceeds `subWordProgressThresholdMs` are split; short
    /// tokens return their own full range as the single fragment. Fragments
    /// together exactly cover `charStart..<charEnd` with no gap or overlap.
    func subWordFragments(maxFragmentChars: Int = 10) -> [Range<Int>] {
        let length = charEnd - charStart
        guard durationMs > Self.subWordProgressThresholdMs, length > maxFragmentChars else {
            return [charStart..<charEnd]
        }
        let fragmentCount = max(1, Int((Double(length) / Double(maxFragmentChars)).rounded(.up)))
        var fragments: [Range<Int>] = []
        var cursor = charStart
        for index in 0..<fragmentCount {
            let remainingFragments = fragmentCount - index
            let charsLeft = charEnd - cursor
            let size = Int((Double(charsLeft) / Double(remainingFragments)).rounded(.up))
            let end = index == fragmentCount - 1 ? charEnd : min(charEnd, cursor + max(1, size))
            guard cursor < end else { continue }
            fragments.append(cursor..<end)
            cursor = end
        }
        return fragments.isEmpty ? [charStart..<charEnd] : fragments
    }

    /// Given elapsed time since this word started speaking, the index into
    /// `fragments` that should currently be highlighted. Proportional to elapsed
    /// time across the word's spoken duration, clamped to a valid index, and
    /// monotonically non-decreasing as `elapsedMsSinceWordStart` increases.
    func activeSubWordFragmentIndex(elapsedMsSinceWordStart: Int, fragments: [Range<Int>]) -> Int {
        activeSubWordFragmentIndex(elapsedMsSinceWordStart: elapsedMsSinceWordStart, fragmentCount: fragments.count)
    }

    /// Same proportional math as the `fragments:` overload above, for callers
    /// (like the caption rendering view's own box-width-based fragment split)
    /// that only need the fragment count, not the character ranges themselves.
    func activeSubWordFragmentIndex(elapsedMsSinceWordStart: Int, fragmentCount: Int) -> Int {
        guard fragmentCount > 1 else { return 0 }
        guard durationMs > 0 else { return 0 }
        let clampedElapsed = max(0, min(durationMs, elapsedMsSinceWordStart))
        let progress = Double(clampedElapsed) / Double(durationMs)
        let index = Int(progress * Double(fragmentCount))
        return max(0, min(fragmentCount - 1, index))
    }
}

/// Pure layout math for wrapping a single unbreakable caption token (a checksum,
/// URL, or long identifier) into fragments that each fit within the caption box,
/// so the rendering view can wrap mid-token instead of overflowing or collapsing
/// the box (INF-364). SwiftUI text measurement is not available in AttacheCore,
/// so this uses a deliberately conservative average character-width estimate;
/// the view is still free to further shrink a fragment, but wrapping to a new
/// flow line means a single token can never exceed the box width by itself.
public enum CaptionTokenLayout {
    /// Rough average advance width of one character at `fontSize`, as a fraction
    /// of the font size. Conservative (wide) on purpose so estimated fragments
    /// undershoot rather than overshoot the box.
    private static let averageCharacterWidthFactor: Double = 0.62

    /// Safety margin so an estimated-to-fit fragment has room for measurement
    /// error without touching the box edge.
    private static let boxWidthUsageFactor: Double = 0.92

    /// How many characters of a token can be expected to fit in `boxWidth` at
    /// `fontSize`, using the conservative average-width estimate above.
    public static func fragmentCharacterCount(boxWidth: Double, fontSize: Double) -> Int {
        guard boxWidth > 0, fontSize > 0 else { return 1 }
        let averageCharWidth = fontSize * averageCharacterWidthFactor
        let usableWidth = boxWidth * boxWidthUsageFactor
        return max(1, Int((usableWidth / averageCharWidth).rounded(.down)))
    }

    /// Splits `token` into fragments that each fit within `boxWidth` at
    /// `fontSize`. Tokens that already fit are returned unsplit. Fragments
    /// concatenate back to exactly `token` with no character lost or duplicated.
    public static func fragments(for token: String, boxWidth: Double, fontSize: Double) -> [String] {
        let maxChars = fragmentCharacterCount(boxWidth: boxWidth, fontSize: fontSize)
        guard token.count > maxChars else { return [token] }

        var fragments: [String] = []
        var remaining = Substring(token)
        while !remaining.isEmpty {
            let count = min(maxChars, remaining.count)
            let end = remaining.index(remaining.startIndex, offsetBy: count)
            fragments.append(String(remaining[remaining.startIndex..<end]))
            remaining = remaining[end...]
        }
        return fragments
    }
}

public struct CaptionWordWindow: Equatable {
    public let words: [WordTiming]
    public let activeID: String?
    public let hasLeading: Bool
    public let hasTrailing: Bool

    public init(words: [WordTiming], activeID: String?, hasLeading: Bool, hasTrailing: Bool) {
        self.words = words
        self.activeID = activeID
        self.hasLeading = hasLeading
        self.hasTrailing = hasTrailing
    }
}

public struct CaptionSegment: Equatable {
    public let text: String
    public let isActive: Bool

    public init(text: String, isActive: Bool) {
        self.text = text
        self.isActive = isActive
    }
}

/// Formats a caption word's start time for the hover-scrub tooltip
/// (INF-365): hovering a karaoke or transcript word shows "m:ss" so the
/// click-to-jump target is legible before the click, without changing the
/// existing click/double-click behavior.
public enum CaptionTimestampFormatter {
    public static func format(ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// User choice for how captions render (INF caption controls). `karaoke`
/// highlights each word as it is spoken when the timing is exact; `plain` never
/// highlights individual words. Persisted app-side.
public enum CaptionStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case karaoke
    case plain

    public var id: String { rawValue }

    /// Menu label shown in Settings.
    public var title: String {
        switch self {
        case .karaoke: return "Karaoke (highlight each word)"
        case .plain: return "Plain (no word highlight)"
        }
    }
}

/// How the caption surface should render for the current clip, given the user's
/// on/off and style choices and the active timeline's timing provenance. Kept a
/// pure decision so the honest-degrade rule is unit-tested without a view.
public enum CaptionRenderMode: Equatable, Sendable {
    /// Captions are off: render nothing during playback.
    case hidden
    /// Show the caption text without per-word highlighting.
    case plain
    /// Highlight each word as it is spoken (karaoke).
    case karaoke
}

public enum CaptionRenderDecision {
    /// The renderer's decision. Captions off hides everything. Plain style always
    /// renders plain. Karaoke style renders karaoke ONLY when the timeline's
    /// timing is exact; estimated timing degrades to plain (no misleading bounce)
    /// until an exact timeline arrives, at which point the same call upgrades to
    /// karaoke live.
    public static func mode(
        captionsEnabled: Bool,
        style: CaptionStyle,
        provenance: CaptionTimingProvenance
    ) -> CaptionRenderMode {
        guard captionsEnabled else { return .hidden }
        switch style {
        case .plain:
            return .plain
        case .karaoke:
            return provenance.isExact ? .karaoke : .plain
        }
    }
}

/// Pure, stateless windowing for the bottom karaoke caption. The caption shows a
/// fixed-size window of words; this decides which word index that window starts
/// on, given the total word count, the window size, and the anchor word (from
/// `CaptionAlignment.captionAnchorIndex(at:)`).
///
/// It is deterministic and depends only on its inputs, so the window is a pure
/// function of the clock exactly like the full-message transcript's highlight.
/// The previous design kept the start in view `@State` and only nudged it from an
/// `onChange(currentTimeMs)` side effect; when that update was skipped (the
/// karaoke view first appearing mid-message, captions toggled off then on, or the
/// estimated->exact alignment swap) the window stranded at word 0 while the clock
/// and the full-message panel kept advancing. Deriving it here removes that whole
/// class of stranding.
///
/// Behavior: the window holds on the first page until the active word reaches the
/// trailing `trigger` zone, then pages forward in steady strides (keeping
/// `backfill` words of leading context) so the caption does not scroll on every
/// word, and the anchor is always inside the returned window.
public enum CaptionWindow {
    public static func start(
        wordCount: Int,
        windowSize: Int,
        anchor: Int,
        backfill: Int = 2,
        trigger: Int = 2
    ) -> Int {
        guard windowSize > 0, wordCount > windowSize else { return 0 }
        let maxStart = wordCount - windowSize
        let clampedAnchor = min(max(0, anchor), wordCount - 1)
        // Still comfortably inside the first window: hold at the start.
        if clampedAnchor < windowSize - trigger { return 0 }
        // Page forward in fixed strides so the window jumps rather than scrolls,
        // keeping the anchor visible with `backfill` words of leading context.
        let stride = max(1, windowSize - backfill - trigger)
        let page = ((clampedAnchor - (windowSize - trigger)) / stride) + 1
        return min(maxStart, page * stride)
    }
}

public enum CaptionAlignmentBuilder {
    public static let minimumWordDurationMs = 90

    /// One tokenized word of a caption script: its text plus its character range
    /// in the source text. This is the exact tokenization the estimated fallback
    /// and forced-alignment mapper both build on, so their character ranges line
    /// up with what the caption view renders.
    public struct WordUnit: Equatable {
        public let word: String
        public let charStart: Int
        public let charEnd: Int

        public init(word: String, charStart: Int, charEnd: Int) {
            self.word = word
            self.charStart = charStart
            self.charEnd = charEnd
        }
    }

    /// Public tokenization used by both the estimated fallback and the forced
    /// aligner so their word units (and thus char ranges) are identical.
    public static func wordUnits(in text: String) -> [WordUnit] {
        wordRanges(in: text).map { WordUnit(word: $0.word, charStart: $0.charStart, charEnd: $0.charEnd) }
    }

    public static func estimatedDurationMs(for text: String) -> Int {
        let words = wordRanges(in: text)
        guard !words.isEmpty else { return 1200 }

        let base = words.reduce(0) { partial, item in
            partial + max(150, min(520, Int(speechWeight(for: item.word) * 58)))
        }
        let punctuationPauses = text.reduce(0) { partial, character in
            partial + (".,;:!?".contains(character) ? 130 : 0)
        }
        return max(1800, min(45_000, base + punctuationPauses + 650))
    }

    public static func fallback(text: String, durationMs: Int? = nil) -> CaptionAlignment {
        let ranges = wordRanges(in: text)
        let totalDuration = max(durationMs ?? estimatedDurationMs(for: text), 1)
        guard !ranges.isEmpty else {
            return CaptionAlignment(text: text, words: [], totalDurationMs: totalDuration, provenance: .estimated)
        }

        let weights = ranges.map { speechWeight(for: $0.word) }
        let totalWeight = weights.reduce(0, +)
        var elapsedWeight = 0.0

        let timings = ranges.enumerated().map { index, item in
            let startMs = Int((elapsedWeight / totalWeight) * Double(totalDuration))
            elapsedWeight += weights[index]
            let nextStartMs = index == ranges.count - 1
                ? totalDuration
                : Int((elapsedWeight / totalWeight) * Double(totalDuration))
            return WordTiming(
                word: item.word,
                startMs: startMs,
                durationMs: max(1, nextStartMs - startMs),
                charStart: item.charStart,
                charEnd: item.charEnd
            )
        }

        return CaptionAlignment(text: text, words: timings, totalDurationMs: totalDuration, provenance: .estimated)
    }

    /// Builds an exact-from-engine alignment from per-character timestamps a TTS
    /// engine returns (ElevenLabs with-timestamps). `characters`,
    /// `startTimesSec`, and `endTimesSec` are parallel arrays over the spoken
    /// text. Characters are grouped into the caption's own word units so the
    /// rendered char ranges match; each word takes the start of its first
    /// character and the end of its last. Returns nil if the arrays disagree in
    /// length or are empty, so the caller falls back to the estimated timeline.
    public static func fromCharacterTimings(
        text: String,
        characters: [String],
        startTimesSec: [Double],
        endTimesSec: [Double]
    ) -> CaptionAlignment? {
        guard !characters.isEmpty,
              characters.count == startTimesSec.count,
              characters.count == endTimesSec.count else {
            return nil
        }
        // Reconstruct the engine's spoken string from its own characters so the
        // per-character indices line up regardless of how it split them.
        let joined = characters.joined()
        let units = wordUnits(in: joined)
        guard !units.isEmpty else { return nil }

        // Cumulative character offsets so a word's char range maps to indices in
        // the parallel timing arrays.
        var charCount = 0
        var offsets: [Int] = []
        offsets.reserveCapacity(characters.count)
        for character in characters {
            offsets.append(charCount)
            charCount += character.count
        }
        func timingIndex(forCharacterOffset offset: Int) -> Int? {
            // Largest character whose start offset is <= the requested offset.
            var low = 0
            var high = offsets.count - 1
            var picked: Int?
            while low <= high {
                let mid = (low + high) / 2
                if offsets[mid] <= offset {
                    picked = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            return picked
        }

        let totalEndSec = endTimesSec.max() ?? 0
        let totalDurationMs = max(1, Int((totalEndSec * 1000).rounded()))
        let words: [WordTiming] = units.map { unit in
            let firstIndex = timingIndex(forCharacterOffset: unit.charStart) ?? 0
            let lastIndex = timingIndex(forCharacterOffset: max(unit.charStart, unit.charEnd - 1)) ?? firstIndex
            let startMs = Int((startTimesSec[firstIndex] * 1000).rounded())
            let endMs = Int((endTimesSec[max(firstIndex, lastIndex)] * 1000).rounded())
            return WordTiming(
                word: unit.word,
                startMs: max(0, startMs),
                durationMs: max(minimumWordDurationMs, endMs - startMs),
                charStart: unit.charStart,
                charEnd: unit.charEnd
            )
        }
        return CaptionAlignment(
            text: joined,
            words: words,
            totalDurationMs: totalDurationMs,
            provenance: .exactFromEngine
        )
    }

    /// Whitespace tokens longer than this get locale-aware sub-segmentation so
    /// spaceless scripts (Thai, Chinese, Japanese) highlight word by word
    /// instead of as one giant run.
    static let spacelessRunThreshold = 12

    private static func wordRanges(in text: String) -> [(word: String, charStart: Int, charEnd: Int)] {
        var results: [(String, Int, Int)] = []
        var currentStart: String.Index?

        func appendWord(endingAt end: String.Index) {
            guard let start = currentStart else { return }
            results.append(contentsOf: segmented(text: text, tokenRange: start..<end))
            currentStart = nil
        }

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace || character.isNewline {
                appendWord(endingAt: index)
            } else if currentStart == nil {
                currentStart = index
            }
            index = text.index(after: index)
        }
        appendWord(endingAt: text.endIndex)
        return results
    }

    /// One whitespace-delimited token, sub-segmented when it is a long
    /// spaceless run. Latin tokens (with their punctuation) pass through
    /// untouched; long runs split on linguistic word boundaries (via
    /// `NLTokenizer`, INF-364) with the remainder folded into the last piece so
    /// no character is lost. `NLTokenizer` is used rather than
    /// `String.enumerateSubstrings(options: [.byWords, .localized])` because the
    /// latter does not reliably sub-segment spaceless Hangul runs (Korean is one
    /// of the app's shipped caption languages): it returns the whole run as a
    /// single boundary, which would otherwise show a whole Korean sentence as one
    /// frozen caption token.
    private static func segmented(text: String, tokenRange: Range<String.Index>) -> [(String, Int, Int)] {
        let token = String(text[tokenRange])
        let tokenStart = text.distance(from: text.startIndex, to: tokenRange.lowerBound)

        func whole() -> [(String, Int, Int)] {
            [(token, tokenStart, tokenStart + token.count)]
        }

        let technical = technicalSegments(token: token, tokenStart: tokenStart)
        if technical.count > 1 { return technical }

        guard token.count > spacelessRunThreshold else { return whole() }

        var boundaries: [Range<String.Index>] = []
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = token
        tokenizer.enumerateTokens(in: token.startIndex..<token.endIndex) { range, _ in
            boundaries.append(range)
            return true
        }
        guard boundaries.count > 1 else { return whole() }

        // Snap the pieces so together they cover the full token: the first
        // starts at the token start, each subsequent piece starts where the
        // previous ended, the last runs to the token end.
        var pieces: [(String, Int, Int)] = []
        for (index, range) in boundaries.enumerated() {
            let start = index == 0 ? token.startIndex : boundaries[index - 1].upperBound
            let end = index == boundaries.count - 1 ? token.endIndex : range.upperBound
            guard start < end else { continue }
            let piece = String(token[start..<end])
            let charStart = tokenStart + token.distance(from: token.startIndex, to: start)
            pieces.append((piece, charStart, charStart + piece.count))
        }
        return pieces.isEmpty ? whole() : pieces
    }

    /// Split identifiers and paths the way they are usually spoken: at camel
    /// case, acronym, digit, and common separator boundaries. Each separator
    /// stays attached to the preceding piece, so concatenating the timings is
    /// byte-for-byte equivalent at the Character level to the source token.
    private static func technicalSegments(
        token: String,
        tokenStart: Int
    ) -> [(String, Int, Int)] {
        let characters = Array(token)
        guard characters.count > 1 else { return [(token, tokenStart, tokenStart + token.count)] }

        let separators = CharacterSet(charactersIn: "._/\\:-=()[]{}#@")
        func isSeparator(_ character: Character) -> Bool {
            character.unicodeScalars.allSatisfy { separators.contains($0) }
        }
        func isUpper(_ character: Character) -> Bool {
            character.isLetter && String(character) == String(character).uppercased()
                && String(character) != String(character).lowercased()
        }
        func isLower(_ character: Character) -> Bool {
            character.isLetter && String(character) == String(character).lowercased()
                && String(character) != String(character).uppercased()
        }

        let hasSeparator = characters.contains(where: isSeparator)
        let hasCaseBoundary = (1..<characters.count).contains { index in
            let previous = characters[index - 1]
            let current = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            return (isLower(previous) && isUpper(current))
                || (isUpper(previous) && isUpper(current) && next.map(isLower) == true)
        }
        guard hasSeparator || hasCaseBoundary else {
            return [(token, tokenStart, tokenStart + token.count)]
        }

        var boundaries: Set<Int> = [0, characters.count]
        for index in 1..<characters.count {
            let previous = characters[index - 1]
            let current = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil

            if isSeparator(previous) {
                boundaries.insert(index)
            }
            if isLower(previous) && isUpper(current) {
                boundaries.insert(index)
            }
            if previous.isNumber != current.isNumber,
               (previous.isNumber || current.isNumber) {
                boundaries.insert(index)
            }
            if isUpper(previous), isUpper(current), let next, isLower(next) {
                boundaries.insert(index)
            }
        }

        let ordered = boundaries.sorted()
        guard ordered.count > 2 else { return [(token, tokenStart, tokenStart + token.count)] }
        return zip(ordered, ordered.dropFirst()).compactMap { lower, upper in
            guard lower < upper else { return nil }
            let piece = String(characters[lower..<upper])
            return (piece, tokenStart + lower, tokenStart + upper)
        }
    }

    /// A rough speech cost rather than raw character length. Short words get a
    /// floor, numbers and all-caps pieces get extra time, and punctuation earns
    /// a small pause. The actual audio duration still supplies the outer clock.
    private static func speechWeight(for token: String) -> Double {
        let letters = token.filter(\.isLetter).count
        let digits = token.filter(\.isNumber).count
        let punctuation = token.count - letters - digits
        let allCaps = letters > 1 && token.filter(\.isLetter).allSatisfy {
            String($0) == String($0).uppercased()
        }
        return max(
            2.4,
            Double(letters) + Double(digits) * 1.25 + Double(punctuation) * 0.7
                + (allCaps ? Double(letters) * 0.25 : 0)
        )
    }
}

private extension String {
    func characterSlice(from start: Int, to end: Int) -> String {
        guard start < end else { return "" }
        let boundedStart = max(0, min(count, start))
        let boundedEnd = max(boundedStart, min(count, end))
        let startIndex = index(self.startIndex, offsetBy: boundedStart)
        let endIndex = index(self.startIndex, offsetBy: boundedEnd)
        return String(self[startIndex..<endIndex])
    }
}
