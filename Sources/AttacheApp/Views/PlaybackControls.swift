import SwiftUI

// A transport control that lights up in the theme color on hover.
struct TransportButton: View {
    var systemImage: String
    var accent: Color
    var prominent: Bool = false
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .typoIcon(size: prominent ? 18 : 16, .bold)
                .foregroundStyle(prominent || hovering ? accent : Color.primary.opacity(0.82))
                .frame(width: prominent ? 44 : 38, height: prominent ? 44 : 38)
                .background(fillStyle, in: Circle())
                .overlay(Circle().stroke(strokeColor))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }

    private var fillStyle: AnyShapeStyle {
        if prominent {
            return AnyShapeStyle(accent.opacity(hovering ? 0.26 : 0.16))
        }
        if hovering {
            return AnyShapeStyle(accent.opacity(0.18))
        }
        return AnyShapeStyle(.ultraThinMaterial.opacity(0.5))
    }

    private var strokeColor: Color {
        if prominent {
            return accent.opacity(hovering ? 0.75 : 0.5)
        }
        return hovering ? accent.opacity(0.55) : Color.primary.opacity(0.12)
    }
}

struct PlaybackTimeLabel: View {
    @ObservedObject var timeline: PlaybackTimeline
    var isActiveCard: Bool
    var playbackDurationMs: Int
    var cardDurationMs: Int
    var fallbackProgress: Double

    var body: some View {
        Text(timeText)
            .typoLabel(design: .monospaced)
            .foregroundStyle(.secondary)
    }

    private var timeText: String {
        let duration = isActiveCard ? playbackDurationMs : cardDurationMs
        let current = isActiveCard ? timeline.currentTimeMs : Int((Double(duration) * fallbackProgress).rounded())
        return "\(formatMMSS(current)) / \(formatMMSS(duration))"
    }
}

struct PlaybackScrubberSlider: View {
    @ObservedObject var timeline: PlaybackTimeline
    var isActiveCard: Bool
    var playbackDurationMs: Int
    var fallbackProgress: Double
    var canSeek: Bool
    var onSeek: (Double) -> Void

    var body: some View {
        Slider(value: progressBinding, in: 0...1)
            .disabled(!canSeek)
            .help("Seek playback")
            .accessibilityLabel("Seek playback")
    }

    private var progressBinding: Binding<Double> {
        Binding(get: { progress }, set: { onSeek($0) })
    }

    private var progress: Double {
        guard isActiveCard, playbackDurationMs > 0 else { return fallbackProgress }
        return min(1, Double(timeline.currentTimeMs) / Double(playbackDurationMs))
    }
}

func formatMMSS(_ ms: Int) -> String {
    let seconds = max(0, ms / 1000)
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
