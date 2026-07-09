import AttacheCore
import SwiftUI

struct EchoformRendererView: View {
    @ObservedObject var playback: SpeechPlaybackController
    @ObservedObject var timeline: PlaybackTimeline
    var unreadCount: Int
    var hasCards: Bool
    var visualMode: CompanionVisualMode
    var visualSymmetry: CompanionVisualSymmetry = .mirrored
    var idleBrand: CompanionIdleBrand = .mark
    var idleCustomText: String = ""
    var idleImage: NSImage?
    var theme: CompanionTheme
    var brightnessLevel: Int
    var intensity: Double

    @Environment(\.colorScheme) private var colorScheme
    @State private var breathing = false
    @State private var sonar = false

    var body: some View {
        ZStack {
            rendererBackground
            if shouldAnimateContinuously {
                rendererCanvas(date: Date())
            } else if isPausedOnCard {
                pausedShimmer
            } else {
                ambientGlow
            }

            if playback.isPlaying || playback.isPaused {
                Text("Visualizer state")
                    .font(.system(size: 1))
                    .frame(width: 1, height: 1)
                    .clipped()
                    .opacity(0.001)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Audio visualizer \(visualizerAccessibilityValue)")
                    .accessibilityValue(visualizerAccessibilityValue)
                    .allowsHitTesting(false)
            }
        }
    }

    private var visualizerAccessibilityValue: String {
        let peak = state.bars.max() ?? 0
        let status = playback.isPaused ? "paused" : "active"
        return "\(status), level \(Int((state.level * 1_000).rounded())), peak \(Int((peak * 1_000).rounded()))"
    }

    private var state: VisualizerRenderState {
        timeline.renderState
    }

    private var shouldAnimateContinuously: Bool {
        playback.isPlaying && !playback.isPaused
    }

    private var isPausedOnCard: Bool {
        playback.isPlaying && playback.isPaused
    }

