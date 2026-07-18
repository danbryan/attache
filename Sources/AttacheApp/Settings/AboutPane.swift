import AttacheCore
import SwiftUI

/// Version and build number, so a bug report or support request always has
/// something exact to point at (`CFBundleShortVersionString` /
/// `CFBundleVersion` via `AttacheAppSupport`, unused anywhere in the UI
/// before this).
struct AboutPane: View {
    @ObservedObject var model: AppModel
    @State private var stallEvents: [StallEvent] = []
    @State private var licensesText: String?
    @State private var showLicenses = false

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
            voicesCreditsSection
            Divider().padding(.vertical, 2)
            responsivenessSection
        }
        .onAppear { refreshStallEvents() }
    }

    /// Voice and speech acknowledgements (INF-384). The engine lines are fixed
    /// facts; the Azelma line is generated from the Core license manifest so it
    /// stays in lockstep with the bundled THIRD-PARTY-LICENSES.
    private var voicesCreditsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Voices & speech").typoSection()
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(PremiumVoiceCredits.engineCredit)
                        .font(.caption)
                    Text(PremiumVoiceCredits.engineSubcredit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let azelma = PremiumVoiceLicenseManifest.shipped.entry(id: "azelma") {
                    Text(azelmaCredit(azelma))
                        .font(.caption)
                        .tint(.accentColor)
                }
                Text(PremiumVoiceCredits.updatesCredit)
                    .font(.caption)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("About Voices Credits")
            .accessibilityIdentifier("About Voices Credits")

            Button(showLicenses ? "Hide Third-Party Licenses" : "Third-Party Licenses") {
                if licensesText == nil {
                    licensesText = Self.loadThirdPartyLicenses()
                }
                showLicenses.toggle()
            }
            .accessibilityIdentifier("About Third Party Licenses")
            .accessibilityLabel("Third-Party Licenses")

            if showLicenses {
                ScrollView {
                    Text(licensesText ?? "Third-party license text is unavailable in this build.")
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(8)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// SwiftUI Text with the license name rendered as a tappable link, derived
    /// from the Core formatter's Markdown. Falls back to plain text if the
    /// Markdown does not parse.
    private func azelmaCredit(_ entry: PremiumVoiceLicenseManifest.Entry) -> AttributedString {
        let markdown = PremiumVoiceCredits.voiceCreditMarkdown(entry)
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(PremiumVoiceCredits.voiceCreditPlain(entry))
    }

    /// Load the bundled THIRD-PARTY-LICENSES via Bundle.main (never
    /// Bundle.module, per AGENTS.md gotcha). Returns nil if it is absent so the
    /// UI shows a graceful fallback rather than crashing.
    private static func loadThirdPartyLicenses() -> String? {
        if let url = Bundle.main.url(forResource: "THIRD-PARTY-LICENSES", withExtension: nil),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
            let url = base.appendingPathComponent("THIRD-PARTY-LICENSES")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
        }
        return nil
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
