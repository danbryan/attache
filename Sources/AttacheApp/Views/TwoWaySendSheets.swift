import SwiftUI
import AttacheCore

/// First-use enablement for send-to-agent on a specific session. States plainly
/// what it does and the safety rules (docs/two-way.md), and requires an explicit
/// enable. Distinct from "Ask Attaché", which never leaves the app.
struct TwoWayEnableSheet: View {
    let sessionTitle: String
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
            Text("Every send still asks you to confirm first. You can turn this off for the session at any time.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Enable send-to-agent", action: onEnable)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 440)
    }
}

/// Per-instruction confirmation: repeats exactly what will be sent and to which
/// session, and requires an explicit Send. No path sends without this.
struct TwoWayConfirmSheet: View {
    let instruction: Instruction
    let sessionTitle: String
    let onSend: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "paperplane.fill")
                    .typoIcon(size: 20).foregroundStyle(.orange)
                Text("Send this to \(sessionTitle)?")
                    .typoSection()
            }
            Text("“\(instruction.text)”")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            Text("Delivered by resuming the agent when the session is quiet. This goes INTO the agent, not to Attaché.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Send to agent", action: onSend)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(.orange)
            }
        }
        .padding(20).frame(width: 440)
    }
}
