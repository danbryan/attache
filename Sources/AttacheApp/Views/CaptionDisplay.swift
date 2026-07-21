import AttacheCore
import SwiftUI

// Wraps word views like text, but centers each line so the caption reads like a
// caption rather than a left-aligned list.
struct CenteredFlowLayout: Layout {
    var spacing: CGFloat = 7
    var lineSpacing: CGFloat = 6
    var centered: Bool = true

    private func lines(_ subviews: Subviews, maxWidth: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var lines: [[(index: Int, size: CGSize)]] = []
        var line: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let advance = size.width + (line.isEmpty ? 0 : spacing)
            if width + advance > maxWidth, !line.isEmpty {
                lines.append(line)
                line = []
                width = 0
            }
            line.append((index, size))
            width += size.width + (line.count == 1 ? 0 : spacing)
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let grouped = lines(subviews, maxWidth: maxWidth)
        var height: CGFloat = 0
        var widest: CGFloat = 0
        for (lineIndex, line) in grouped.enumerated() {
            let lineWidth = line.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, line.count - 1))
            widest = max(widest, lineWidth)
            height += (line.map { $0.size.height }.max() ?? 0) + (lineIndex > 0 ? lineSpacing : 0)
        }
        return CGSize(width: min(maxWidth, widest), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let grouped = lines(subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for line in grouped {
            let lineWidth = line.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, line.count - 1))
            let lineHeight = line.map { $0.size.height }.max() ?? 0
            var x = bounds.minX + (centered ? (bounds.width - lineWidth) / 2 : 0)
            for (index, size) in line {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (lineHeight - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += lineHeight + lineSpacing
        }
    }
}

private struct KaraokeCaptionView: View {
    var text: String
    var alignment: CaptionAlignment?
    var currentTimeMs: Int
    var highlightColor: Color
    /// Whether to highlight each word (karaoke) or show the caption as plain
    /// text. Plain is used when the user picked plain, or when karaoke would be
    /// dishonest because the active timeline is only estimated.
    var mode: CaptionRenderMode = .karaoke
    var fontSize: CGFloat = 24
    var lineCount: Int = 2
    var onSeek: ((Int) -> Void)?
    var onSeekAndResume: ((Int) -> Void)?

    // The first word index shown. Held steady while the spoken word moves through
    // the window, and only advanced once the active word nears the trailing edge,
    // so the caption stays put and readable instead of scrolling on every word.
    @State private var windowStart = 0

    private var windowSize: Int { max(6, lineCount * 6 + 3) }

    // Word to position the window on: the active word, or the last one already
    // started (so the window still tracks during the gaps between words).
    private func anchorIndex(_ a: CaptionAlignment) -> Int {
        a.activeWordIndex(at: currentTimeMs)
            ?? a.words.lastIndex { currentTimeMs >= $0.startMs }
            ?? 0
    }

    private func advanceWindowIfNeeded() {
        guard let alignment, !alignment.words.isEmpty else { return }
        let count = alignment.words.count
        let anchor = anchorIndex(alignment)
        let backfill = 2   // words of context kept before the anchor after a jump
        let trigger = 2    // advance once the anchor is within this many of the edge
        let maxStart = max(0, count - windowSize)
        if anchor < windowStart || anchor >= windowStart + windowSize - trigger {
            windowStart = min(maxStart, max(0, anchor - backfill))
        }
    }

    var body: some View {
        // No backing box: a tight dark outline plus a soft glow keeps the words
        // readable over the (calm, bar-free) bottom of the visualizer.
        content
            .font(.system(size: fontSize, weight: .semibold))
            .shadow(color: .black.opacity(0.9), radius: 4)
            .shadow(color: .black.opacity(0.6), radius: 12)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .animation(.easeInOut(duration: 0.075), value: alignment?.activeWordIndex(at: currentTimeMs))
            .onChange(of: currentTimeMs) { _ in advanceWindowIfNeeded() }
            .onChange(of: text) { _ in windowStart = 0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Captions")
            .accessibilityValue(text)
    }

    // The karaoke caption box is capped at this width (see `.frame(maxWidth:)`
    // below); oversized-token wrapping (INF-364) is planned against this same
    // number so a fragment that "fits" here also fits the rendered box.
    private static let boxWidth: Double = 700

    @ViewBuilder
    private var content: some View {
        if mode == .karaoke, let alignment, !alignment.words.isEmpty {
            let count = alignment.words.count
            let start = min(max(0, windowStart), max(0, count - 1))
            let end = min(count, start + windowSize)
            let slice = Array(alignment.words[start..<end])
            let activeID = alignment.activeWordIndex(at: currentTimeMs).map { alignment.words[$0].id }
            let units = captionDisplayUnits(for: slice, boxWidth: Self.boxWidth, fontSize: Double(fontSize))
            CenteredFlowLayout(spacing: 2, lineSpacing: 4) {
                if start > 0 {
                    Text("…").foregroundStyle(.white.opacity(0.45)).padding(.horizontal, 2)
                }
                ForEach(units) { unit in
                    CaptionWordView(
                        unit: unit,
                        isActiveWord: unit.word.id == activeID,
                        currentTimeMs: currentTimeMs,
                        highlightColor: highlightColor,
                        onSeek: onSeek,
                        onSeekAndResume: onSeekAndResume
                    )
                }
                if end < count {
                    Text("…").foregroundStyle(.white.opacity(0.45)).padding(.horizontal, 2)
                }
            }
            .frame(maxWidth: Self.boxWidth)
        } else {
            Text(text)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.86)
        }
    }
}

