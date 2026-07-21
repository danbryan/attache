import Foundation

/// One word a speech recognizer reported, with its timing in the synthesized
/// clip. `startMs`/`durationMs` are milliseconds from the start of the audio.
/// This is the recognizer-agnostic input to the forced-alignment mapper, so the
/// pure mapping logic is tested with fixtures and never needs `SFSpeechRecognizer`.
public struct RecognizedWord: Equatable {
    public var text: String
    public var startMs: Int
    public var durationMs: Int

    public init(text: String, startMs: Int, durationMs: Int) {
        self.text = text
        self.startMs = startMs
        self.durationMs = durationMs
    }
}

/// Maps a recognizer's recognized words (with timestamps) onto a KNOWN script's
/// word list to recover exact per-word timing for karaoke captions on engines
/// that supply none. The script text is authoritative for what is shown; the
/// recognition only supplies the clock.
///
/// The script and recognition are aligned with Needleman-Wunsch (global edit
/// distance over normalized tokens). Script words that align to an equal
/// recognized word are ANCHORED to that word's start time. Unanchored script
/// words (substitutions/insertions relative to the recognition, or dropped
/// recognition) have their start time linearly interpolated between their
/// nearest anchored neighbors. Confidence is the fraction of script words that
/// anchored; below `minimumConfidence` the alignment is rejected so the caller
/// keeps the estimated timeline.
public enum ForcedAlignment {
    /// Pinned by `ForcedAlignmentTests`: below this fraction of script words
    /// anchored, the recovered timing is too sparse to trust and the caller keeps
    /// the estimated timeline. Tuned so a clip where the recognizer caught most
    /// words upgrades, while a mostly-garbage transcription does not.
    public static let minimumConfidence = 0.6

    public struct Result: Equatable {
        /// The recovered alignment (provenance `.exactFromAlignment`). Present
        /// even when `accepted` is false so callers can inspect it in tests.
        public var alignment: CaptionAlignment
        /// Fraction of script words that anchored to a recognized word (0...1).
        public var confidence: Double
        /// True when `confidence >= minimumConfidence`. Only an accepted result
        /// should replace the estimated timeline.
        public var accepted: Bool

        public init(alignment: CaptionAlignment, confidence: Double, accepted: Bool) {
            self.alignment = alignment
            self.confidence = confidence
            self.accepted = accepted
        }
    }

    public static func align(
        scriptText: String,
        recognized: [RecognizedWord],
        totalDurationMs: Int,
        minimumConfidence: Double = ForcedAlignment.minimumConfidence
    ) -> Result {
        let units = CaptionAlignmentBuilder.wordUnits(in: scriptText)
        let duration = max(1, totalDurationMs)

        // No script words: nothing to align.
        guard !units.isEmpty else {
            return Result(
                alignment: CaptionAlignment(text: scriptText, words: [], totalDurationMs: duration, provenance: .exactFromAlignment),
                confidence: 0,
                accepted: false
            )
        }

        let scriptTokens = units.map { normalize($0.word) }
        let recognizedTokens = recognized.map { normalize($0.text) }

        // Map each script index to a recognized index when they align as an equal
        // match; nil otherwise.
        let anchors = matchAnchors(script: scriptTokens, recognized: recognizedTokens)
        let anchoredCount = anchors.compactMap { $0 }.count
        let confidence = Double(anchoredCount) / Double(units.count)

        // Anchored start times (ms), then interpolate the gaps.
        var starts = [Int?](repeating: nil, count: units.count)
        for (index, anchor) in anchors.enumerated() {
            if let anchor, recognized.indices.contains(anchor) {
                starts[index] = max(0, min(duration, recognized[anchor].startMs))
            }
        }
        // Keep anchored times monotonic; a recognizer can occasionally report a
        // word slightly before its predecessor, which would invert the caption.
        enforceMonotonic(&starts, upperBound: duration)
        let resolvedStarts = interpolate(starts: starts, unitCount: units.count, totalDurationMs: duration)

        var words: [WordTiming] = []
        words.reserveCapacity(units.count)
        for (index, unit) in units.enumerated() {
            let start = resolvedStarts[index]
            let nextStart = index == units.count - 1 ? duration : resolvedStarts[index + 1]
            words.append(
                WordTiming(
                    word: unit.word,
                    startMs: start,
                    durationMs: max(CaptionAlignmentBuilder.minimumWordDurationMs, nextStart - start),
                    charStart: unit.charStart,
                    charEnd: unit.charEnd
                )
            )
        }

        let alignment = CaptionAlignment(
            text: scriptText,
            words: words,
            totalDurationMs: duration,
            provenance: .exactFromAlignment
        )
        return Result(
            alignment: alignment,
            confidence: confidence,
            accepted: confidence >= minimumConfidence
        )
    }

    // MARK: - Matching

