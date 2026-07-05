import AppKit
import AttacheCore
import SwiftUI

/// Escape closes the window, matching how the palette overlays dismiss.
private final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}

/// Hosts the dedicated Settings window (opened with Cmd-comma). Separate from the
/// live companion window so Attaché surface is never disturbed.
final class SettingsWindowController: NSWindowController {
    init(model: AppModel) {
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let window = SettingsWindow(contentViewController: hosting)
        window.title = "\(CompanionAppSupport.appDisplayName) Settings"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 840, height: 580))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AttacheSettingsWindow")
        if !window.setFrameUsingName("AttacheSettingsWindow") {
            window.center()
        }
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        guard let window else { return }
        // Placement persists via the frame autosave name; no re-centering.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