/// One caption word, possibly split into display fragments (INF-364) so a
/// single unbreakable token (checksum, URL, long identifier) that is wider than
/// the caption box wraps mid-token instead of overflowing or collapsing it.
/// Each unit is its own flow item so `CenteredFlowLayout` can wrap between
/// fragments exactly like it wraps between ordinary words.
struct CaptionDisplayUnit: Identifiable {
    let id: String
    let word: WordTiming
    let text: String
    let fragmentIndex: Int
    let fragmentCount: Int
}

/// Expands a window of words into display units, splitting any word wider than
/// `boxWidth` at `fontSize` into multiple fragments via `CaptionTokenLayout`.
/// Ordinary words that already fit pass through as a single one-fragment unit,
/// identical to their previous rendering.
func captionDisplayUnits(for words: [WordTiming], boxWidth: Double, fontSize: Double) -> [CaptionDisplayUnit] {
    words.flatMap { word -> [CaptionDisplayUnit] in
        let fragments = CaptionTokenLayout.fragments(for: word.word, boxWidth: boxWidth, fontSize: fontSize)
        return fragments.enumerated().map { index, fragment in
            CaptionDisplayUnit(
                id: "\(word.id)#\(index)",
                word: word,
                text: fragment,
                fragmentIndex: index,
                fragmentCount: fragments.count
            )
        }
    }
}

// A single caption word fragment: highlighted when its word is active, and on
// hover it gets a themed pill (like the session list) to advertise that it's
// clickable. A word that was too wide for the caption box arrives here as
// multiple fragments (INF-364); when the word's spoken duration exceeds
// `WordTiming.subWordProgressThresholdMs`, only the fragment matching current
// elapsed progress through the word lights up, so a long checksum highlights
// progressively instead of as one frozen block.
struct CaptionWordView: View {
    var unit: CaptionDisplayUnit
    var isActiveWord: Bool
    var currentTimeMs: Int = 0
    var highlightColor: Color
    var baseColor: Color = .white
    var onSeek: ((Int) -> Void)?
    var onSeekAndResume: ((Int) -> Void)?
    @State private var hovering = false

    private var highlighted: Bool {
        guard isActiveWord else { return false }
        guard unit.fragmentCount > 1, unit.word.durationMs > WordTiming.subWordProgressThresholdMs else {
            // Short word, or a word that only needed wrapping (not pacing):
            // every fragment lights up together, matching the pre-INF-364
            // whole-word highlight behavior.
            return true
        }
        let elapsed = currentTimeMs - unit.word.startMs
        let activeFragment = unit.word.activeSubWordFragmentIndex(
            elapsedMsSinceWordStart: elapsed,
            fragmentCount: unit.fragmentCount
        )
        return activeFragment == unit.fragmentIndex
    }

    /// Pure position affordance: an underline plus the "m:ss" timestamp
    /// tooltip on hover (INF-365). It never intercepts scroll or click; the
    /// existing tap gestures below are unchanged.
    private var isHoverable: Bool { onSeek != nil }

    var body: some View {
        Text(unit.text)
            .fontWeight(highlighted ? .bold : nil)
            .foregroundStyle(highlighted ? highlightColor : (hovering ? highlightColor.opacity(0.92) : baseColor))
            .underline(hovering && isHoverable, pattern: .solid, color: highlightColor.opacity(0.85))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering ? highlightColor.opacity(0.22) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onSeekAndResume?(unit.word.startMs) }
            .onTapGesture { onSeek?(unit.word.startMs) }
            .onHover { inside in
                hovering = isHoverable && inside
            }
            .help(isHoverable
                ? "\(CaptionTimestampFormatter.format(ms: unit.word.startMs)) · Click to jump. Double-click to jump and play."
                : "")
    }
}

// MARK: - Playback-timeline observers
//
// These small views observe `PlaybackTimeline` (the ~20 Hz clock state) so the
// caption highlight, scrubber, and time label refresh every tick without
// re-evaluating the whole main window body.

struct ResponseCaptionLayer: View {
    @ObservedObject var timeline: PlaybackTimeline
    var text: String
    var alignment: CaptionAlignment?
    var highlightColor: Color
    var syncOffsetMs: Int
    var mode: CaptionRenderMode = .karaoke
    var fontSize: CGFloat = 24
    var lineCount: Int = 2
    var onSeek: ((Int) -> Void)?
    var onSeekAndResume: ((Int) -> Void)?

    var body: some View {
        KaraokeCaptionView(
            text: text,
            alignment: alignment,
            currentTimeMs: timeline.currentTimeMs + syncOffsetMs,
            highlightColor: highlightColor,
            mode: mode,
            fontSize: fontSize,
            lineCount: lineCount,
            onSeek: onSeek,
            onSeekAndResume: onSeekAndResume
        )
    }
}
