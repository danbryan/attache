import AppKit
import Combine
import AttacheCore
import SwiftUI

final class AttacheWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private var cancellables: Set<AnyCancellable> = []

    /// The window's floor. Deliberately a fixed constant with no line-count (or
    /// any other content) input: the caption line-count choice is a preference
    /// ceiling, not a reserve, so the user can always drag the window this small
    /// whether they picked one caption line or the maximum. Lowered from the
    /// original 760x500 so the window can be tucked out of the way; the main
    /// layout (bottom-docked overlays, centered visualizer) still reads at this
    /// size, and the separate MiniAttache panel keeps its own smaller floor.
    static let minimumWindowSize = NSSize(width: 640, height: 460)

    init(model: AppModel) {
        self.model = model
        let rootView = AttacheRootView(model: model)
        let hostingView = NSHostingView(rootView: rootView)
        // Do NOT let SwiftUI content drive the window's minimum/maximum size.
        // NSHostingView otherwise propagates the content's intrinsic minimum up
        // to the window's contentMinSize, which grows with the caption line
        // count and pins the window so it cannot be dragged narrower or shorter
        // (BUG 1). With sizing decoupled, `minSize` below is the only floor.
        hostingView.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AttacheAppSupport.appDisplayName
        window.contentView = hostingView
        window.isOpaque = model.surfaceOpacity >= 0.995
        window.backgroundColor = Self.backgroundColor(for: model.surfaceOpacity)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = Self.minimumWindowSize
        super.init(window: window)
        window.delegate = self
        bindWindowAppearance()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func showAttache() {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        AppActivation.bringToForeground()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func bindWindowAppearance() {
        model.$surfaceOpacity
            .receive(on: RunLoop.main)
            .sink { [weak self] opacity in
                self?.window?.backgroundColor = Self.backgroundColor(for: opacity)
                self?.window?.isOpaque = opacity >= 0.995
            }
            .store(in: &cancellables)
    }

    private static func backgroundColor(for surfaceOpacity: Double) -> NSColor {
        // Adapts to light/dark so a translucent window tints with the system
        // surface instead of always darkening toward black.
        NSColor.windowBackgroundColor.withAlphaComponent(min(1.0, max(0.35, surfaceOpacity)))
    }
}
