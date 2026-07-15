import AttacheCore
import SwiftUI

/// Version and build number, so a bug report or support request always has
/// something exact to point at (`CFBundleShortVersionString` /
/// `CFBundleVersion` via `AttacheAppSupport`, unused anywhere in the UI
/// before this).
struct AboutPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About").typoTitle()
            settingRow("Version") {
                Text(AttacheAppSupport.appVersion)
                    .foregroundStyle(.secondary)
            }
            settingRow("Build") {
                Text(AttacheAppSupport.buildVersion)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Divider().padding(.vertical, 2)
            settingRow("Welcome") {
                Button("Run welcome again") {
                    NotificationCenter.default.post(name: .attacheShowOnboarding, object: nil)
                }
                .accessibilityLabel("Run welcome again")
                Text("Review integrations, voice, and character setup from the beginning.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
