import Foundation

/// Small, shared navigation actions for controls that live outside Settings.
/// Settings is a separate AppKit window, so the section selection is posted on
/// the following main-loop turn after the window has had a chance to appear.
@MainActor
enum AttacheNavigation {
    static func openSettings(_ section: SettingsSection) {
        NotificationCenter.default.post(name: .attacheOpenSettings, object: nil)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .attacheOpenSettingsSection,
                object: section.rawValue
            )
        }
    }

    /// Named to match the dock's right-click "jump straight to a pane" menus
    /// (INF-354); forwards to `openSettings(_:)`.
    static func openSettings(pane: SettingsSection) {
        openSettings(pane)
    }

    static func openPersonalityManager() {
        openSettings(.personalities)
    }

    static func openActivitySimulator() {
        NotificationCenter.default.post(name: .attacheOpenActivitySimulator, object: nil)
    }
}
