import AttacheCore
import SwiftUI

struct EchoformRendererView: View {
    @ObservedObject var playback: SpeechPlaybackController
    @ObservedObject var timeline: PlaybackTimeline
    /// The Attaché activity contract (INF-268). This view reads its semantic fields
    /// (`unreadCount`) and keeps drawing audio from `timeline` at 20 Hz.
    var activity: AttacheActivityState
    /// The latest one-shot beat for the character renderer (INF-271).
    var activityMoment: AttacheActivityMoment?
    var visualMode: AttacheVisualMode
    var visualSymmetry: AttacheVisualSymmetry = .mirrored
    var idleBrand: AttacheIdleBrand = .mark
    var idleCustomText: String = ""
    var idleImage: NSImage?
    var theme: AttacheTheme
    var brightnessLevel: Int
    var intensity: Double
    /// The mini attache window (INF-272) renders the same hierarchy with no
    /// background plate, so the renderer floats directly on the desktop.
    var transparentBackground = false
    /// Character delights and the shiny easter egg (INF-273), character mode only.
    var characterDelights: CharacterDelights = .none
    var characterShiny = false
    /// Fleet interactivity (INF-275), character mode only.
    var onFleetFocus: ((String) -> Void)?
    var onFleetSwitch: (() -> Void)?
    /// Per-mote right-click context menu (INF-375). `moteMenuModel` maps the
    /// mote's session id to its menu description (title, source, focused
    /// state); the actions run "Stop Watching" and "Unfocus". Left unset, the
    /// character shows only its default personality context menu.
    var moteMenuModel: ((String) -> MoteContextMenuModel?)?
    var onMoteStopWatching: ((String) -> Void)?
    var onMoteUnfocus: ((String) -> Void)?
    /// The focused mote's persisted ring angle (INF-280), character mode only.
    var characterFocusAngle: Double = AttacheCharacterChoreography.defaultFocusAngle
    var onCharacterFocusAngleChanged: ((Double) -> Void)?
    /// The character in the middle of the ring (INF-283), character mode only.
    var character: AttacheCharacter = .robot
    /// Desktop mini attache: show only focus/needs-you/finished (INF-291).
    var fleetNotificationsOnly = false
    /// Echo defaults to a character-sized presence. The parent enters a real
    /// macOS full-screen space on double-click, then this same shared character
    /// renderer grows to the immersive size.
    var compactBars = false
    /// The in-app Echo presence has been expanded into a real full-screen space
    /// (double-click / "Enter Full Screen"). Only then does Echo swap its
    /// character-sized voice bars for the immersive deterministic equalizer that
    /// draws the actual analyzed audio spectrum. The desktop mini window never
    /// sets this, so it keeps the compact presence.
    var fullScreenEqualizer = false
    var onToggleBarsExpansion: (() -> Void)?
    /// Incognito identity (INF-356): true while the active conversation is
    /// private, so the shared character renderer draws its crown band
    /// overlay in both character mode and Echo's voice-bars presence.
    var isPrivate = false
    /// Karaoke captions are on screen for the current speaking turn
    /// (INF-358 check 1), character mode only.
    var isCaptioning = false
    /// An app overlay is open above this renderer (INF-358 check 2): the
    /// character holds its pose instead of animating unseen underneath.
    var overlayVisible = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    @State private var sonar = false
    /// The session id of the fleet mote under the cursor (INF-375), tracked so
    /// the context menu can present that mote's actions on right-click.
    @State private var hoveredMoteSessionID: String?

    var body: some View {
        ZStack {
            if !transparentBackground {
                rendererBackground
            }
            if visualMode == .character {
                // The character owns the whole surface in every phase: it IS the
                // idle screen, the playback visual, and the status display.
                // Fresh 20 Hz audio rides in on the contract so the speaking
                // mouth can track the level.
                AttacheCharacterView(
                    activity: activity.with(audio: state),
                    moment: activityMoment,
                    theme: theme,
                    brightnessLevel: brightnessLevel,
                    delights: characterDelights,
                    shiny: characterShiny,
                    character: character,
                    fleetNotificationsOnly: fleetNotificationsOnly,
                    onFleetFocus: onFleetFocus,
                    onFleetSwitch: onFleetSwitch,
                    onHoveredMoteChange: { hoveredMoteSessionID = $0 },
                    focusAngle: characterFocusAngle,
                    onFocusAngleChanged: onCharacterFocusAngleChanged,
                    isPrivate: isPrivate,
                    isCaptioning: isCaptioning,
                    overlayVisible: overlayVisible
                )
                .contextMenu {
                    moteOrDefaultMenu
                }
            } else if visualMode == .bars {
                if fullScreenEqualizer {
                    // The immersive Echo presentation: the original deterministic
                    // audio-reactive equalizer, drawing the real analyzed audio
                    // spectrum (mirrored bars) plus the waveform and pulse rings.
                    fullEqualizer
                } else {
                    sharedEchoPresence
                }
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
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard visualMode == .bars else { return }
            onToggleBarsExpansion?()
        })
    }

