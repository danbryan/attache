import AppKit
import AttacheCore
import SwiftUI

/// Settings pane over the app-wide `mcp.json` (INF-373). It surfaces each
/// configured server's live connection status and validation errors, and can
/// add, enable/disable, reload, and open the file. Tool capability is not set
/// here: servers are shared, and each personality grants individual tools in
/// its editor.
struct MCPServersPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var registry: MCPServerRegistry
    @State private var addSheetPresented = false
    @State private var writeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MCP Servers").typoTitle()
            Text("Connect MCP servers so a character can look up information during a live call. Servers are shared; each character grants individual tools under Personalities.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            buttonsRow

            if let writeError {
                Text(writeError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if registry.configuredServers.isEmpty {
                emptyState
            } else {
                VStack(spacing: 6) {
                    ForEach(registry.configuredServers, id: \.name) { server in
                        row(server)
                    }
                }
            }
        }
        .sheet(isPresented: $addSheetPresented) {
            MCPAddServerSheet { name, snippet in
                addServer(name: name, snippet: snippet)
            }
        }
    }

    private var buttonsRow: some View {
        HStack(spacing: 10) {
            Button("Add Server…") { addSheetPresented = true }
                .accessibilityIdentifier("Add Server…")
            Button("Open mcp.json") { openConfigFile() }
                .accessibilityIdentifier("Open mcp.json")
            Button("Reload") {
                writeError = nil
                registry.reload()
            }
            .accessibilityIdentifier("Reload MCP Servers")
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No MCP servers configured.")
                .typoBody(.medium)
            Text("Add one by pasting a standard mcp.json snippet, or open the file to edit it directly.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }

    private func row(_ server: MCPServerConfig) -> some View {
        let status = registry.statuses[server.name] ?? (server.isEnabled ? .idle : .disabled)
        let validationError = registry.validationErrors[server.name]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                statusDot(status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).typoBody(.medium)
                    Text(statusText(status))
                        .font(.caption)
                        .foregroundStyle(statusColor(status))
                        .lineLimit(2)
                }
                Spacer()
                if server.isValid {
                    Toggle("", isOn: enabledBinding(server))
                        .labelsHidden()
                        .accessibilityLabel("Enable \(server.name)")
                }
            }
            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private func statusDot(_ status: MCPServerStatus) -> some View {
        switch status {
        case .connecting:
            ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
        default:
            Circle().fill(statusColor(status)).frame(width: 9, height: 9)
        }
    }

    private func statusText(_ status: MCPServerStatus) -> String {
        switch status {
        case .disabled: return "Disabled"
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected(let toolCount):
            return "Connected, \(toolCount) tool\(toolCount == 1 ? "" : "s")"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }

    private func statusColor(_ status: MCPServerStatus) -> Color {
        switch status {
        case .disabled: return .secondary
        case .idle: return .secondary
        case .connecting: return .secondary
        case .connected: return .green
        case .failed: return .red
        }
    }

    private func enabledBinding(_ server: MCPServerConfig) -> Binding<Bool> {
        Binding(
            get: { server.isEnabled },
            set: { newValue in setEnabled(newValue, for: server.name) }
        )
    }

    // MARK: File edits

    private func openConfigFile() {
        writeError = nil
        let url = registry.ensureConfigFileExists()
        NSWorkspace.shared.open(url)
    }

    private func addServer(name: String, snippet: String) {
        do {
            let merged = try MCPConfigEditor.merge(
                snippet: snippet, name: name, into: registry.currentConfigData()
            )
            try registry.writeConfigData(merged)
            writeError = nil
            addSheetPresented = false
        } catch {
            writeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func setEnabled(_ enabled: Bool, for name: String) {
        do {
            let updated = try MCPConfigEditor.setEnabled(
                enabled, forServer: name, in: registry.currentConfigData()
            )
            try registry.writeConfigData(updated)
            writeError = nil
        } catch {
            writeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Small sheet for pasting a standard mcp.json server snippet. Accepts either a
/// bare inner server object (keyed under the entered name) or a full
/// `{"mcpServers": {...}}` fragment.
struct MCPAddServerSheet: View {
    let onAdd: (_ name: String, _ snippet: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var snippet = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add MCP Server").typoSection()
            Text("Paste a standard mcp.json server entry. Use a full \u{7B}\"mcpServers\": …\u{7D} fragment, or a single server object with a name below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("Name").font(.caption).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                TextField("my-server", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("MCP Server Name")
            }

            Text("Server JSON")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $snippet)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
                .accessibilityLabel("Server JSON")
                .accessibilityIdentifier("MCP Server JSON")

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { onAdd(name, snippet) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("MCP Add Server Confirm")
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
