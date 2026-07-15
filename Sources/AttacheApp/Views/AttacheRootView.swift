import AppKit
import AttacheCore
import SwiftUI

enum AttacheSurfaceMode {
    case live
    case voicemail
}

private struct ThemeAccentKey: EnvironmentKey {
    static let defaultValue: Color = .accentColor
}

extension EnvironmentValues {
    /// The active theme's signature color, so highlight and selection chrome in
    /// child views follows the chosen theme instead of the system accent.
    var themeAccent: Color {
        get { self[ThemeAccentKey.self] }
        set { self[ThemeAccentKey.self] = newValue }
    }
}

extension View {
    /// Suppress the system focus ring (the blue outline) on `.focusable()` content
    /// so it doesn't fight the theme. No-op before macOS 14.
    @ViewBuilder func disableFocusRing() -> some View {
        if #available(macOS 14.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }
}

enum DockItem { case unread, focus, mode, talk, send, personality, settings }

/// How much of the window bottom the floating interaction stack occupies.
/// Each bottom-anchored overlay reports its band (content height plus its
/// bottom clearance); the tallest wins so the character renderer can reserve it.
private struct BottomOverlayHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    func reportsBottomOverlayBand(clearance: CGFloat) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(
                key: BottomOverlayHeightKey.self,
                value: proxy.size.height + clearance
            )
        })
    }
}

