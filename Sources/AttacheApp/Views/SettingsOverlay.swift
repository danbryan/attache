import AttacheCore
import SwiftUI

/// The in-window Settings surface (INF-377): a Discord-style full-surface
/// overlay hosted inside the single main Attaché window, replacing the old
/// separate Settings window. A left sidebar lists the same sections; the right
/// side scrolls the selected section's pane. Panes are reused verbatim through
/// `SettingsPaneView` so behavior and AX labels are preserved.
struct SettingsOverlay: View {
    @ObservedObject var model: AppModel
    @Environment(\.themeAccent) private var accent

    /// Section selection is model-backed so section deep-links (dock context
    /// menu, "Edit Attaché model…", "Change idle screen…") land on the right
    /// pane whether or not the overlay was already open.
    private var section: SettingsSection { model.activeSettingsSection }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(maxWidth: 940, maxHeight: 660)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .readingPlate(theme: model.theme, cornerRadius: 16, minimumOpacity: 0.72)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        .padding(24)
        .attacheTextScale(model.uiTextScale)
        .onChange(of: model.integrationFocusProviderID) { providerID in
            if providerID != nil { model.activeSettingsSection = .integrations }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("Settings Overlay")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .typoTitle()
                Spacer()
                Button {
                    model.hideSettingsOverlay()
                } label: {
                    Image(systemName: "xmark")
                        .typoIcon(size: 12, .semibold)
                        .frame(width: 26, height: 26)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(Color.primary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Close settings")
                .accessibilityLabel("Close Settings")
                .accessibilityIdentifier("Close Settings")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsSection.allCases) { item in
                        sidebarRow(item)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 208)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sidebarRow(_ item: SettingsSection) -> some View {
        let selected = item == section
        return Button {
            AttacheLog.uiLatency.withIntervalSignpost("settingsPaneSwitch") {
                model.activeSettingsSection = item
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .frame(width: 18)
                    .foregroundStyle(selected ? accent : Color.primary.opacity(0.7))
                Text(LocalizedStringKey(item.title))
                    .typoBody(selected ? .semibold : .regular)
                    .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.82))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? accent.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(item.title)))
        .accessibilityIdentifier("Settings section \(item.title)")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private var detail: some View {
        ScrollView {
            SettingsPaneView(model: model, section: section)
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
