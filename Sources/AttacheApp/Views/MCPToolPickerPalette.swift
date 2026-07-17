import AppKit
import AttacheCore
import SwiftUI

/// Per-personality MCP tool picker (INF-373). Shares the command-palette
/// contract: search is focused on open (Space types into it like any palette),
/// arrows move the selection, Return closes confirming, and Escape closes.
/// Clicking a row's permission chip cycles that tool's permission.
/// Tools are grouped by server under collapsible headers; opening the picker
/// connects idle servers lazily so their tools appear.
struct MCPToolPickerPalette: View {
    @ObservedObject var model: AppModel
    @ObservedObject var registry: MCPServerRegistry
    @Binding var grants: MCPToolGrants
    @Binding var isVisible: Bool
    @Environment(\.attacheTextScale) private var textScale
    @State private var query = ""
    @State private var selectedID: String?
    @State private var collapsedServers: Set<String> = []
    @FocusState private var fieldFocused: Bool

    private struct ServerGroup: Identifiable {
        let id: String          // server name
        let status: MCPServerStatus
        let tools: [MCPToolDescriptor]

        var isFailed: Bool {
            if case .failed = status { return true }
            return false
        }
    }

    /// Valid, enabled servers with their (filtered) tools, in configured order.
    private var groups: [ServerGroup] {
        let all = registry.availableTools()
        let terms = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return registry.configuredServers
            .filter { $0.isValid && $0.isEnabled }
            .map { server in
                let tools = all
                    .filter { $0.serverName == server.name }
                    .filter { descriptor in
                        guard !terms.isEmpty else { return true }
                        let haystack = [server.name, descriptor.toolName, descriptor.description]
                            .joined(separator: " ")
                        return terms.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
                    }
                    .sorted { $0.toolName < $1.toolName }
                return ServerGroup(
                    id: server.name,
                    status: registry.statuses[server.name] ?? .idle,
                    tools: tools
                )
            }
    }