    private var sharedEchoPresence: some View {
        AttacheCharacterView(
            activity: activity.with(audio: state),
            moment: activityMoment,
            theme: theme,
            brightnessLevel: brightnessLevel,
            delights: characterDelights,
            character: character,
            rendersEchoBars: true,
            immersive: !compactBars,
            fleetNotificationsOnly: fleetNotificationsOnly,
            onFleetFocus: onFleetFocus,
            onFleetSwitch: onFleetSwitch,
            onHoveredMoteChange: { hoveredMoteSessionID = $0 },
            focusAngle: characterFocusAngle,
            onFocusAngleChanged: onCharacterFocusAngleChanged,
            isPrivate: isPrivate,
            isCaptioning: isCaptioning,
            overlayVisible: overlayVisible
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Echo voice bars, \(activity.phase.accessibilityTitle)")
        .accessibilityHint(compactBars ? "Double-click to enter full screen" : "Double-click to exit full screen")
        .contextMenu {
            if let menu = hoveredMoteMenu {
                menu
            } else {
                Button(compactBars ? "Enter Full Screen" : "Exit Full Screen") {
                    onToggleBarsExpansion?()
                }
                Button("Edit personalities…") {
                    AttacheNavigation.openPersonalityManager()
                }
                Button("Preview expressions…") {
                    AttacheNavigation.openActivitySimulator()
                }
            }
        }
    }

    /// The immersive Echo equalizer: the pre-unification full-screen voice-bars
    /// presence, restored. It draws the real analyzed audio the playback path
    /// publishes on `timeline.renderState` (deterministic per-band spectrum,
    /// mirrored), shimmers when paused, and rests on the branded idle glow.
    /// No illustrated character, fleet, or crown here: this is the classic
    /// equalizer surface, so the robot and cowboy presences are untouched.
    private var fullEqualizer: some View {
        Group {
            if shouldAnimateContinuously {
                rendererCanvas(date: Date())
            } else if isPausedOnCard {
                pausedShimmer
            } else {
                ambientGlow
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Echo voice bars, \(activity.phase.accessibilityTitle)")
        .accessibilityHint("Double-click to exit full screen")
        .contextMenu {
            Button("Exit Full Screen") {
                onToggleBarsExpansion?()
            }
            Button("Edit personalities…") {
                AttacheNavigation.openPersonalityManager()
            }
            Button("Preview expressions…") {
                AttacheNavigation.openActivitySimulator()
            }
        }
    }

    /// The character's context menu: the hovered mote's actions when the
    /// cursor is over a fleet mote (INF-375), otherwise the default
    /// personality items.
    @ViewBuilder private var moteOrDefaultMenu: some View {
        if let menu = hoveredMoteMenu {
            menu
        } else {
            Button("Edit personalities…") {
                AttacheNavigation.openPersonalityManager()
            }
            Button("Preview expressions…") {
                AttacheNavigation.openActivitySimulator()
            }
        }
    }

    /// The per-mote menu content for the mote currently under the cursor, or
    /// nil when none is (so the caller can fall back to its default items).
    private var hoveredMoteMenu: MoteContextMenuContent? {
        guard let id = hoveredMoteSessionID, let model = moteMenuModel?(id) else { return nil }
        return MoteContextMenuContent(
            model: model,
            onStopWatching: { onMoteStopWatching?(id) },
            onUnfocus: { onMoteUnfocus?(id) }
        )
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
            guard !reduceMotion else { breathing = true; return }
            withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
        .onDisappear { breathing = false }
    }

    // Idle look: a low-key branded animation, a soft breathing glow, gently
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
                    // The Attaché mark (design/attache-logo.svg): full color
                    // by default, a single-color silhouette for the monogram.
                    AttacheMascotMark(
                        arcColor: energyColor(1.0, opacity: 0.96),
                        monochrome: idleBrand == .monogram ? Color.primary.opacity(0.7) : nil,
                        glow: idleBrand == .monogram ? Color.primary.opacity(0.25) : ambientColor,
                        glowStrength: breathing ? 1 : 0.45
                    )
                    .frame(width: 190, height: 190)
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
            guard !reduceMotion else { breathing = true; return }
            withAnimation(.easeInOut(duration: activity.unreadCount > 0 ? 3.4 : 5.0).repeatForever(autoreverses: true)) {
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
        energyColor(activity.unreadCount > 0 ? 0.52 : 0.36)
    }

    // The brand "A" takes the theme's brightest color so the whole mark follows
    // the theme and never disappears (e.g. a white "A" on a light theme).
    // energyColor keeps it legible on both light and dark OS backgrounds.
    private var brandLetterColor: Color {
        energyColor(1.0, opacity: 0.96)
    }

    private var rendererBackground: some View {
        // Dark mode keeps the cinematic near-black stage. Light mode used to
        // be raw system white, which glared and gave the character no stage
        // (INF-286 feedback); it now uses a soft cool-neutral with a gentle
        // radial vignette so the surface reads as chosen and the character
        // sits on a stage instead of a blank sheet. Energy tints stay faint.
        if colorScheme == .dark {
            let center = Color(red: 0.012, green: 0.016, blue: 0.030)
            return AnyView(Rectangle().fill(
                LinearGradient(
                    gradient: Gradient(colors: [
                        energyColor(0.02, opacity: 0.18),
                        center.opacity(0.97),
                        energyColor(0.38, opacity: 0.18)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            ))
        }
        // Soft, slightly cool paper white in the middle, deepening to a
        // muted neutral at the edges.
        let lightCenter = Color(red: 0.957, green: 0.961, blue: 0.976)
        let lightEdge = Color(red: 0.878, green: 0.886, blue: 0.910)
        return AnyView(
            Rectangle()
                .fill(lightCenter)
                .overlay(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            energyColor(0.20, opacity: 0.06),
                            lightCenter.opacity(0),
                            lightEdge.opacity(0.85)
                        ]),
                        center: .center,
                        startRadius: 8,
                        endRadius: 620
                    )
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
            // The bars and waveform are the audio content itself, so they stay
            // under Reduce Motion; the clock-driven pulse rings are decorative
            // and are dropped when the user asks for reduced motion.
            if !reduceMotion {
                drawPulse(context: context, size: size, date: date, restrained: true)
            }
            drawWaveform(context: context, size: size, band: band)
            drawBars(context: context, size: size, band: band)
        case .character:
            // Character mode never reaches the canvas path; AttacheCharacterView owns the
            // surface (see body).
            break
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
        // The mirroring and the per-band response curve are the pure,
        // deterministic mapping in AttacheCore (EchoEqualizerBars), so the same
        // analyzed audio always draws the same equalizer and the mapping is
        // unit-tested independently of the view.
        let heights = EchoEqualizerBars.barHeights(
            from: state.bars,
            intensity: intensity,
            mirrored: visualSymmetry == .mirrored
        )
        guard !heights.isEmpty else { return }

        let count = heights.count
        let gap: CGFloat = 3
        let stageWidth = min(size.width * 0.86, max(320, min(size.width, size.height * 1.35)))
        let stageX = (size.width - stageWidth) / 2
        let barWidth = max(1, (stageWidth - gap * CGFloat(count - 1)) / CGFloat(count))
        let maxHeight = band.height * 0.96
        let center = band.midY

        for index in 0..<count {
            let energy = heights[index]
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
        theme.energyColor(energy, opacity: opacity, brightnessLevel: brightnessLevel, darkScheme: colorScheme == .dark)
    }
}

/// Echo's "face": a small equalizer that uses real audio while speaking and
/// semantic motion for the same thinking, tool, blocked, and error states the
/// illustrated characters consume.
private struct EchoBarsGlyph: View {
    var activity: AttacheActivityState
    var date: Date
    var color: Color

    private let idleProfile: [Double] = [0.28, 0.42, 0.64, 0.88, 0.58, 1, 0.58, 0.88, 0.64, 0.42, 0.28]

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: max(3, proxy.size.width * 0.025)) {
                ForEach(idleProfile.indices, id: \.self) { index in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.38), color],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: proxy.size.height * barHeight(index: index))
                        .shadow(color: color.opacity(activity.phase == .speaking ? 0.42 : 0.18), radius: 5)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func barHeight(index: Int) -> CGFloat {
        let time = date.timeIntervalSinceReferenceDate
        if activity.phase == .speaking, !activity.audio.bars.isEmpty {
            let source = Int(
                (Double(index) / Double(max(1, idleProfile.count - 1)))
                    * Double(activity.audio.bars.count - 1)
            )
            let energy = min(1, pow(Double(activity.audio.bars[source]), 0.55) * 2.8)
            return CGFloat(max(0.08, energy))
        }

        let speed: Double
        let strength: Double
        switch activity.phase {
        case .sleeping: (speed, strength) = (0.55, 0.12)
        case .idle: (speed, strength) = (0.9, 0.18)
        case .agentThinking: (speed, strength) = (3.2, 0.38)
        case .agentResponding: (speed, strength) = (2.3, 0.48)
        case .toolRunning: (speed, strength) = (4.4, 0.42)
        case .paused: (speed, strength) = (0, 0)
        case .blockedOnUser: (speed, strength) = (2.1, 0.25)
        case .error: (speed, strength) = (7.0, 0.32)
        case .speaking: (speed, strength) = (3.0, 0.5)
        }
        let wave = 0.5 + 0.5 * sin(time * speed + Double(index) * 0.78)
        let base = idleProfile[index] * (activity.phase == .paused ? 0.62 : 0.72)
        return CGFloat(min(1, max(0.08, base + wave * strength)))
    }
}

private extension AttacheActivityPhase {
    var accessibilityTitle: String {
        switch self {
        case .sleeping: return "sleeping"
        case .idle: return "idle"
        case .agentThinking: return "agent thinking"
        case .agentResponding: return "agent responding"
        case .toolRunning: return "tool running"
        case .speaking: return "speaking"
        case .paused: return "paused"
        case .blockedOnUser: return "waiting for you"
        case .error: return "error"
        }
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
