import SwiftUI

struct VoiceInputMicButtonFace: View {
    var mode: AttacheVoiceInputMode
    var isListening: Bool
    var theme: AttacheTheme
    var size: CGFloat
    var symbolSize: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if isListening {
                TimelineView(.animation) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate / 0.9
                    let pulse = 0.5 + (0.5 * sin(phase * Double.pi * 2))
                    Circle()
                        .stroke(theme.signatureColor.opacity(0.16 + ((1 - pulse) * 0.36)), lineWidth: 2)
                        .frame(width: size, height: size)
                        .scaleEffect(1.03 + (pulse * 0.31))
                }
                .allowsHitTesting(false)
            }

            Circle()
                .fill(backgroundStyle)
                .frame(width: size, height: size)
                .overlay(Circle().stroke(strokeColor, lineWidth: isListening ? 1.6 : 1.2))
                .shadow(color: shadowColor, radius: isListening ? 9 : 3)

            Image(systemName: symbolName)
                .typoIcon(size: symbolSize, .bold)
                .foregroundStyle(symbolColor)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .scaleEffect(isListening ? 1.1 : 1.0)
        .animation(.easeInOut(duration: 0.12), value: isListening)
        .accessibilityLabel(isListening ? "Microphone listening" : "Microphone off")
    }

    private var symbolName: String {
        if isListening { return "mic.fill" }
        return mode == .pushToTalk ? "mic" : "mic.slash.fill"
    }

    private var backgroundStyle: AnyShapeStyle {
        if isListening {
            return AnyShapeStyle(theme.signatureColor)
        }
        return AnyShapeStyle(.ultraThinMaterial.opacity(colorScheme == .dark ? 0.62 : 0.76))
    }

    private var symbolColor: Color {
        if isListening {
            return theme.signatureForegroundColor
        }
        return mode == .pushToTalk ? theme.signatureColor.opacity(0.82) : Color.secondary.opacity(0.9)
    }

    private var strokeColor: Color {
        if isListening {
            return theme.signatureForegroundColor.opacity(0.42)
        }
        return mode == .pushToTalk ? theme.signatureColor.opacity(0.38) : Color.secondary.opacity(0.24)
    }

    private var shadowColor: Color {
        isListening ? theme.signatureColor.opacity(0.58) : theme.signatureColor.opacity(0.16)
    }
}
