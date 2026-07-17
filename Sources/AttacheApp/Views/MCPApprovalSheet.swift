import AttacheCore
import SwiftUI

/// Ask-first confirmation for an MCP tool call (INF-373), the same one-tap
/// interaction as the agent-send confirm. It names the tool, its server, and
/// the character asking, shows the pretty-printed arguments, and marks whether
/// the tool is read-only or effectful. "Always allow" is offered for read-only
/// tools only; effectful tools can never be always-allowed.
struct MCPApprovalSheet: View {
    let approval: PendingMCPApproval
    let personalityName: String
    let onDecision: (MCPApprovalDecision) -> Void

    private var descriptor: MCPToolDescriptor { approval.descriptor }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .typoIcon(size: 20).foregroundStyle(.orange)
                Text("Run \(descriptor.toolName)?")
                    .typoSection()
            }

            HStack(spacing: 8) {
                Text(descriptor.serverName)
                    .typoCaption(.semibold)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                Text(descriptor.isReadOnly ? "READ-ONLY" : "CAN MAKE CHANGES")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(descriptor.isReadOnly ? Color.secondary : Color.orange)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background((descriptor.isReadOnly ? Color.primary.opacity(0.08) : Color.orange.opacity(0.14)), in: Capsule())
            }

            Text("\(personalityName) wants to look this up during your call.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if !prettyArguments.isEmpty {
                ScrollView {
                    Text(prettyArguments)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 160)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.10)))
            }

            HStack {
                Button("Deny", role: .cancel) { onDecision(.deny) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("MCP Deny")
                Spacer()
                if descriptor.isReadOnly {
                    Button("Always allow for \(personalityName)") { onDecision(.alwaysAllow) }
                        .accessibilityIdentifier("MCP Always Allow")
                }
                Button("Allow Once") { onDecision(.allowOnce) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .accessibilityIdentifier("MCP Allow Once")
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var prettyArguments: String {
        let raw = approval.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw != "{}" else { return "" }
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(
               withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
           ),
           let string = String(data: pretty, encoding: .utf8) {
            return string
        }
        return raw
    }
}
