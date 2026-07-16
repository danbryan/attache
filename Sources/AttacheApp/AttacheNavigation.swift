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

    static func openPersonalityManager() {
        openSettings(.personalities)
    }

    static func openActivitySimulator() {
        NotificationCenter.default.post(name: .attacheOpenActivitySimulator, object: nil)
    }
}