struct AttacheRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var playback: SpeechPlaybackController
    @ObservedObject var micTranscript: MicTranscriptController
    @State var hoveredDockItem: DockItem?
    @State private var chromeAwake = true
    @State private var idleWorkItem: DispatchWorkItem?
    @State var focusConfirmationWorkItem: DispatchWorkItem?
    @State var focusConfirmationVisible = false
    @State var controlsPinned = false
    @State var surfaceMode: AttacheSurfaceMode = .live
    @State var liveComposerVisible = false
    @State private var paletteVisible = false
    @State private var shortcutsVisible = false
    @State var dockHovering = false
    @State var inboxVisible = false
    @State var personalitySwitcherVisible = false
    @State private var historyVisible = false
    @State var callHolding = false
    @State var pendingCallPresentationProvider: AttachePresentationProvider?
    // Cloud consent for the recap / follow-up / live follow-up recovery
    // menus (INF-254): one generic pending switch instead of one state var
    // and sheet per surface, since the consent moment is identical everywhere
    // except which underlying `select...RecoveryProvider` runs on Enable.
    @State var pendingRecoveryProviderSwitch: PendingRecoveryProviderSwitch?
    @State private var nearBottom = false
    @State private var windowHeight: CGFloat = 700
    @State private var echoExpanded = false
    /// Tallest bottom-anchored overlay band (composer, captions, transport,
    /// dock) this frame. The character renderer is inset by it so the character is
    /// never covered; the full-bleed visualizer modes ignore it by design.
    @State private var bottomOverlayHeight: CGFloat = 0

    /// The character's reserved bottom band. The floor stays constant whether the
    /// auto-hiding dock is showing or not, so waking the chrome by moving
    /// the mouse never shifts the ring while the user reaches for a mote;
    /// the caption/composer band still grows the inset when it is taller.
    private var presenceBottomInset: CGFloat {
        let usesCharacterSpace = model.visualMode == .character
            || (model.visualMode == .bars && !echoExpanded)
        return usesCharacterSpace ? max(bottomOverlayHeight, 80) : 0
    }

    init(model: AppModel) {
        self.model = model
        self.playback = model.playback
        self.micTranscript = model.micTranscript
    }

    // The active theme's signature color (e.g. Cyberpunk pink), used for every
    // highlight and selection accent in Attaché window.
    var accent: Color { model.theme.signatureColor }

    // Ambient home: the chrome is visible while the pointer is recently active (or
    // pinned, or you're interacting), and fades to the bare glow when still.
    private var controlsVisible: Bool {
        !model.autoHideControls || chromeAwake || controlsPinned || paletteVisible || liveComposerVisible
            || personalitySwitcherVisible || focusConfirmationVisible || model.conversationActive
    }

    private func pointerMoved(at location: CGPoint) {
        if !chromeAwake {
            withAnimation(.easeInOut(duration: 0.22)) { chromeAwake = true }
        }
        let bottom = location.y > windowHeight - 150
        if bottom != nearBottom {
            withAnimation(.easeInOut(duration: 0.2)) { nearBottom = bottom }
        }
        scheduleIdleFade()
    }

    private func scheduleIdleFade() {
        idleWorkItem?.cancel()
        guard model.autoHideControls, !controlsPinned, !paletteVisible, !liveComposerVisible,
              !personalitySwitcherVisible, !focusConfirmationVisible else { return }
        let work = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.4)) { chromeAwake = false }
        }
        idleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, model.autoHideDelaySeconds), execute: work)
    }

    /// Wakes the chrome and shows the dock focus status card for a moment
    /// whenever focus changes, then lets everything fade again.
    func showFocusConfirmation() {
        focusConfirmationWorkItem?.cancel()
        if !chromeAwake {
            withAnimation(.easeInOut(duration: 0.18)) { chromeAwake = true }
        }
        withAnimation(.easeInOut(duration: 0.18)) { focusConfirmationVisible = true }
        let work = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.35)) { focusConfirmationVisible = false }
            scheduleIdleFade()
        }
        focusConfirmationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(model.surfaceOpacity)
                .ignoresSafeArea()

            EchoformRendererView(
                playback: playback,
                timeline: playback.clock,
                activity: model.attacheActivity,
                activityMoment: model.attacheMoment,
                visualMode: model.visualMode,
                visualSymmetry: .mirrored,
                idleBrand: .mark,
                theme: model.theme,
                brightnessLevel: 1,
                intensity: 1.0,
                characterDelights: CharacterDelights(
                    typesAlong: true,
                    rareIdles: true,
                    hoverReacts: true
                ),
                characterShiny: model.characterShiny,
                onFleetFocus: { model.focusCodexSession($0) },
                onFleetSwitch: {
                    NotificationCenter.default.post(name: .attacheOpenPalette, object: nil)
                },
                characterFocusAngle: model.characterFocusAngle,
                onCharacterFocusAngleChanged: { model.characterFocusAngle = $0 },
                character: model.character,
                compactBars: model.visualMode == .bars && !echoExpanded,
                onToggleBarsExpansion: {
                    guard let window = NSApp.keyWindow else { return }
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                        echoExpanded.toggle()
                    }
                    window.toggleFullScreen(nil)
                }
            )
            // A personality change reads like changing characters: the old
            // presence eases out and the new one settles in. No spoken greeting
            // fires here, so switching remains quick and non-interruptive.
            .id(model.activePersonalityID)
            .transition(.opacity.combined(with: .scale(scale: 0.86)))
            .animation(.spring(response: 0.46, dampingFraction: 0.82), value: model.activePersonalityID)
            .opacity(model.surfaceOpacity)
            .ignoresSafeArea()
            .padding(.bottom, presenceBottomInset)
            .animation(.easeInOut(duration: 0.22), value: presenceBottomInset)

            if surfaceMode == .live,
               model.showActivityInsights,
               !model.activityPhrases.isEmpty,
               !playbackSurfaceActive {
                ActivityInsightHeatMap(phrases: model.activityPhrases, theme: model.theme)
                    .opacity(model.surfaceOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            conversationOverlay
                .allowsHitTesting(false)

            captionsToggle

            if surfaceMode == .live {
                liveModeOverlay
                    .transition(.opacity)

                liveCallPlaybackHUD
                    .transition(.opacity.combined(with: .move(edge: .bottom)))

                if controlsVisible {
                    slimDock
                        .reportsBottomOverlayBand(clearance: 18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 18)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }

            if surfaceMode == .voicemail {
                voicemailModeOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }

            if surfaceMode == .live {
                LyricsSidePanel(
                    model: model,
                    playback: playback,
                    scrubberHoverExclusionEnabled: liveTransportVisible
                )
                    .transition(.opacity)
            }

            if paletteVisible {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { paletteVisible = false }
                SessionCommandPalette(model: model, isVisible: $paletteVisible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if inboxVisible {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { inboxVisible = false }
                InboxOverlay(model: model, isVisible: $inboxVisible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if historyVisible {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { historyVisible = false }
                HistoryOverlay(model: model, isVisible: $historyVisible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if personalitySwitcherVisible {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { personalitySwitcherVisible = false }
                CharacterSwitcherPalette(model: model, isVisible: $personalitySwitcherVisible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if shortcutsVisible {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { shortcutsVisible = false }
                KeyboardShortcutsOverlay(isVisible: $shortcutsVisible, accent: accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if model.activitySimulatorEnabled {
                ActivitySimulatorPanel(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 18)
                    .padding(.trailing, 18)
            }

        }
        .contentShape(Rectangle())
        .attacheTextScale(model.uiTextScale)
        .onPreferenceChange(BottomOverlayHeightKey.self) { bottomOverlayHeight = $0 }
        .animation(.easeInOut(duration: 0.18), value: inboxVisible)
        .animation(.easeInOut(duration: 0.18), value: personalitySwitcherVisible)
        .animation(.easeInOut(duration: 0.18), value: shortcutsVisible)
        .background(
            KeyboardShortcutMonitor(
                onEscape: handleEscapeKey,
                onDelete: handleDeleteKey,
                onSpace: handleSpaceKey,
                onLeftArrow: handleLeftArrowKey,
                onRightArrow: handleRightArrowKey,
                onCaptionResize: handleCaptionResize,
                onTextZoom: handleTextZoom,
                onPreviousPersonality: handlePreviousPersonalityKey,
                onNextPersonality: handleNextPersonalityKey,
                onOpenShortcuts: handleOpenShortcutsKey,
                onSpeedKey: handleSpeedKey
            )
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                pointerMoved(at: location)
            case .ended:
                if nearBottom {
                    withAnimation(.easeInOut(duration: 0.2)) { nearBottom = false }
                }
                scheduleIdleFade()
            }
        }
        .onAppear { scheduleIdleFade() }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingSheet(model: model)
        }
        .sheet(isPresented: $model.showTwoWayEnable) {
            TwoWayEnableSheet(
                sessionTitle: model.twoWayEnableTargetTitle ?? "this session",
                directSendEnabled: model.directAgentSendEnabled,
                onEnable: { model.confirmEnableTwoWay() },
                onCancel: { model.cancelEnableTwoWay() }
            )
        }
        .sheet(item: $model.pendingInstruction) { instruction in
            TwoWayConfirmSheet(
                instruction: instruction,
                onSend: { model.confirmStagedInstruction() },
                onCancel: { model.discardStagedInstruction() }
            )
        }
        .sheet(item: $pendingCallPresentationProvider) { provider in
            CloudConsentSheet(
                providerName: provider.title,
                produces: "live answers",
                sends: "your question and the attached session context",
                onEnable: {
                    model.acknowledgeCloudConsent(for: provider)
                    model.selectConversationRecoveryProvider(provider)
                    pendingCallPresentationProvider = nil
                },
                onCancel: { pendingCallPresentationProvider = nil }
            )
        }
        .sheet(item: $pendingRecoveryProviderSwitch) { pending in
            CloudConsentSheet(
                providerName: pending.provider.title,
                produces: pending.surface.consentProduces,
                sends: pending.surface.consentSends,
                onEnable: {
                    model.acknowledgeCloudConsent(for: pending.provider)
                    applyRecoveryProviderSwitch(pending.provider, surface: pending.surface)
                    pendingRecoveryProviderSwitch = nil
                },
                onCancel: { pendingRecoveryProviderSwitch = nil }
            )
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { windowHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { windowHeight = $0 }
            }
        )
        .onExitCommand {
            withAnimation(.easeInOut(duration: 0.16)) {
                surfaceMode = .live
            }
        }
        .focusable()
        .disableFocusRing()
        .tint(model.theme.signatureColor)
        .environment(\.themeAccent, model.theme.signatureColor)
        .animation(.easeInOut(duration: 0.18), value: controlsVisible)
        .animation(.easeInOut(duration: 0.18), value: focusConfirmationVisible)
        .animation(.easeInOut(duration: 0.18), value: surfaceMode)
        .animation(.easeInOut(duration: 0.2), value: model.conversationActive)
        .onChange(of: model.attachedCodexSessionID) { _ in showFocusConfirmation() }
        .onChange(of: model.activePersonalityID) { _ in echoExpanded = false }
        .onChange(of: personalitySwitcherVisible) { isVisible in
            if !isVisible { scheduleIdleFade() }
        }
        .onChange(of: model.visualMode) { mode in
            if mode != .bars { echoExpanded = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard model.visualMode == .bars,
                  let window = note.object as? NSWindow,
                  window.title == AttacheAppSupport.appDisplayName else { return }
            echoExpanded = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow,
                  window.title == AttacheAppSupport.appDisplayName else { return }
            echoExpanded = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .attacheOpenTalk)) { _ in
            withAnimation(.easeInOut(duration: 0.18)) {
                surfaceMode = .live
                chromeAwake = true
                nearBottom = true
                model.startConversation()
            }
            scheduleIdleFade()
        }
        .onReceive(NotificationCenter.default.publisher(for: .attacheOpenInbox)) { _ in
            withAnimation(.easeInOut(duration: 0.16)) {
                surfaceMode = .live
                paletteVisible = false
                personalitySwitcherVisible = false
                historyVisible = false
                inboxVisible = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .attacheOpenHistory)) { _ in
            withAnimation(.easeInOut(duration: 0.16)) {
                surfaceMode = .live
                paletteVisible = false
                personalitySwitcherVisible = false
                inboxVisible = false
                historyVisible = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .attacheOpenVoicemailSurface)) { _ in
            withAnimation(.easeInOut(duration: 0.16)) {
                inboxVisible = false
                personalitySwitcherVisible = false
                surfaceMode = .voicemail
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .attacheOpenPalette)) { _ in
            withAnimation(.easeInOut(duration: 0.16)) {
                surfaceMode = .live
                inboxVisible = false
                personalitySwitcherVisible = false
                historyVisible = false
                paletteVisible = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .attacheOpenCharacterSwitcher)) { _ in
            withAnimation(.easeInOut(duration: 0.16)) {
                surfaceMode = .live
                chromeAwake = true
                paletteVisible = false
                inboxVisible = false
                historyVisible = false
                shortcutsVisible = false
                personalitySwitcherVisible = true
            }
            scheduleIdleFade()
        }
        .onReceive(NotificationCenter.default.publisher(for: .attacheOpenShortcuts)) { _ in
            withAnimation(.easeInOut(duration: 0.16)) {
                paletteVisible = false
                inboxVisible = false
                historyVisible = false
                personalitySwitcherVisible = false
                shortcutsVisible = true
            }
        }
    }

    /// S / A / R adjust playback speed while a recap is loaded (playing or
    /// paused), with a transient chip confirming the new rate.
    private func handleSpeedKey(_ delta: Int) -> Bool {
        guard playback.isPlaying || playback.isPaused else { return false }
        if delta == 0 {
            model.playbackSpeed = 1.0
        } else {
            model.playbackSpeed = min(1.6, max(0.8, model.playbackSpeed + Double(delta) * 0.1))
        }
        model.postHomeNotice(String(format: "%.2fx", model.playbackSpeed), kind: .info, duration: 1.2)
        return true
    }

    private func handleEscapeKey() -> Bool {
        if shortcutsVisible {
            withAnimation(.easeInOut(duration: 0.16)) { shortcutsVisible = false }
            return true
        }
        if historyVisible {
            withAnimation(.easeInOut(duration: 0.16)) { historyVisible = false }
            return true
        }
        if personalitySwitcherVisible {
            withAnimation(.easeInOut(duration: 0.16)) { personalitySwitcherVisible = false }
            return true
        }
        if inboxVisible {
            withAnimation(.easeInOut(duration: 0.16)) { inboxVisible = false }
            return true
        }
        if paletteVisible {
            withAnimation(.easeInOut(duration: 0.16)) { paletteVisible = false }
            return true
        }
        // Escape dismisses live playback immediately (v0.1.2 behavior).
        if model.dismissCurrentPlayback() {
            withAnimation(.easeInOut(duration: 0.16)) {
                surfaceMode = .live
                liveComposerVisible = false
                chromeAwake = true
                nearBottom = true
            }
            scheduleIdleFade()
            return true
        }
        if model.conversationActive {
            withAnimation(.easeInOut(duration: 0.18)) { model.endConversation() }
            return true
        }
        guard liveComposerVisible || surfaceMode == .voicemail else {
            return false
        }
        withAnimation(.easeInOut(duration: 0.16)) {
            surfaceMode = .live
            liveComposerVisible = false
        }
        return true
    }

    private func handleDeleteKey() -> Bool {
        guard surfaceMode == .voicemail, model.selectedCard != nil else {
            return false
        }
        model.archiveSelected()
        return true
    }

    // Media-player keys: space toggles play/pause, arrows rewind/fast-forward by
    // the Settings skip interval. Skipped when a text field is focused (handled in
    // the monitor) so typing still works.
    private func handleSpaceKey() -> Bool {
        if livePreviewTransportVisible {
            playback.togglePause()
            return true
        }
        guard model.selectedCard != nil else { return false }
        model.toggleSelectedPlayback()
        return true
    }

    private func handleLeftArrowKey() -> Bool {
        if livePreviewTransportVisible {
            skipPreviewPlayback(forward: false)
            return true
        }
        guard model.selectedCard != nil else { return false }
        model.skipBackward()
        return true
    }

    private func handleRightArrowKey() -> Bool {
        if livePreviewTransportVisible {
            skipPreviewPlayback(forward: true)
            return true
        }
        guard model.selectedCard != nil else { return false }
        model.skipForward()
        return true
    }

    private func handlePreviousPersonalityKey() -> Bool {
        model.selectAdjacentPersonality(offset: -1)
        return true
    }

    private func handleNextPersonalityKey() -> Bool {
        model.selectAdjacentPersonality(offset: 1)
        return true
    }

    private func handleOpenShortcutsKey() -> Bool {
        withAnimation(.easeInOut(duration: 0.16)) {
            shortcutsVisible = true
        }
        return true
    }

    // +/- resize the caption while it's on screen.
    private func handleCaptionResize(_ delta: Int) -> Bool {
        guard captionOverlayVisible else { return false }
        model.adjustCaptionLines(by: delta)
        return true
    }

    // Command +/- zoom the whole UI (the INF-149 text scale).
    private func handleTextZoom(_ delta: Int) -> Bool {
        model.adjustUITextScale(by: delta > 0 ? 0.05 : -0.05)
        return true
    }

    private var conversationOverlay: some View {
        VStack(spacing: 0) {
            topTranscriptOverlay
            Spacer()
            if surfaceMode != .live {
                bottomResponseOverlay
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var topTranscriptOverlay: some View {
        if topOverlayVisible {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(transcriptOverlayText)
                        .typoSection()
                        .foregroundStyle(.primary.opacity(0.92))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(voiceInputContext)
                        .typoCaption(.medium, design: .monospaced)
                        .foregroundStyle(.primary.opacity(0.52))
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
            .readingPlate(theme: model.theme, cornerRadius: 8, minimumOpacity: 0.65)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var transcriptOverlayText: String {
        let text = micTranscript.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return micTranscript.isPreparing ? "Starting microphone..." : "Listening..."
    }

    @ViewBuilder
    private var bottomResponseOverlay: some View {
        if model.captionsEnabled,
           playback.isPlaying || playback.isPaused {
            ZStack {
                ResponseCaptionLayer(
                    timeline: playback.clock,
                    text: playback.currentText,
                    alignment: playback.currentAlignment,
                    highlightColor: model.theme.captionHighlightColor,
                    syncOffsetMs: model.captionSyncOffsetMs,
                    fontSize: CGFloat(model.captionFontSize),
                    lineCount: model.captionLineCount,
                    onSeek: seekToCaptionTime,
                    onSeekAndResume: seekToCaptionTimeAndResume
                )
                .frame(maxWidth: 760)
                .readingPlate(theme: model.theme, cornerRadius: 12, minimumOpacity: 0.65)
                .background(
                    CaptionScrollMonitor(enabled: true) { model.adjustCaptionLines(by: $0) }
                )
                .frame(maxWidth: .infinity, alignment: .bottom)
                .accessibilityLabel(playback.isPaused ? "Playback paused" : "Assistant speaking")

                // The visual karaoke view is composed from many animated word
                // fragments; SwiftUI does not reliably expose their full text to
                // AX. Keep a non-visible transcript node so VoiceOver and smoke
                // tests can verify the spoken content without adding another
                // visible answer surface.
                Text(playback.currentText)
                    .font(.system(size: 1))
                    .lineLimit(1)
                    .frame(width: 1, height: 1)
                    .clipped()
                    .opacity(0.001)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(playback.isPaused ? "Playback paused" : "Assistant speaking") transcript \(playback.currentText)")
                    .accessibilityValue(playback.currentText)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, alignment: .bottom)
        }
    }

    // A captions on/off toggle on the main screen, so distracting karaoke can be
    // dismissed instantly (and brought back) without opening Settings. Hover-to-
    // seek on individual words still works while captions are shown.
    @ViewBuilder
    private var captionsToggle: some View {
        if playback.isPlaying || playback.isPaused {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button { model.captionsEnabled.toggle() } label: {
                        Image(systemName: model.captionsEnabled ? "captions.bubble.fill" : "captions.bubble")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(model.captionsEnabled ? model.theme.signatureColor : Color.secondary)
                            .frame(width: 36, height: 30)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(model.captionsEnabled ? "Hide captions" : "Show captions")
                    .accessibilityLabel(model.captionsEnabled ? "Hide captions" : "Show captions")
                }
            }
            .padding(.trailing, 22)
            .padding(.bottom, 100)
            .animation(.easeInOut(duration: 0.18), value: model.captionsEnabled)
        }
    }

    private var liveModeOverlay: some View {
        VStack(spacing: 0) {
            Spacer()

            if let talkSession = model.talkContextSession, liveComposerShouldShow {
                liveSessionComposer(for: talkSession)
                    .padding(.horizontal, 34)
                    .reportsBottomOverlayBand(clearance: liveComposerBottomPadding)
                    .padding(.bottom, liveComposerBottomPadding)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    /// The bottom of the live surface is one ordered interaction stack:
    /// composer, captions, transport, then the dock below it. Keeping these
    /// views in the same VStack makes overlap impossible for card playback and
    /// conversational preview playback alike, while leaving the composer
    /// available for notes or a follow-up during a long response.
    @ViewBuilder
    private var liveCallPlaybackHUD: some View {
        if model.onCall || liveBottomHUDVisible {
            VStack(spacing: 16) {
                if model.onCall {
                    // A call uses the same persistent-input convention as a
                    // standard chat: keep the composer available while the user
                    // listens, pauses, seeks, or starts drafting a follow-up.
                    onCallHUD
                        .transition(.opacity)
                }

                if liveBottomHUDVisible {
                    liveBottomHUDContent
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .reportsBottomOverlayBand(clearance: 80)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var liveBottomHUDContent: some View {
        VStack(spacing: 14) {
            if captionOverlayVisible {
                bottomResponseOverlay
                    .padding(.horizontal, 10)
            }
            if liveTransportVisible {
                liveTransportBar
                    .padding(.horizontal, 6)
            } else if livePreviewTransportVisible {
                livePreviewTransportBar
                    .padding(.horizontal, 6)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // True whenever a recap is actively playing or paused in live mode, so the
    // transport bar can ride along with (or without) the captions.
    var liveTransportVisible: Bool {
        (playback.isPlaying || playback.isPaused)
            && model.selectedCard.map { playback.currentCardID == $0.id } == true
    }

    private var livePreviewTransportVisible: Bool {
        (playback.isPlaying || playback.isPaused)
            && playback.currentCardID == nil
            && playback.durationMs > 0
            && !playback.currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var playbackSurfaceActive: Bool {
        playback.isPlaying
            || playback.isPaused
            || !playback.currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var liveBottomHUDVisible: Bool {
        captionOverlayVisible || liveTransportVisible || livePreviewTransportVisible
    }

    var liveBottomHUDMaxHeight: CGFloat {
        if captionOverlayVisible {
            return 140 + CGFloat(model.captionLineCount) * 38
        }
        return 150
    }

    private var livePreviewTransportBar: some View {
        VStack(spacing: 9) {
            HStack(spacing: 11) {
                PlaybackScrubberSlider(
                    timeline: playback.clock,
                    isActiveCard: true,
                    playbackDurationMs: playback.durationMs,
                    fallbackProgress: 0,
                    canSeek: playback.durationMs > 0,
                    onSeek: seekPreviewPlayback(to:)
                )
                .tint(accent)
                PlaybackTimeLabel(
                    timeline: playback.clock,
                    isActiveCard: true,
                    playbackDurationMs: playback.durationMs,
                    cardDurationMs: playback.durationMs,
                    fallbackProgress: 0
                )
            }
            HStack(spacing: 24) {
                TransportButton(
                    systemImage: skipSymbol("gobackward", model.seekStepSeconds),
                    accent: accent,
                    help: "Back \(model.seekStepSeconds)s"
                ) { skipPreviewPlayback(forward: false) }

                TransportButton(
                    systemImage: playback.isPaused ? "play.fill" : "pause.fill",
                    accent: accent,
                    prominent: true,
                    help: playback.isPaused ? "Resume" : "Pause"
                ) { playback.togglePause() }

                TransportButton(
                    systemImage: skipSymbol("goforward", model.seekStepSeconds),
                    accent: accent,
                    help: "Forward \(model.seekStepSeconds)s"
                ) { skipPreviewPlayback(forward: true) }

                speedBadge
            }
        }
    }

    /// The rate readout that rides under the transport: click cycles presets,
    /// S / D / R adjust from the keyboard.
    private var speedBadge: some View {
        Button(action: model.cyclePlaybackSpeed) {
            Text(model.playbackSpeedLabel)
                .typoCaption(.bold, monoDigit: true)
                .foregroundStyle(abs(model.playbackSpeed - 1.0) < 0.01 ? Color.secondary : accent)
                .frame(minWidth: 34)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial.opacity(0.6), in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("Playback speed. Click to cycle; S slower, D faster, R resets.")
        .accessibilityLabel("Playback speed \(model.playbackSpeedLabel)")
    }

    private func seekPreviewPlayback(to progress: Double) {
        guard playback.durationMs > 0 else { return }
        let clamped = min(1, max(0, progress))
        playback.seek(to: Int((Double(playback.durationMs) * clamped).rounded()))
    }

    private func skipPreviewPlayback(forward: Bool) {
        let delta = model.seekStepSeconds * 1000 * (forward ? 1 : -1)
        playback.seek(by: delta)
    }

    private var liveComposerBottomPadding: CGFloat {
        // The off-call send composer is still an independent overlay. Reserve
        // the bottom HUD's content height, its 80-point dock clearance, and a
        // 16-point visual gap so it follows the same no-overlap contract.
        liveBottomHUDVisible ? liveBottomHUDMaxHeight + 96 : 22
    }

    // Transport controls for the speaking recap: scrub bar, time, and
    // back / play-pause / forward, all driving the same model the media keys do.
    private var liveTransportBar: some View {
        let card = model.selectedCard
        let active = card.map { isActiveCard($0) } ?? false
        // INF-251 (A3): on-call the top bar is suppressed, so its "session ·
        // project" provenance (`cardContext`) moves here as a leading caption,
        // the same data the top bar would have shown for this card. Off-call,
        // the top bar still carries it, so this stays hidden there to avoid
        // showing it twice.
        let provenance = (model.onCall ? card.map(cardContext) : nil).flatMap { $0.isEmpty ? nil : $0 }
        return VStack(spacing: 9) {
            if let provenance {
                HStack {
                    Text(provenance)
                        .typoCaption(.medium, design: .monospaced)
                        .foregroundStyle(.primary.opacity(0.52))
                        .lineLimit(1)
                    Spacer()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Call context \(provenance)")
            }
            HStack(spacing: 11) {
                PlaybackScrubberSlider(
                    timeline: playback.clock,
                    isActiveCard: active,
                    playbackDurationMs: playback.durationMs,
                    fallbackProgress: model.selectedStartProgress,
                    canSeek: card.map { canSeek($0) } ?? false,
                    onSeek: { model.seekSelected(to: $0) }
                )
                .tint(accent)
                PlaybackTimeLabel(
                    timeline: playback.clock,
                    isActiveCard: active,
                    playbackDurationMs: playback.durationMs,
                    cardDurationMs: card?.durationMs ?? 0,
                    fallbackProgress: model.selectedStartProgress
                )
            }
            HStack(spacing: 24) {
                TransportButton(
                    systemImage: skipSymbol("gobackward", model.seekStepSeconds),
                    accent: accent,
                    help: "Back \(model.seekStepSeconds)s"
                ) { model.skipBackward() }

                TransportButton(
                    systemImage: card.map { primaryPlaybackIcon(for: $0) } ?? "play.fill",
                    accent: accent,
                    prominent: true,
                    help: card.map { primaryPlaybackHelp(for: $0) } ?? "Play"
                ) { model.toggleSelectedPlayback() }

                TransportButton(
                    systemImage: skipSymbol("goforward", model.seekStepSeconds),
                    accent: accent,
                    help: "Forward \(model.seekStepSeconds)s"
                ) { model.skipForward() }

                speedBadge
            }
        }
    }

    // SF Symbols only ship numbered go-back/forward glyphs for a few intervals;
    // fall back to the plain glyph (the tooltip still states the seconds).
    private func skipSymbol(_ base: String, _ seconds: Int) -> String {
        [5, 10, 15, 30, 45, 60, 75, 90].contains(seconds) ? "\(base).\(seconds)" : base
    }


    private var captionOverlayVisible: Bool {
        model.captionsEnabled
            && (playback.isPlaying || playback.isPaused)
            && !playback.currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        if let currentCardID = playback.currentCardID,
           model.selectedCard?.id == currentCardID {
            model.seekToCaptionTimeAndResume(captionTimeMs)
        } else {
            playback.seek(to: max(0, captionTimeMs - model.captionSyncOffsetMs))
            if playback.isPaused {
                playback.resume()
            }
        }
    }

    private var liveComposerShouldShow: Bool {
        liveComposerVisible
            || model.isGeneratingLiveFollowUpAnswer
    }

    // INF-263: the top box is now exclusively the "eyes-up" surface for your
    // own live dictation (nowhere else to render it while a turn is being
    // captured). It never shows agent/call/playback status, on-call or off
    // -call: that all lives in the bottom composer (on-call) or the bottom
    // caption/transport surface (off-call, `bottomResponseOverlay`).
    private var topOverlayVisible: Bool {
        micTranscript.isPreparing || micTranscript.isListening || !micTranscript.transcript.isEmpty
    }

    private var voiceInputContext: String {
        let language = AttacheCaptionLanguage.named(model.spokenLanguage).name
        return "\(language) / system speech / \(micTranscript.status)"
    }

    private var voiceInputBinding: Binding<Bool> {
        Binding(
            get: { micTranscript.isListening },
            set: { _ in model.toggleVoiceInput() }
        )
    }

    func cardContext(_ card: VoicemailCard) -> String {
        let project = card.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        return [card.sessionTitle, project]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    func primaryPlaybackIcon(for card: VoicemailCard) -> String {
        if playback.currentCardID == card.id, playback.isPlaying, !playback.isPaused {
            return "pause.fill"
        }
        return "play.fill"
    }

    func primaryPlaybackHelp(for card: VoicemailCard) -> String {
        if playback.currentCardID == card.id, playback.isPlaying {
            return playback.isPaused ? "Resume" : "Pause"
        }
        return "Play"
    }

    func canSeek(_ card: VoicemailCard) -> Bool {
        card.durationMs > 0 || (playback.currentCardID == card.id && playback.durationMs > 0)
    }

    func isActiveCard(_ card: VoicemailCard) -> Bool {
        playback.currentCardID == card.id && playback.isPlaying
    }


}
