import AppKit
import AttacheCore
import Combine
import SwiftUI

/// The desktop mini attache (INF-272): a borderless, transparent,
/// always-on-top window showing just the active renderer, so the character (or the
/// bars) lives on the desktop instead of inside window chrome. It reuses the
/// same content hierarchy as the main window (`EchoformRendererView` with a
/// transparent background) rather than forking it.
///
/// Space behavior, decided deliberately: the window joins ALL Spaces
/// (`.canJoinAllSpaces` + `.fullScreenAuxiliary`). The attache's whole
/// point is ambient presence while you work somewhere else; a character pinned to
/// one Space is invisible exactly when the agents are busiest. Level is
/// `.floating`: above normal windows, below screen savers and modal panels.
final class MiniAttacheWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []
    static let defaultSize = NSSize(width: 280, height: 300)

    init(model: AppModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.minSize = NSSize(width: 180, height: 194)
        panel.maxSize = NSSize(width: 560, height: 600)
        panel.title = "Attaché Mini Window"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: MiniAttacheView(model: model))
        super.init(window: panel)
        panel.delegate = self

        model.$miniAttacheClickThrough
            .receive(on: RunLoop.main)
            .sink { [weak self] clickThrough in
                self?.window?.ignoresMouseEvents = clickThrough
            }
            .store(in: &cancellables)
        model.miniAttacheResize
            .receive(on: RunLoop.main)
            .sink { [weak self] size in
                self?.setSize(size)
            }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        guard let window else { return }
        window.setFrame(restoredFrame(), display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    func windowDidMove(_ notification: Notification) {
        persistFrame()
    }

    func windowDidResize(_ notification: Notification) {
        persistFrame()
    }

    /// A display was attached or detached: re-resolve against the saved frame
    /// for the NEW arrangement, falling back to a visible default so the
    /// attache is never stranded offscreen.
    @objc private func screenParametersChanged() {
        guard let window, window.isVisible else { return }
        window.setFrame(restoredFrame(), display: true)
    }

    func setSize(_ size: NSSize) {
        guard let window else { return }
        var frame = window.frame
        frame.origin.y += frame.size.height - size.height
        frame.size = size
        window.setFrame(frame, display: true)
        persistFrame()
    }

    // MARK: Frame persistence, keyed by display arrangement

    /// One key per display arrangement, so the two-monitor position and the
    /// laptop-only position are remembered independently and each restores
    /// when its arrangement returns.
    static func arrangementKey(for screenFrames: [NSRect]) -> String {
        screenFrames
            .map { "\(Int($0.origin.x)),\(Int($0.origin.y)),\(Int($0.width)),\(Int($0.height))" }
            .sorted()
            .joined(separator: "|")
    }

    /// Pure frame resolution: the saved frame wins when it is still visibly
    /// on one of the current screens; anything else lands at the default spot
    /// (bottom-right of the first screen, inset), so a vanished display can
    /// never strand the attache. Unit-tested in MiniAttacheFrameTests.
    static func resolvedFrame(saved: NSRect?, screens: [NSRect], size fallbackSize: NSSize) -> NSRect {
        let primary = screens.first ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let saved {
            let visibleEnough = screens.contains { screen in
                let overlap = screen.intersection(saved)
                return overlap.width >= 60 && overlap.height >= 60
            }
            if visibleEnough {
                return saved
            }
        }
        let size = saved?.size ?? fallbackSize
        return NSRect(
            x: primary.maxX - size.width - 32,
            y: primary.minY + 48,
            width: size.width,
            height: size.height
        )
    }

    private func restoredFrame() -> NSRect {
        let screens = NSScreen.screens.map(\.frame)
        let key = Self.arrangementKey(for: screens)
        let saved = storedFrames()[key].map { NSRectFromString($0) }
        return Self.resolvedFrame(saved: saved, screens: screens, size: Self.defaultSize)
    }

    private func persistFrame() {
        guard let window else { return }
        let key = Self.arrangementKey(for: NSScreen.screens.map(\.frame))
        var frames = storedFrames()
        frames[key] = NSStringFromRect(window.frame)
        if let data = try? JSONEncoder().encode(frames) {
            defaults.set(data, forKey: AttachePreferenceKey.miniAttacheFrames)
        }
    }

    private func storedFrames() -> [String: String] {
        guard let data = defaults.data(forKey: AttachePreferenceKey.miniAttacheFrames),
              let frames = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return frames
    }
}

