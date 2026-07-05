import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The in-app theme editor: create a theme from the current one, adjust its
/// gradient stops and accents with the native color picker, import a shared
/// spec, or export the active one. Everything applies live to the window;
/// accents are clamped to the contrast floor as you pick.
struct CustomThemeEditor: View {
    @ObservedObject var model: AppModel
    @State private var importPresented = false
    @State private var importError: String?

    private var activeSpec: CompanionThemeSpec? {
        guard model.theme == .custom, let id = model.activeCustomThemeID else { return nil }
        return model.customThemes.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("New custom theme") { model.createCustomTheme() }
                Button("Import theme…") { importPresented = true }
                if let spec = activeSpec {
                    Button("Export…") { exportSpec(spec) }
                    Button(role: .destructive) {
                        model.deleteCustomTheme(spec.id)
                    } label: {
                        Text("Delete")
                    }
                }
            }
            .typoCaption(.semibold)

            if let error = importError {
                Text(error).typoCaption().foregroundStyle(.red)
            }

            if let spec = activeSpec {
                editor(for: spec)
            } else {
                Text("Custom themes start from the current theme's colors. Share one as a JSON file; imports are contrast-checked automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        .fileImporter(isPresented: $importPresented, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    _ = try model.importCustomTheme(from: url)
                    importError = nil
                } catch {
                    importError = "Could not read that theme file."
                }
            case .failure:
                break
            }
        }
    }

    private func editor(for spec: CompanionThemeSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Name").typoCaption(.medium).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                TextField("Theme name", text: Binding(
                    get: { spec.name },
                    set: { newValue in
                        var updated = spec
                        updated.name = newValue
                        model.applyCustomThemeEdit(updated)
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }
            colorRow("Glow low", value: spec.stops.indices.contains(0) ? spec.stops[0] : nil) { stop in
                var updated = spec
                if updated.stops.indices.contains(0) { updated.stops[0] = stop }
                model.applyCustomThemeEdit(updated)
            }
            colorRow("Glow mid", value: spec.stops.indices.contains(1) ? spec.stops[1] : nil) { stop in
                var updated = spec
                if updated.stops.indices.contains(1) { updated.stops[1] = stop }
                model.applyCustomThemeEdit(updated)
            }
            colorRow("Glow high", value: spec.stops.indices.contains(2) ? spec.stops[2] : nil) { stop in
                var updated = spec
                if updated.stops.indices.contains(2) { updated.stops[2] = stop }
                model.applyCustomThemeEdit(updated)
            }
            colorRow("Accent (dark)", value: spec.accentDark) { stop in
                var updated = spec
                updated.accentDark = stop
                model.applyCustomThemeEdit(updated)
            }
            colorRow("Accent (light)", value: spec.accentLight) { stop in
                var updated = spec
                updated.accentLight = stop
                model.applyCustomThemeEdit(updated)
            }
            HStack(spacing: 8) {
                Text("Solid plates").typoCaption(.medium).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                Toggle("", isOn: Binding(
                    get: { spec.wantsSolidPlates },
                    set: { newValue in
                        var updated = spec
                        updated.wantsSolidPlates = newValue
                        model.applyCustomThemeEdit(updated)
                    }
                ))
                .labelsHidden()
                Text("Keep text plates fully opaque regardless of surface opacity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Accents are nudged automatically if a pick falls below the 4.5:1 contrast floor.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func colorRow(_ label: String, value: CompanionThemeStop?, onChange: @escaping (CompanionThemeStop) -> Void) -> some View {
        if let value {
            HStack(spacing: 8) {
                Text(label).typoCaption(.medium).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                ColorPicker("", selection: Binding(
                    get: { Color(red: value.red, green: value.green, blue: value.blue) },
                    set: { color in
                        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
                        onChange(CompanionThemeStop(red: Double(ns.redComponent),
                                                    green: Double(ns.greenComponent),
                                                    blue: Double(ns.blueComponent)))
                    }
                ), supportsOpacity: false)
                .labelsHidden()
                .accessibilityLabel(label)
            }
        }
    }

    private func exportSpec(_ spec: CompanionThemeSpec) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(spec.name.replacingOccurrences(of: "/", with: "-")).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? model.exportCustomTheme(spec.id, to: url)
        }
    }
}
