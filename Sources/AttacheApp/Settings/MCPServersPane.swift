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
    /// Per-harness collapsed state for the detected section, remembered for the
    /// life of the pane (session), mirroring SessionSwitcher's group headers.
    @State private var collapsedHarnesses: Set<MCPHarness> = []
    /// The whole detected section starts collapsed so a user who has already
    /// imported what they want is not confronted with every server their other
    /// tools configure; expanding it is a deliberate act.
    @State private var detectedSectionExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MCP Servers").typoTitle()
            Text("Connect MCP servers so your Attaché can look up information during a live call. Servers are shared; each Attaché grants individual tools under Personalities.")
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

            detectedSection
        }
        .onAppear { registry.refreshDetection() }
        .sheet(isPresented: $addSheetPresented) {
            MCPAddServerSheet { name, snippet in
                addServer(name: name, snippet: snippet)
            }
        }
    }

    // MARK: Detected servers

    /// The deduped + per-harness structure the section renders. Cross-harness
    /// duplicates are lifted into `shared`; the registry has already filtered out
    /// anything matching a configured server.
    private var detectedGrouping: MCPDetectedGrouping {
        MCPHarnessImport.group(registry.detectedServers)
    }

    @ViewBuilder private var detectedSection: some View {
        if !registry.detectedServers.isEmpty {
            let grouping = detectedGrouping
            let count = registry.detectedServers.count
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button {
                        withAnimation(.easeOut(duration: 0.14)) {
                            detectedSectionExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right")
                                .typoIcon(size: 8, .bold)
                                .rotationEffect(.degrees(detectedSectionExpanded ? 90 : 0))
                            Text(detectedSectionExpanded
                                 ? "Detected in your other tools"
                                 : "Detected in your other tools · \(count) server\(count == 1 ? "" : "s")")
                                .typoSection()
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("MCP Detected Toggle")
                    .accessibilityLabel(detectedSectionExpanded
                        ? "Collapse servers detected in your other tools"
                        : "Expand servers detected in your other tools, \(count) available")
                    Spacer()
                    if detectedSectionExpanded {
                        Button("Refresh") { registry.refreshDetection() }
                            .accessibilityIdentifier("MCP Refresh Detected")
                            .disabled(registry.isDetecting)
                    }
                }
                if detectedSectionExpanded {
                    Text("Servers found in your other agent tools. Importing copies the server into Attaché's own mcp.json; nothing in the other tool is changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !grouping.shared.isEmpty {
                        sharedGroupView(grouping.shared)
                    }
                    ForEach(grouping.harnessGroups) { group in
                        detectedHarnessGroupView(group)
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    /// Cross-harness duplicates: one row per identity, with origin badges and a
    /// single Import for the canonical entry. Rendered above the per-harness
    /// groups so a server offered by several tools appears exactly once.
    private func sharedGroupView(_ shared: [MCPDedupedDetectedServer]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("In multiple tools").typoBody(.medium)
                Spacer()
            }
            ForEach(shared) { deduped in
                dedupedRow(deduped)
            }
        }
    }

    private func detectedHarnessGroupView(_ group: MCPDetectedHarnessGroup) -> some View {
        let harness = group.harness
        let collapsed = collapsedHarnesses.contains(harness)
        let importable = group.servers.filter { $0.importability.isImportable }
        let count = group.servers.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.14)) {
                        if collapsed { collapsedHarnesses.remove(harness) }
                        else { collapsedHarnesses.insert(harness) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .typoIcon(size: 8, .bold)
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                        Text(collapsed
                             ? "\(harness.displayName) · \(count) server\(count == 1 ? "" : "s")"
                             : harness.displayName)
                            .typoBody(.medium)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("MCP Harness Toggle \(harness.displayName)")
                if !importable.isEmpty {
                    Button("Import All") { importDetected(importable) }
                        .accessibilityIdentifier("MCP Import All \(harness.displayName)")
                }
            }
            if !collapsed {
                ForEach(group.servers) { server in
                    detectedRow(server)
                }
            }
        }
    }

    private func dedupedRow(_ deduped: MCPDedupedDetectedServer) -> some View {
        let server = deduped.canonical
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.name).typoBody(.medium)
                    Text(server.transportSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        ForEach(deduped.origins, id: \.self) { origin in
                            originBadge(origin.displayName)
                        }
                    }
                }
                Spacer()
                Button("Import") { importDetected([server]) }
                    .disabled(!deduped.isImportable)
                    .accessibilityIdentifier("MCP Detected Import \(server.name)")
            }
            if let reason = server.importability.reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }

    private func originBadge(_ label: String) -> some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.08), in: Capsule())
    }

    private func detectedRow(_ server: MCPDetectedServer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).typoBody(.medium)
                    Text(server.transportSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(server.originPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Import") { importDetected([server]) }
                    .disabled(!server.importability.isImportable)
                    .accessibilityIdentifier("MCP Detected Import \(server.name)")
            }
            if let reason = server.importability.reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text("An aggregator gateway like metaMCP is the recommended way to carry authorized services into Attaché.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
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
                if server.isValid && server.isEnabled {
                    Button("Test") {
                        Task { await registry.testServer(name: server.name) }
                    }
                    .disabled(status == .connecting)
                    .accessibilityIdentifier("MCP Test \(server.name)")
                }
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

    private func importDetected(_ servers: [MCPDetectedServer]) {
        guard !servers.isEmpty else { return }
        do {
            try registry.importDetected(servers)
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
