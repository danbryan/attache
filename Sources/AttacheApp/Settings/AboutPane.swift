import AttacheCore
import SwiftUI

/// Version and build number, so a bug report or support request always has
/// something exact to point at (`CFBundleShortVersionString` /
/// `CFBundleVersion` via `CompanionAppSupport`, unused anywhere in the UI
/// before this).
struct AboutPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About").typoTitle()
            settingRow("Version") {
                Text(CompanionAppSupport.appVersion)
                    .foregroundStyle(.secondary)
            }
            settingRow("Build") {
                Text(CompanionAppSupport.buildVersion)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}
