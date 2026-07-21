import SwiftUI

/// The agents Attaché watches. Enabling an agent indexes its sessions and lets
/// Attaché speak its updates; everything stays on this Mac. Enabling Claude
/// Code or Codex additionally installs Attaché's status hooks (opinionated
/// default, INF): those two report status the instant it changes, while the
/// other agents are followed through their session files. Turning a source off
/// removes its hooks again. Install or removal failures never block the toggle;
/// they surface as a caption on the row and Attaché falls back to session
/// files.
struct AgentsPane: View {
    @ObservedObject var model: AppModel

    /// The four watchable local agent sources, in a fixed display order. The
    /// `hooked` sources (Claude Code, Codex) get immediate status through an
    /// installed hook; the others are followed through their session files.
    /// Exposed for the pane-composition test so the list can never silently
    /// drift from the four sources.
    struct SourceRow: Identifiable {
        let id: String
        let title: String
        /// True when enabling this source installs an immediacy hook.
        let hooked: Bool
    }

    static let sources: [SourceRow] = [
        SourceRow(id: "codex", title: "Codex sessions", hooked: true),
        SourceRow(id: "claude", title: "Claude Code sessions", hooked: true),
        SourceRow(id: "grok", title: "Grok Build sessions", hooked: false),
        SourceRow(id: "opencode", title: "opencode sessions", hooked: false)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agents").typoTitle()
            Text("Enable an agent and Attaché indexes its sessions and speaks its updates. Data stays on this Mac.")
                .typoLabel()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            agentSources
            agentInstructions
        }
    }

    private var agentSources: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local agent sources")
                .typoBody(.semibold)
            ForEach(Self.sources) { source in
                sourceRow(source)
            }
            Text("Status is immediate for Claude Code and Codex through installed hooks; other agents are followed through their session files, which is close but less immediate.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private func sourceRow(_ source: SourceRow) -> some View {
        Toggle(source.title, isOn: binding(for: source.id))
        if let warning = warning(for: source.id) {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("Agent hook warning \(source.id)")
        }
    }

    private var agentInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent instructions")
                .typoBody(.semibold)
            Text("Reverse-send writes into the focused agent session with your own agent permissions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Skip final send confirmation", isOn: Binding(
                get: { model.directAgentSendEnabled },
                set: { model.directAgentSendEnabled = $0 }
            ))
            .accessibilityLabel("Skip final send confirmation")
            Text("After you enable send-to-agent for a session, explicit Tell Agent turns can send directly. Ask Attaché handoffs always show the exact message and frozen target for confirmation because model tool calls can be influenced by session evidence.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }

    private func binding(for id: String) -> Binding<Bool> {
        switch id {
        case "codex":
            return Binding(get: { model.codexSourceEnabled }, set: { model.setCodexSourceEnabled($0) })
        case "claude":
            return Binding(get: { model.claudeCodeSourceEnabled }, set: { model.setClaudeCodeSourceEnabled($0) })
        case "grok":
            return Binding(get: { model.grokBuildSourceEnabled }, set: { model.setGrokBuildSourceEnabled($0) })
        case "opencode":
            return Binding(get: { model.opencodeSourceEnabled }, set: { model.setOpencodeSourceEnabled($0) })
        default:
            return .constant(false)
        }
    }

    private func warning(for id: String) -> String? {
        switch id {
        case "claude": return model.claudeHookWarning
        case "codex": return model.codexNotifyWarning
        default: return nil
        }
    }
}