/// The mini window's content: the active renderer over nothing, plus the
/// right-click menu that keeps every control reachable without the main
/// window. When click-through is enabled the window stops receiving events
/// entirely; the menu bar's Mini Window section remains the way back.
struct MiniAttacheView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var playback: SpeechPlaybackController

    init(model: AppModel) {
        self.model = model
        self.playback = model.playback
    }

    var body: some View {
        EchoformRendererView(
            playback: playback,
            timeline: playback.clock,
            activity: model.attacheActivity,
            activityMoment: model.attacheMoment,
            visualMode: model.visualMode,
            visualSymmetry: .mirrored,
            idleBrand: .none,
            theme: model.theme,
            brightnessLevel: 1,
            intensity: 1.0,
            transparentBackground: true,
            characterDelights: CharacterDelights(
                typesAlong: true,
                rareIdles: true,
                hoverReacts: true
            ),
            characterShiny: model.characterShiny,
            onFleetFocus: { [weak model] id in
                model?.focusCodexSession(id)
            },
            onFleetSwitch: {
                NotificationCenter.default.post(name: .attacheShowMainWindow, object: nil)
                NotificationCenter.default.post(name: .attacheOpenPalette, object: nil)
            },
            characterFocusAngle: model.characterFocusAngle,
            onCharacterFocusAngleChanged: { [weak model] angle in
                model?.characterFocusAngle = angle
            },
            character: model.character,
            fleetNotificationsOnly: true,
            isPrivate: model.isPrivateConversation
        )
        .overlay(alignment: .top) {
            if model.isPrivateConversation {
                miniPrivateChip
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Replay Last Update") { model.replayLastUpdate() }
            Button("Open Attaché") {
                NotificationCenter.default.post(name: .attacheShowMainWindow, object: nil)
            }
            Button(model.voicemailMode ? "Go Live (narrate updates aloud)" : "Go Quiet (send updates to Inbox)") {
                model.toggleVoicemailMode()
            }
            Menu("Size") {
                Button("Small") { model.miniAttacheResize.send(NSSize(width: 210, height: 225)) }
                Button("Medium") { model.miniAttacheResize.send(MiniAttacheWindowController.defaultSize) }
                Button("Large") { model.miniAttacheResize.send(NSSize(width: 370, height: 396)) }
                Button("Huge") { model.miniAttacheResize.send(NSSize(width: 460, height: 493)) }
            }
            Button("Reply in Attaché…") {
                NotificationCenter.default.post(name: .attacheShowMainWindow, object: nil)
            }
            Button("Enable Click-Through") { model.miniAttacheClickThrough = true }
            Divider()
            Button("Hide Mini Window") { model.miniAttacheEnabled = false }
            Button("Quit Attaché") { NSApp.terminate(nil) }
        }
        .accessibilityLabel("Mini window")
    }

    // The mini window's PRIVATE chip (INF-356): the main window's HUD is not
    // present here, so the mini window needs its own persistent indicator
    // while storage mode is .privateCall. Same copy and tooltip rule as the
    // call HUD's chip (`PrivateModeIndicator.chipTooltip`).
    private var miniPrivateChip: some View {
        Text("PRIVATE")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.72), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.35)))
            .padding(.top, 6)
            .help(PrivateModeIndicator.chipTooltip(modelIsLocal: !model.presentationSendsToCloud))
            .accessibilityLabel("PRIVATE")
            .accessibilityValue(PrivateModeIndicator.chipTooltip(modelIsLocal: !model.presentationSendsToCloud))
            .allowsHitTesting(false)
    }
}

extension Notification.Name {
    static let attacheShowMainWindow = Notification.Name("attacheShowMainWindow")
}