    /// Global sequence alignment (Needleman-Wunsch). Returns, for each script
    /// token, the index of the recognized token it aligns to as an EQUAL match,
    /// or nil (substitution/insertion/deletion). Only equal-token matches count
    /// as anchors, so a substituted word never borrows a wrong timestamp.
    private static func matchAnchors(script: [String], recognized: [String]) -> [Int?] {
        let m = script.count
        let n = recognized.count
        guard m > 0 else { return [] }
        guard n > 0 else { return [Int?](repeating: nil, count: m) }

        let matchScore = 2
        let mismatchScore = -1
        let gapScore = -1

        // Score matrix (m+1) x (n+1).
        var score = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { score[i][0] = i * gapScore }
        for j in 0...n { score[0][j] = j * gapScore }
        for i in 1...m {
            for j in 1...n {
                let equal = script[i - 1] == recognized[j - 1] && !script[i - 1].isEmpty
                let diagonal = score[i - 1][j - 1] + (equal ? matchScore : mismatchScore)
                let up = score[i - 1][j] + gapScore
                let left = score[i][j - 1] + gapScore
                score[i][j] = max(diagonal, up, left)
            }
        }

        // Backtrack, recording equal-diagonal steps as anchors.
        var anchors = [Int?](repeating: nil, count: m)
        var i = m
        var j = n
        while i > 0 && j > 0 {
            let equal = script[i - 1] == recognized[j - 1] && !script[i - 1].isEmpty
            let diagonal = score[i - 1][j - 1] + (equal ? matchScore : mismatchScore)
            if score[i][j] == diagonal {
                if equal { anchors[i - 1] = j - 1 }
                i -= 1
                j -= 1
            } else if score[i][j] == score[i - 1][j] + gapScore {
                i -= 1
            } else {
                j -= 1
            }
        }
        return anchors
    }

    // MARK: - Interpolation

    private static func enforceMonotonic(_ starts: inout [Int?], upperBound: Int) {
        var last = 0
        for index in starts.indices {
            if let value = starts[index] {
                let clamped = max(last, min(upperBound, value))
                starts[index] = clamped
                last = clamped
            }
        }
    }

    /// Fill nil start times by linear interpolation between the nearest anchored
    /// neighbors. Leading unanchored words spread from 0 to the first anchor;
    /// trailing ones spread from the last anchor to the total duration.
    private static func interpolate(starts: [Int?], unitCount: Int, totalDurationMs: Int) -> [Int] {
        guard unitCount > 0 else { return [] }
        var resolved = [Int](repeating: 0, count: unitCount)
        // No anchors at all: fall back to an even spread so timing is at least
        // monotonic (the caller will reject on confidence anyway).
        let anchoredIndices = starts.indices.filter { starts[$0] != nil }
        guard !anchoredIndices.isEmpty else {
            for index in 0..<unitCount {
                resolved[index] = Int(Double(index) / Double(unitCount) * Double(totalDurationMs))
            }
            return resolved
        }

        var index = 0
        while index < unitCount {
            if let value = starts[index] {
                resolved[index] = value
                index += 1
                continue
            }
            // Run [gapStart, gapEnd) of unanchored words. It is bounded on the
            // left by the previous anchored word's time (or 0 at the very start)
            // and on the right by the next anchored word's time (or the total
            // duration past the last anchor).
            let gapStart = index
            var gapEnd = index
            while gapEnd < unitCount && starts[gapEnd] == nil { gapEnd += 1 }

            let leftTime = gapStart > 0 ? resolved[gapStart - 1] : 0
            let rightTime = gapEnd < unitCount ? (starts[gapEnd] ?? totalDurationMs) : totalDurationMs
            let gapCount = gapEnd - gapStart
            // Spread the run's start times evenly across (leftTime, rightTime).
            // Dividing by (gapCount + 1) leaves headroom before the right boundary
            // when it is an anchored word, and reaches the duration when it is the
            // trailing edge.
            let divisor = gapEnd < unitCount ? (gapCount + 1) : gapCount
            for offset in 0..<gapCount {
                let step = Double(offset + 1) / Double(max(1, divisor))
                let interpolated = leftTime + Int((Double(rightTime - leftTime) * step).rounded())
                resolved[gapStart + offset] = min(totalDurationMs, max(leftTime, interpolated))
            }
            index = gapEnd
        }

        // Final monotonic pass so rounding never inverts a pair.
        var last = 0
        for i in 0..<unitCount {
            resolved[i] = max(last, min(totalDurationMs, resolved[i]))
            last = resolved[i]
        }
        return resolved
    }

    // MARK: - Normalization

    /// Lowercase and strip surrounding punctuation so "Codex." matches "codex".
    /// Digits are kept (numbers must match numbers). An empty result (a token
    /// that was pure punctuation) never anchors.
    static func normalize(_ token: String) -> String {
        let lowered = token.lowercased()
        let scalars = lowered.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
