import AppKit
import Combine
import AttacheCore
import SwiftUI

final class AttacheWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        let rootView = AttacheRootView(model: model)
        let hostingView = NSHostingView(rootView: rootView)
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
        window.minSize = NSSize(width: 760, height: 500)
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
        NSApp.activate(ignoringOtherApps: true)
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
