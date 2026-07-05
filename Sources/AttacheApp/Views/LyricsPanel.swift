import AttacheCore
import SwiftUI

// Apple Music-style lyrics: hover the right edge to slide out the full message,
// with the spoken word highlighted and every word clickable to seek.
struct LyricsSidePanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var playback: SpeechPlaybackController
    var scrubberHoverExclusionEnabled = false
    @State private var expanded = false

    private var alignment: CaptionAlignment? { playback.currentAlignment }

    private var hasLyrics: Bool {
        (playback.isPlaying || playback.isPaused) && (alignment?.words.isEmpty == false)
    }

    var body: some View {
        if hasLyrics {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    content
                        .frame(width: expanded ? 330 : 48, alignment: .topLeading)
                        .frame(maxHeight: .infinity)
                        .background {
                            if expanded { Rectangle().fill(.regularMaterial) }
                        }
                        .overlay(alignment: .leading) {
                            if expanded { Divider() }
                        }
                        .clipped()
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            updateHoverExpansion(phase, height: proxy.size.height)
                        }
                }
            }
        }
    }

    private func updateHoverExpansion(_ phase: HoverPhase, height: CGFloat) {
        switch phase {
        case .active(let location):
            let blocked = EdgeHoverScrubberExclusion.contains(
                location,
                height: height,
                enabled: !expanded && scrubberHoverExclusionEnabled
            )
            withAnimation(.easeInOut(duration: 0.18)) {
                expanded = !blocked
            }
        case .ended:
            withAnimation(.easeInOut(duration: 0.18)) { expanded = false }
        }
    }

    @ViewBuilder private var content: some View {
        if expanded, let alignment {
            VStack(alignment: .leading, spacing: 0) {
                Label("Full message", systemImage: "text.alignleft")
                    .typoCaption(.semibold)
                    .foregroundStyle(model.theme.signatureColor)
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
                LyricsTranscript(
                    clock: playback.clock,
                    alignment: alignment,
                    syncOffsetMs: model.captionSyncOffsetMs,
                    highlightColor: model.theme.signatureColor,
                    onSeek: seekToCaptionTime,
                    onSeekAndResume: seekToCaptionTimeAndResume
                )
            }
        } else {
            // Collapsed: a thin handle pinned to the right edge inside a wide,
            // easy-to-hit hover zone.
            Capsule()
                .fill(model.theme.signatureColor.opacity(0.55))
                .frame(width: 3, height: 44)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 5)
        }
    }

    private func seekToCaptionTime(_ captionTimeMs: Int) {
        if let currentCardID = playback.currentCardID,
           model.selectedCard?.id == currentCardID {
            model.seekToCaptionTime(captionTimeMs)
        } else {
            playback.seek(to: max(0, captionTimeMs - model.captionSyncOffsetMs))
        }
    }

    private func seekToCaptionTimeAndResume(_ captionTimeMs: Int) {
        seekToCaptionTime(captionTimeMs)
        if playback.isPaused {
            playback.resume()
        }
    }
}

private struct LyricsTranscript: View {
    @ObservedObject var clock: PlaybackTimeline
    var alignment: CaptionAlignment
    var syncOffsetMs: Int
    var highlightColor: Color
    var onSeek: ((Int) -> Void)?
    var onSeekAndResume: ((Int) -> Void)?

    private var activeID: String? {
        guard let index = alignment.activeWordIndex(at: clock.currentTimeMs + syncOffsetMs) else { return nil }
        return alignment.words[index].id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                CenteredFlowLayout(spacing: 3, lineSpacing: 7, centered: false) {
                    ForEach(alignment.words) { word in
                        CaptionWordView(
                            word: word,
                            isActive: word.id == activeID,
                            highlightColor: highlightColor,
                            baseColor: .primary.opacity(0.82),
                            onSeek: onSeek,
                            onSeekAndResume: onSeekAndResume
                        )
                        .id(word.id)
                    }
                }
                .typoSection(.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .onChange(of: activeID) { id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}
