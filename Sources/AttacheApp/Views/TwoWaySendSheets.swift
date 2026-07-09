import SwiftUI
import AttacheCore

/// First-use enablement for send-to-agent on a specific session. States plainly
/// what it does and the safety rules (docs/two-way.md), and requires an explicit
/// enable. Ask Attaché may also hand off an explicit request through this gate.
struct TwoWayEnableSheet: View {
    let sessionTitle: String
    let directSendEnabled: Bool
    let onEnable: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "paperplane.circle.fill")
                    .typoIcon(size: 22).foregroundStyle(.orange)
                Text("Send instructions to \(sessionTitle)?")
                    .typoSection()
            }
            Text("This turns on send-to-agent for this session. Attaché will deliver instructions you confirm back into the agent by resuming it, acting with your own agent permissions. It waits until the session is quiet, sends one at a time, and never approves permissions or tool use on the agent's behalf.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(directSendEnabled
                 ? "This first instruction still asks for final confirmation. After that, your Settings choice sends future Tell Agent turns and explicit personality handoffs for this session without the final sheet."
                 : "Every send still asks you to confirm first. You can turn this off for the session at any time.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Enable send-to-agent", action: onEnable)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .accessibilityLabel("Enable send-to-agent")
            }
        }
        .padding(20).frame(width: 440)
    }
}

/// Default per-instruction confirmation: repeats exactly what will be sent and
/// to which session, and requires an explicit Send.
struct TwoWayConfirmSheet: View {
    let instruction: Instruction
    let onSend: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "paperplane.fill")
                    .typoIcon(size: 20).foregroundStyle(.orange)
                Text("Send this to \(instruction.targetDisplayName ?? "this session")?")
                    .typoSection()
            }
            Text("“\(instruction.text)”")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            if instruction.origin == .personalityTool,
               let source = instruction.sourceUtterance,
               source.trimmingCharacters(in: .whitespacesAndNewlines) != instruction.text {
                Text("Requested in Ask Attaché: “\(source)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Delivered by resuming the agent when the session is quiet. This goes INTO the agent, not to Attaché.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Send to agent", action: onSend)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(.orange)
                    .accessibilityLabel("Send to agent")
            }
        }
        .padding(20).frame(width: 440)
    }
}