    // Paused look: hold the current word's spectrum and breathe it gently (no idle
    // logo), so it reads as "paused here" and still alive. The bars are drawn once
    // from the frozen render state; only opacity/scale animate (Core Animation), so
    // a long pause costs no per-frame CPU.
    private var pausedShimmer: some View {
        ZStack {
            GeometryReader { proxy in
                let minSide = min(proxy.size.width, proxy.size.height)
                Circle()
                    .fill(RadialGradient(
                        colors: [ambientColor.opacity(0.20), ambientColor.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: minSide * 0.5
                    ))
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .blur(radius: 26)
                    .opacity(breathing ? 0.7 : 0.38)
            }
            rendererCanvas(date: Date())
                .opacity(breathing ? 0.96 : 0.64)
                .scaleEffect(breathing ? 1.0 : 0.985)
        }
        .onAppear {
            breathing = false
            withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
        .onDisappear { breathing = false }
    }

    // Idle look: a low-key branded animation — a soft breathing glow, gently
    // emanating sound-wave rings (the brand motif), and the wordmark. Signals the
    // app is alive (not a frozen window) without spending main-thread CPU
    // (everything is Core Animation scale/opacity).
    private var ambientGlow: some View {
        ZStack {
            GeometryReader { proxy in
                let minSide = min(proxy.size.width, proxy.size.height)
                Circle()
                    .fill(RadialGradient(
                        colors: [ambientColor.opacity(0.32), ambientColor.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: minSide * 0.58
                    ))
                    .scaleEffect(breathing ? 1.06 : 0.84)
                    .opacity(breathing ? 0.9 : 0.55)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .blur(radius: 22)
            }

            ForEach(0..<3, id: \.self) { ring in
                Circle()
                    .strokeBorder(ambientColor.opacity(0.30), lineWidth: 1.3)
                    .frame(width: 150, height: 150)
                    .scaleEffect(sonar ? 2.3 : 0.55)
                    .opacity(sonar ? 0 : 0.55)
                    .animation(
                        .easeOut(duration: 5.4).repeatForever(autoreverses: false).delay(Double(ring) * 1.8),
                        value: sonar
                    )
            }

            // The center of the idle screen belongs to the user: the brand
            // lockup is the default, not a requirement.
            VStack(spacing: 16) {
                if idleBrand == .mark || idleBrand == .monogram {
                    // The default monogram stays monochrome; the full mark
                    // keeps the theme-tinted treatment for those who pick it.
                    AttacheBrandMark(
                        letterColor: idleBrand == .monogram
                            ? Color.primary.opacity(0.82)
                            : brandLetterColor,
                        barColor: { index in
                            idleBrand == .monogram
                                ? Color.primary.opacity(0.35 + 0.4 * (Double(index) / 10.0))
                                : energyColor(0.42 + 0.58 * (Double(index) / 10.0), opacity: 0.96)
                        },
                        glow: idleBrand == .monogram ? Color.primary.opacity(0.25) : ambientColor,
                        glowStrength: breathing ? 1 : 0.45
                    )
                    .frame(width: 150, height: 158)
                    .opacity(breathing ? 0.98 : 0.84)
                }
                if idleBrand == .mark {
                    Text("Attaché")
                        .typoTitle(.regular)
                        .tracking(6)
                        .foregroundStyle(ambientColor.opacity(0.88))
                        .opacity(breathing ? 0.82 : 0.52)
                }
                if idleBrand == .customText {
                    Text(idleCustomText.isEmpty ? "Attaché" : idleCustomText)
                        .typoDisplay(size: 30, .regular)
                        .tracking(6)
                        .lineLimit(1)
                        .foregroundStyle(ambientColor.opacity(0.88))
                        .opacity(breathing ? 0.85 : 0.55)
                }
                if idleBrand == .customImage {
                    if let idleImage {
                        Image(nsImage: idleImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 220, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                            .opacity(breathing ? 0.92 : 0.68)
                    } else {
                        Text("Pick an image in Settings")
                            .typoCaption(.medium)
                            .foregroundStyle(ambientColor.opacity(0.7))
                    }
                }
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button("Change idle screen…") {
                    NotificationCenter.default.post(name: .attacheOpenSettings, object: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        NotificationCenter.default.post(name: .attacheOpenSettingsSection,
                                                        object: SettingsSection.appearance.rawValue)
                    }
                }
            }
        }
        .onAppear {
            breathing = false
            sonar = false
            withAnimation(.easeInOut(duration: unreadCount > 0 ? 3.4 : 5.0).repeatForever(autoreverses: true)) {
                breathing = true
            }
            sonar = true
        }
        .onDisappear {
            breathing = false
            sonar = false
        }
    }

    // Theme-tinted, a touch more present when there are unread updates.
    private var ambientColor: Color {
        energyColor(unreadCount > 0 ? 0.52 : 0.36)
    }

    // The brand "A" takes the theme's brightest color so the whole mark follows
    // the theme and never disappears (e.g. a white "A" on a light theme).
    // energyColor keeps it legible on both light and dark OS backgrounds.
    private var brandLetterColor: Color {
        energyColor(1.0, opacity: 0.96)
    }

    private var rendererBackground: some View {
        // Dark mode keeps the cinematic near-black stage; light mode uses the
        // system window surface so the canvas matches the rest of the app instead
        // of being a dark void. Energy tints are kept faint in both.
        let center: Color = colorScheme == .dark
            ? Color(red: 0.012, green: 0.016, blue: 0.030)
            : Color(nsColor: .windowBackgroundColor)
        let wash = colorScheme == .dark ? 0.18 : 0.09
        return Rectangle()
            .fill(
                LinearGradient(
                    gradient: Gradient(colors: [
                        energyColor(0.02, opacity: wash),
                        center.opacity(0.97),
                        energyColor(0.38, opacity: wash)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private func rendererCanvas(date: Date) -> some View {
        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            let band = barBand(in: size)
            drawMode(context: context, size: size, band: band, date: date)
        }
    }

    private func drawMode(context: GraphicsContext, size: CGSize, band: CGRect, date: Date) {
        switch visualMode {
        case .bars:
            drawPulse(context: context, size: size, date: date, restrained: true)
            drawWaveform(context: context, size: size, band: band)
            drawBars(context: context, size: size, band: band)
        case .wave:
            drawPulse(context: context, size: size, date: date, restrained: true)
            drawWaveform(context: context, size: size, band: band)
        case .heat:
            drawPulse(context: context, size: size, date: date, restrained: true)
            drawSpectralHeat(context: context, size: size, band: band)
        case .pulse:
            drawPulse(context: context, size: size, date: date, restrained: false)
        case .flow:
            drawPulse(context: context, size: size, date: date, restrained: true)
            drawFlow(context: context, size: size, band: band, date: date)
        case .combined:
            drawSpectralHeat(context: context, size: size, band: band)
            drawPulse(context: context, size: size, date: date, restrained: false)
            drawWaveform(context: context, size: size, band: band)
            drawBars(context: context, size: size, band: band)
        }
    }

    private func barBand(in size: CGSize) -> CGRect {
        let topReserved = min(max(size.height * 0.21, 104), 142)
        let bottomReserved = min(max(size.height * 0.28, 144), 196)
        let height = max(120, size.height - topReserved - bottomReserved)
        let y = min(topReserved, max(0, size.height - bottomReserved - height))
        return CGRect(x: 0, y: y, width: size.width, height: height)
    }

    private func drawBars(context: GraphicsContext, size: CGSize, band: CGRect) {
        let bars = visualSymmetry == .mirrored ? centeredVisualBars(from: state.bars) : state.bars
        guard !bars.isEmpty else { return }

        let count = bars.count
        let gap: CGFloat = 3
        let stageWidth = min(size.width * 0.86, max(320, min(size.width, size.height * 1.35)))
        let stageX = (size.width - stageWidth) / 2
        let barWidth = max(1, (stageWidth - gap * CGFloat(count - 1)) / CGFloat(count))
        let maxHeight = band.height * 0.96
        let center = band.midY

        for index in 0..<count {
            let raw = Double(bars[index])
            let energy = min(1, pow(raw, 0.55) * 2.4 * intensity)
            guard energy > 0.01 else { continue }

            let height = max(2, CGFloat(energy) * maxHeight)
            let x = stageX + CGFloat(index) * (barWidth + gap)
            let y = max(band.minY, min(band.maxY - height, center - height / 2))
            let rect = CGRect(x: x, y: y, width: barWidth, height: height)
            context.fill(
                Path(roundedRect: rect, cornerRadius: min(barWidth, height) * 0.4),
                with: .color(energyColor(energy, opacity: 0.35 + 0.6 * energy))
            )
        }
    }

    private func centeredVisualBars(from bars: [Float]) -> [Float] {
        guard bars.count > 2 else { return bars }

        let lastSourceIndex = CGFloat(bars.count - 1)
        let visualCenter = CGFloat(bars.count - 1) / 2
        let maxDistance = max(1, visualCenter - 0.5)

        return bars.indices.map { index in
            let distance = abs(CGFloat(index) - visualCenter)
            let normalizedDistance = min(1, max(0, (distance - 0.5) / maxDistance))
            return interpolatedBar(in: bars, at: normalizedDistance * lastSourceIndex)
        }
    }

    private func interpolatedBar(in bars: [Float], at position: CGFloat) -> Float {
        let lower = max(0, min(bars.count - 1, Int(position.rounded(.down))))
        let upper = max(0, min(bars.count - 1, lower + 1))
        let fraction = Float(position - CGFloat(lower))
        return bars[lower] + (bars[upper] - bars[lower]) * fraction
    }

    private func drawPulse(context: GraphicsContext, size: CGSize, date: Date, restrained: Bool) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let time = date.timeIntervalSinceReferenceDate
        let level = Double(state.level) * intensity
        let bass = Double(state.bass) * intensity
        let pulse = Double(state.pulse) * intensity
        let maxRadius = Double(min(size.width, size.height)) * 0.46

        let breath = 0.5 + 0.5 * sin(time * 0.7)
        let coreEnergy = min(1, 0.08 + level * 3 + bass * 0.6)
        let radiusScale = restrained ? 0.68 : 1.0
        let coreRadius = maxRadius * radiusScale * (0.12 + 0.10 * breath + 0.52 * coreEnergy)
        let coreColor = energyColor(coreEnergy)

        let glow = Gradient(colors: [coreColor.opacity(0.78), coreColor.opacity(0)])
        let coreRect = CGRect(
            x: center.x - CGFloat(coreRadius),
            y: center.y - CGFloat(coreRadius),
            width: CGFloat(coreRadius) * 2,
            height: CGFloat(coreRadius) * 2
        )
        context.fill(
            Path(ellipseIn: coreRect),
            with: .radialGradient(
                glow,
                center: center,
                startRadius: 0,
                endRadius: CGFloat(coreRadius)
            )
        )

        for ring in 0..<4 {
            let phase = Double(ring) * 0.9
            let ringBreath = 0.5 + 0.5 * sin(time * 0.6 + phase)
            let radius = maxRadius * radiusScale * (0.30 + 0.16 * Double(ring) + 0.16 * ringBreath + 0.36 * coreEnergy)
            let energy = min(1, coreEnergy * (1 - 0.15 * Double(ring)))
            let rect = CGRect(
                x: center.x - CGFloat(radius),
                y: center.y - CGFloat(radius),
                width: CGFloat(radius) * 2,
                height: CGFloat(radius) * 2
            )
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(energyColor(energy, opacity: 0.10 + 0.24 * ringBreath)),
                lineWidth: CGFloat(1.4 + 3 * pulse)
            )
        }
    }

    private func drawWaveform(context: GraphicsContext, size: CGSize, band: CGRect) {
        let waveform = state.latestFrame.waveform
        guard waveform.count > 1 else { return }

        let amplitude = band.height * 0.38
        let center = band.midY
        let maxVisibleSamples = 256
        let sampleStride = max(1, waveform.count / maxVisibleSamples)
        let displayCount = max(2, Int(ceil(Double(waveform.count) / Double(sampleStride))))
        let step = size.width / CGFloat(displayCount - 1)

        var path = Path()
        var displayIndex = 0
        for sampleIndex in stride(from: 0, to: waveform.count, by: sampleStride) {
            let sample = waveform[sampleIndex]
            let clamped = max(-1.5, min(1.5, CGFloat(sample)))
            let point = CGPoint(x: CGFloat(displayIndex) * step, y: center - clamped * amplitude)
            if displayIndex == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
            displayIndex += 1
        }

        let energy = min(1, Double(state.level) * 6 * intensity)
        guard energy > 0.02 else { return }
        let color = energyColor(max(0.12, energy))
        context.stroke(path, with: .color(color.opacity(0.22)), lineWidth: 7)
        context.stroke(path, with: .color(color.opacity(0.90)), lineWidth: 1.6)
    }

    private func drawSpectralHeat(context: GraphicsContext, size: CGSize, band: CGRect) {
        let bars = state.bars
        guard !bars.isEmpty else { return }

        let rowHeight = max(2, band.height / CGFloat(bars.count))
        for (index, raw) in bars.enumerated() {
            let energy = min(1, pow(Double(raw), 0.62) * 2.2 * intensity)
            guard energy > 0.02 else { continue }
            let y = band.maxY - CGFloat(index + 1) * rowHeight
            let width = size.width * CGFloat(0.28 + energy * 0.72)
            let x = (size.width - width) / 2
            let rect = CGRect(x: x, y: y, width: width, height: rowHeight + 1)
            context.fill(Path(rect), with: .color(energyColor(energy, opacity: 0.035 + energy * 0.16)))
        }
    }

    private func drawFlow(context: GraphicsContext, size: CGSize, band: CGRect, date: Date) {
        let energy = min(1, (Double(state.mid) + Double(state.treble)) * 1.8 * intensity)
        guard energy > 0.015 else { return }

        let time = date.timeIntervalSinceReferenceDate
        for line in 0..<6 {
            let yBase = band.minY + band.height * (CGFloat(line) + 0.5) / 6
            var path = Path()
            let step = max(10, size.width / 80)
            var x: CGFloat = 0
            while x <= size.width {
                let phase = Double(x / max(size.width, 1)) * 8 + Double(line) * 0.9 + time * (0.12 + energy * 0.45)
                let y = yBase + CGFloat(sin(phase)) * band.height * CGFloat(0.03 + energy * 0.11)
                if x == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                x += step
            }
            context.stroke(
                path,
                with: .color(energyColor(0.2 + energy * 0.6, opacity: 0.08 + energy * 0.18)),
                lineWidth: 1.0 + CGFloat(energy) * 2.0
            )
        }
    }

    private func energyColor(_ energy: Double, opacity: Double = 1) -> Color {
        let stops = theme.stops
        let clamped = min(max(energy, 0), 1)
        let scaled = clamped * Double(stops.count - 1)
        let lower = min(Int(scaled), stops.count - 1)
        let upper = min(lower + 1, stops.count - 1)
        let t = scaled - Double(lower)
        let a = stops[lower]
        let b = stops[upper]
        let baseLuminance = [0.5, 0.74, 1.0][min(max(brightnessLevel, 0), 2)]
        // In light mode, keep the energy colors deeper/saturated so they read on
        // a light canvas instead of washing out.
        let luminance = colorScheme == .dark ? baseLuminance : min(baseLuminance, 0.66)
        return Color(
            .sRGB,
            red: (a.red + (b.red - a.red) * t) * luminance,
            green: (a.green + (b.green - a.green) * t) * luminance,
            blue: (a.blue + (b.blue - a.blue) * t) * luminance,
            opacity: opacity
        )
    }
}

/// The Attaché brand lockup (the "A" over its sound-wave equalizer), rendered in
/// SwiftUI so the idle screen shows the real mark instead of a plain wordmark.
/// The letter is passed in neutral; the bars are themed by `barColor`.
struct AttacheBrandMark: View {
    var letterColor: Color
    var barColor: (Int) -> Color
    var glow: Color
    var glowStrength: Double

    // Symmetric equalizer profile mirroring the app icon's bars.
    private let barHeights: [Double] = [0.34, 0.62, 0.84, 1.0, 0.66, 1.0, 0.66, 1.0, 0.84, 0.62, 0.34]

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                letterPath(w: w, h: h)
                    .stroke(
                        letterColor,
                        style: StrokeStyle(lineWidth: w * 0.085, lineCap: .round, lineJoin: .round)
                    )
                bars(w: w, h: h)
            }
            .shadow(color: glow.opacity(0.30 + 0.32 * glowStrength), radius: w * 0.05)
        }
    }

    private func letterPath(w: CGFloat, h: CGFloat) -> Path {
        var path = Path()
        let apex = CGPoint(x: w * 0.5, y: h * 0.05)
        path.move(to: apex)
        path.addLine(to: CGPoint(x: w * 0.27, y: h * 0.66))
        path.move(to: apex)
        path.addLine(to: CGPoint(x: w * 0.73, y: h * 0.66))
        path.move(to: CGPoint(x: w * 0.355, y: h * 0.46))
        path.addLine(to: CGPoint(x: w * 0.645, y: h * 0.46))
        return path
    }

    private func bars(w: CGFloat, h: CGFloat) -> some View {
        let barWidth = w * 0.045
        let gap = w * 0.028
        let count = barHeights.count
        let totalWidth = barWidth * CGFloat(count) + gap * CGFloat(count - 1)
        let startX = (w - totalWidth) / 2
        let baseline = h * 0.965
        let maxBar = h * 0.30
        return ZStack(alignment: .topLeading) {
            ForEach(0..<count, id: \.self) { index in
                let barHeight = maxBar * barHeights[index]
                RoundedRectangle(cornerRadius: barWidth * 0.5)
                    .fill(barColor(index))
                    .frame(width: barWidth, height: barHeight)
                    .position(
                        x: startX + barWidth / 2 + CGFloat(index) * (barWidth + gap),
                        y: baseline - barHeight / 2
                    )
            }
        }
    }
}
