import AttacheCore
import SwiftUI

/// Version and build number, so a bug report or support request always has
/// something exact to point at (`CFBundleShortVersionString` /
/// `CFBundleVersion` via `AttacheAppSupport`, unused anywhere in the UI
/// before this).
struct AboutPane: View {
    @ObservedObject var model: AppModel
    @State private var stallEvents: [StallEvent] = []

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
            Divider().padding(.vertical, 2)
            responsivenessSection
        }
        .onAppear { refreshStallEvents() }
    }

    /// Main-thread stall counts by duration bucket and by context (INF-349).
    /// Measurement only, content-free: context labels are pane/state names
    /// like "settings.about" or "call.live", never user text.
    private var responsivenessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Responsiveness").typoSection()
                Spacer()
                Button("Refresh") { refreshStallEvents() }
                    .accessibilityLabel("Refresh responsiveness report")
            }
            if stallEvents.isEmpty {
                Text("No stalls over 250ms recorded this launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                settingRow("By duration") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(StallDurationBucket.allCases, id: \.self) { bucket in
                            let count = stallEvents.filter { $0.bucket == bucket }.count
                            if count > 0 {
                                Text("\(bucket.rawValue): \(count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                settingRow("By context") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(contextCounts, id: \.context) { entry in
                            Text("\(entry.context.isEmpty ? "unknown" : entry.context): \(entry.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("A stall is over 250ms for the main thread to respond to a background probe. Last \(MainThreadWatchdog.maxStoredEvents) events kept in memory this launch; nothing is written to disk.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Responsiveness")
    }

    private var contextCounts: [(context: String, count: Int)] {
        Dictionary(grouping: stallEvents, by: { $0.context })
            .map { (context: $0.key, count: $0.value.count) }
            .sorted { $0.context < $1.context }
    }

    private func refreshStallEvents() {
        stallEvents = model.mainThreadWatchdog.report()
    }
}
