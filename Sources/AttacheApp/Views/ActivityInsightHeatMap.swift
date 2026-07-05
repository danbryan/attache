import SwiftUI

// Ambient activity phrases from the focused session's tool activity
// (v0.1.2 activity insights, shown only when enabled in Settings).

struct ActivityInsightHeatMap: View {
    var phrases: [AgentActivityPhrase]
    var theme: CompanionTheme

    private let anchors: [(x: CGFloat, y: CGFloat, width: CGFloat)] = [
        (0.50, 0.24, 0.28),
        (0.26, 0.35, 0.26),
        (0.74, 0.35, 0.26),
        (0.31, 0.62, 0.25),
        (0.69, 0.62, 0.25),
        (0.50, 0.73, 0.30),
        (0.17, 0.50, 0.22),
        (0.83, 0.50, 0.22),
        (0.50, 0.50, 0.24)
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Array(phrases.prefix(anchors.count).enumerated()), id: \.element.id) { index, phrase in
                    let anchor = anchors[index]
                    phraseView(phrase, index: index)
                        .frame(width: max(128, proxy.size.width * anchor.width))
                        .position(x: proxy.size.width * anchor.x, y: proxy.size.height * anchor.y)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .animation(.easeInOut(duration: 0.35), value: phrases)
    }

    private func phraseView(_ phrase: AgentActivityPhrase, index: Int) -> some View {
        let emphasis = max(0.22, min(1.0, phrase.weight))
        let fontSize = 12 + emphasis * 12
        let opacity = 0.14 + emphasis * 0.34
        let color = color(for: phrase.source)
        return Text(phrase.text)
            .font(.system(size: fontSize, weight: emphasis > 0.72 ? .bold : .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .multilineTextAlignment(.center)
            .foregroundStyle(color.opacity(opacity))
            .shadow(color: color.opacity(0.22 + emphasis * 0.18), radius: 10 + emphasis * 14)
            .blur(radius: index == 8 ? 0.5 : 0)
            .accessibilityHidden(true)
    }

    private func color(for source: AgentActivityPhrase.Source) -> Color {
        switch source {
        case .toolIntent:
            return theme.signatureColor
        case .toolResult:
            return theme.captionHighlightColor
        case .externalTool:
            let stop = theme.stops.dropLast().last ?? theme.stops.first
            return Color(
                .sRGB,
                red: stop?.red ?? 0.45,
                green: stop?.green ?? 0.55,
                blue: stop?.blue ?? 0.95,
                opacity: 1
            )
        case .editEvent:
            return theme.signatureColor.opacity(0.72)
        }
    }
}
