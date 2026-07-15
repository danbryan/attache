import AppKit
import SwiftUI

private final class PersonalityStudioWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}

/// Hosts character creation as a real macOS window. The studio can be moved
/// away from onboarding or Settings, resized, minimized, and closed from its
/// title bar like the substantial editor it is.
final class PersonalityStudioWindowController: NSWindowController {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        let window = PersonalityStudioWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_160, height: 740),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Character Studio"
        window.minSize = NSSize(width: 1_100, height: 680)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AttachePersonalityStudioWindow")
        if !window.setFrameUsingName("AttachePersonalityStudioWindow") {
            window.center()
        }
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ request: PersonalityStudioRequest) {
        guard let window else { return }
        window.contentViewController = NSHostingController(
            rootView: PersonalityStudioSheet(
                model: model,
                request: request,
                onClose: { [weak self] in self?.close() }
            )
        )
        window.title = request.mode == .edit ? "Edit Character" : "Create Character"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
