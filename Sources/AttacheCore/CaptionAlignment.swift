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

public struct CaptionAlignment: Codable, Equatable {
    public var text: String
    public var words: [WordTiming]
    public var totalDurationMs: Int

    public init(text: String, words: [WordTiming], totalDurationMs: Int) {
        self.text = text
        self.words = words
        self.totalDurationMs = totalDurationMs
    }

    enum CodingKeys: String, CodingKey {
        case text
        case words
        case totalDurationMs = "total_duration_ms"
    }

    public func activeWordIndex(at currentTimeMs: Int) -> Int? {
        words.firstIndex { word in
            let end = word.startMs + max(80, word.durationMs)
            return currentTimeMs >= word.startMs && currentTimeMs < end
        }
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

public enum CaptionAlignmentBuilder {
    public static let minimumWordDurationMs = 90

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
            return CaptionAlignment(text: text, words: [], totalDurationMs: totalDuration)
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

        return CaptionAlignment(text: text, words: timings, totalDurationMs: totalDuration)
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