    /// Visible tool rows in order, skipping collapsed groups. Keyboard nav walks
    /// this list.
    private var flatTools: [MCPToolDescriptor] {
        groups.flatMap { collapsedServers.contains($0.id) ? [] : $0.tools }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolList
            Divider()
            footer
        }
        .frame(width: 640 * textScale)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .readingPlate(theme: model.theme)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 28, y: 12)
        .background(PaletteKeyMonitor(
            onMove: moveSelection,
            onSelect: { isVisible = false },
            isFieldFocused: fieldFocused
        ))
        .onAppear {
            DispatchQueue.main.async { fieldFocused = true }
            registry.connectConfiguredServers()
            normalizeSelection()
        }
        .onChange(of: query) { _ in normalizeSelection() }
        .onChange(of: registry.statuses) { _ in normalizeSelection() }
        .onExitCommand { isVisible = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MCP Tool Picker")
        .accessibilityIdentifier("MCP Tool Picker")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Grant tools").typoSection()
                    Text("Choose which MCP tools this character may call during a live call.")
                        .typoCaption(.medium)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(MCPToolGrantsSummary.line(for: grants))
                    .typoCaption(.semibold)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tools", text: $query)
                    .textFieldStyle(.plain)
                    .typoBody(.medium)
                    .focused($fieldFocused)
                    .onSubmit { isVisible = false }
                    .accessibilityLabel("Search tools")
                if !query.isEmpty {
                    Button {
                        query = ""
                        fieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear tool search")
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.10)))
        }
        .padding(16)
    }

    private var toolList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if groups.isEmpty {
                        emptyState
                    } else {
                        ForEach(groups) { group in
                            serverHeader(group)
                            if !collapsedServers.contains(group.id) {
                                groupBody(group)
                            }
                        }
                    }
                }
                .padding(7)
            }
            .frame(maxHeight: 410 * textScale)
            .onChange(of: selectedID) { id in
                if let id {
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .typoIcon(size: 22, .medium)
            Text("No MCP servers")
                .typoBody(.semibold)
            Text("Add a server under Settings → MCP Servers.")
                .typoCaption()
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    @ViewBuilder private func groupBody(_ group: ServerGroup) -> some View {
        if group.tools.isEmpty {
            Text(placeholderText(for: group.status))
                .typoCaption()
                .foregroundStyle(group.isFailed ? .red : .secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
        } else {
            ForEach(group.tools) { tool in
                row(tool).id(tool.id)
            }
        }
    }

    private func serverHeader(_ group: ServerGroup) -> some View {
        let collapsed = collapsedServers.contains(group.id)
        return Button {
            withAnimation(.easeOut(duration: 0.14)) {
                if collapsed { collapsedServers.remove(group.id) } else { collapsedServers.insert(group.id) }
            }
            normalizeSelection()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .typoIcon(size: 8, .bold)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(group.id.uppercased()).typoCaption(.bold)
                if case .connecting = group.status {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
                Text("\(group.tools.count)")
                    .typoCaption(.semibold, design: .monospaced)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 2)
        }
        .buttonStyle(.plain)
    }

    private func row(_ tool: MCPToolDescriptor) -> some View {
        let selected = selectedID == tool.namespacedName
        let permission = grants[tool.namespacedName] ?? .notOffered
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(tool.toolName)
                        .typoBody(.semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if tool.isReadOnly {
                        Text("READ-ONLY")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.065), in: Capsule())
                    }
                }
                if !tool.description.isEmpty {
                    Text(tool.description)
                        .typoCaption()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            permissionChip(tool: tool, permission: permission)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(selected ? model.theme.signatureColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onHover { hovering in if hovering { selectedID = tool.namespacedName } }
        .onTapGesture { selectedID = tool.namespacedName }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tool \(tool.toolName)")
        .accessibilityValue(permissionLabel(permission))
        .accessibilityIdentifier("MCP Tool \(tool.namespacedName)")
    }

    private func permissionChip(tool: MCPToolDescriptor, permission: MCPToolPermission) -> some View {
        Button {
            cycle(tool)
        } label: {
            Text(permissionLabel(permission))
                .typoCaption(.semibold)
                .foregroundStyle(permissionColor(permission))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(permissionColor(permission).opacity(0.14), in: Capsule())
                .overlay(Capsule().stroke(permissionColor(permission).opacity(0.30)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("MCP Tool Permission \(tool.namespacedName)")
        .help("Cycle permission.")
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label("Navigate", systemImage: "arrow.up.arrow.down")
            Label("Click a chip to cycle", systemImage: "cursorarrow.click")
            Label("Done", systemImage: "return")
            Spacer()
            Button("Done") { isVisible = false }
                .buttonStyle(.plain)
                .foregroundStyle(model.theme.signatureColor)
                .accessibilityIdentifier("MCP Tools Done")
        }
        .typoCaption(.medium)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    // MARK: Behavior

    private func normalizeSelection() {
        let ids = flatTools.map(\.namespacedName)
        guard !ids.isEmpty else { selectedID = nil; return }
        if selectedID == nil || !ids.contains(selectedID!) {
            selectedID = ids.first
        }
    }

    private func moveSelection(_ delta: Int) {
        selectedID = PaletteSelectionIndex.move(
            current: selectedID, ids: flatTools.map(\.namespacedName), delta: delta
        )
    }

    private func cycle(_ tool: MCPToolDescriptor) {
        selectedID = tool.namespacedName
        let current = grants[tool.namespacedName] ?? .notOffered
        let next = MCPToolPolicy.cyclePermission(current, isReadOnly: tool.isReadOnly)
        // Only non-notOffered entries are stored, so notOffered clears the key.
        if next == .notOffered {
            grants.removeValue(forKey: tool.namespacedName)
        } else {
            grants[tool.namespacedName] = next
        }
    }

    private func placeholderText(for status: MCPServerStatus) -> String {
        switch status {
        case .connecting: return "Connecting…"
        case .failed(let reason): return "Failed: \(reason)"
        case .connected: return query.isEmpty ? "No tools" : "No matching tools"
        case .idle: return "Not connected"
        case .disabled: return "Disabled"
        }
    }

    private func permissionLabel(_ permission: MCPToolPermission) -> String {
        switch permission {
        case .notOffered: return "Off"
        case .askFirst: return "Ask first"
        case .alwaysAllow: return "Always allow"
        }
    }

    private func permissionColor(_ permission: MCPToolPermission) -> Color {
        switch permission {
        case .notOffered: return .secondary
        case .askFirst: return .orange
        case .alwaysAllow: return .green
        }
    }
}
