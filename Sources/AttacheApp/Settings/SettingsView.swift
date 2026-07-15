import AttacheCore
import SwiftUI

/// Sections of the dedicated Settings window. Each becomes a sidebar item.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case appearance
    case voice
    case personalities
    case integrations
    case memory
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .voice: return "Voice & Captions"
        case .personalities: return "Personalities"
        case .integrations: return "Integrations"
        case .memory: return "Memory"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: return "circle.lefthalf.filled"
        case .voice: return "speaker.wave.2.fill"
        case .personalities: return "theatermasks.fill"
        case .integrations: return "puzzlepiece.extension.fill"
        case .memory: return "tray.full.fill"
        case .about: return "info.circle.fill"
        }
    }
}

/// The dedicated Settings window content: a sidebar and the selected section's
/// pane. Each pane surfaces its own "what's active" state where it isn't already
/// obvious, rather than a redundant global status bar.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var section: SettingsSection? = .appearance

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(SettingsSection.allCases) { item in
                    Label { Text(LocalizedStringKey(item.title)) } icon: { Image(systemName: item.symbol) }
                        .accessibilityLabel(Text(LocalizedStringKey(item.title)))
                        .tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 184, ideal: 200, max: 240)
        } detail: {
            ScrollView {
                pane
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 740, minHeight: 480)
        .attacheTextScale(model.uiTextScale)
        .onChange(of: model.integrationFocusProviderID) { providerID in
            if providerID != nil {
                section = .integrations
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .attacheOpenSettingsSection)) { note in
            if let raw = note.object as? String, let target = SettingsSection(rawValue: raw) {
                section = target
            }
        }
    }

    @ViewBuilder private var pane: some View {
        switch section ?? .appearance {
        case .appearance: appearancePane
        case .voice: VoicePane(model: model)
        case .personalities: PersonalitiesPane(model: model)
        case .integrations: IntegrationsPane(model: model)
        case .memory: memoryPane
        case .about: AboutPane()
        }
    }

    private var appearancePane: some View {
        VStack(alignment: .leading, spacing: 16) {
            paneTitle("Appearance")
            settingRow("Light & dark") {
                Picker("", selection: $model.appearanceMode) {
                    ForEach(AttacheAppearanceMode.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                }
                .labelsHidden()
                .accessibilityLabel("Light and dark appearance")
                .frame(width: 210)
            }
            settingRow("Theme") {
                Picker("", selection: themeSelection) {
                    ForEach(AttacheTheme.allCases.filter { $0 != .custom }) {
                        Text(LocalizedStringKey($0.title)).tag($0.rawValue)
                    }
                    if !model.customThemes.isEmpty {
                        Divider()
                        ForEach(model.customThemes) { spec in
                            Text(spec.name).tag("custom:\(spec.id)")
                        }
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Theme")
                .frame(width: 210)
            }
            CustomThemeEditor(model: model)
            Text("Characters choose their own presence, voice, model, and playback pace under Personalities.")
                .font(.caption)
                .foregroundStyle(.secondary)
            settingRow("Mini window") {
                Toggle("", isOn: $model.miniAttacheEnabled).labelsHidden()
                    .accessibilityLabel("Mini window")
                Text("A small always-on-top window with the active character or Echo bars.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.miniAttacheEnabled {
                settingRow("Click-through") {
                    Toggle("", isOn: $model.miniAttacheClickThrough).labelsHidden()
                        .accessibilityLabel("Mini window click-through")
                    Text("Clicks pass through the mini window; use the menu bar to reach its controls.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            settingRow("Text size") {
                Slider(value: $model.uiTextScale,
                       in: AttacheTypeScale.minimumScale...AttacheTypeScale.maximumScale,
                       step: 0.05)
                    .frame(width: 240)
                    .accessibilityLabel("Text size")
                Text("\(Int((model.uiTextScale * 100).rounded()))%")
                    .typoCaption(.medium, monoDigit: true)
                    .foregroundStyle(.secondary)
            }
            settingRow("Surface opacity") {
                Slider(value: $model.surfaceOpacity, in: 0.35...1.0).frame(width: 240)
                Text("\(Int((model.surfaceOpacity * 100).rounded()))%")
                    .typoCaption(.medium, monoDigit: true)
                    .foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 2)
            settingRow("Auto-hide controls") {
                Toggle("", isOn: $model.autoHideControls).labelsHidden()
                Text("Fade the chrome to the bare glow when the pointer is still.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.autoHideControls {
                settingRow("Hide after") {
                    Slider(value: $model.autoHideDelaySeconds, in: 1...6, step: 0.5).frame(width: 200)
                    Text(String(format: "%.1fs", model.autoHideDelaySeconds))
                        .typoCaption(.medium, monoDigit: true)
                        .foregroundStyle(.secondary)
                }
            }
            settingRow("Occasional tips") {
                Toggle("", isOn: $model.showTips).labelsHidden()
                Text("One short pointer per launch about features you haven't used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            settingRow("Menu bar") {
                Toggle("", isOn: $model.showInMenuBar).labelsHidden()
                Text("Show Attaché in the menu bar with fleet status and quick actions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            settingRow("Personality switcher") {
                Toggle("", isOn: $model.showPersonalitySwitcher).labelsHidden()
                Text("Show the personality switcher in the main controls.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.showPersonalitySwitcher {
                settingRow("Personality name") {
                    Toggle("", isOn: $model.showPersonalityNameInDock).labelsHidden()
                    Text("Show the active personality's name next to the icon.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            settingRow("Activity insights") {
                Toggle("", isOn: $model.showActivityInsights).labelsHidden()
                Text("Show ambient phrases from watched-session tools and results.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            settingRow("Notifications") {
                Picker("", selection: $model.notifyScope) {
                    ForEach(AttacheNotifyScope.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Notifications")
                .frame(width: 280)
                Button("System settings…") { AttacheNotifier.shared.openSystemNotificationSettings() }
                Text("Delivery follows macOS Focus profiles and Do Not Disturb.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var memoryPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            paneTitle("Memory")
            Text("Durable tone, routing, and preference notes Attaché uses quietly. Kept separate from your personalities.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open Memory File") { model.openAttacheMemoryFile() }
        }
    }

    private func paneTitle(_ title: String) -> some View {
        Text(LocalizedStringKey(title)).typoTitle()
    }

    /// One selection string for the theme popup: built-in rawValues plus
    /// "custom:<id>" entries for user themes.
    private var themeSelection: Binding<String> {
        Binding(
            get: {
                if model.theme == .custom, let id = model.activeCustomThemeID {
                    return "custom:\(id)"
                }
                return model.theme.rawValue
            },
            set: { newValue in
                if newValue.hasPrefix("custom:") {
                    model.selectCustomTheme(String(newValue.dropFirst("custom:".count)))
                } else if let builtin = AttacheTheme(rawValue: newValue) {
                    model.theme = builtin
                }
            }
        )
    }
}
