import AttacheCore
import SwiftUI

/// Debug-only driver for the companion contract (INF-268): pick any phase,
/// agent, and tool kind, or let it cycle through every phase on a timer, and
/// every renderer follows because the override flows through the same
/// `companionActivity` they already consume. Shown only when the app runs
/// with `ATTACHE_ACTIVITY_SIMULATOR=1`; the override never persists.
struct ActivitySimulatorPanel: View {
    @ObservedObject var model: AppModel
    @State private var phase: CompanionActivityPhase = .idle
    @State private var agent: CompanionAgentIdentity = .codex
    @State private var toolKind: CompanionToolKind = .shell
    @State private var overriding = false
    @State private var cycling = false
    private let cycleTimer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Activity simulator")
                    .typoCaption(.bold)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Cycle", isOn: $cycling)
                    .toggleStyle(.checkbox)
                    .typoCaption(.medium)
                    .accessibilityLabel("Cycle activity phases")
            }

            Picker("Phase", selection: $phase) {
                ForEach(CompanionActivityPhase.allCases, id: \.self) { phase in
                    Text(phase.rawValue).tag(phase)
                }
            }
            .accessibilityLabel("Simulated phase")

            Picker("Agent", selection: $agent) {
                ForEach(CompanionAgentIdentity.allCases, id: \.self) { agent in
                    Text(agent.rawValue).tag(agent)
                }
            }
            .accessibilityLabel("Simulated agent")

            Picker("Tool", selection: $toolKind) {
                ForEach(CompanionToolKind.allCases, id: \.self) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .disabled(phase != .toolRunning)
            .accessibilityLabel("Simulated tool kind")

            HStack(spacing: 8) {
                Button(overriding ? "Simulating" : "Simulate") {
                    overriding = true
                    apply()
                }
                .disabled(overriding)
                Button("Live") {
                    overriding = false
                    cycling = false
                    model.simulatedActivity = nil
                }
                .disabled(!overriding)
            }
            .typoCaption(.medium)

            Text(stateReadout)
                .typoCaption(.medium, design: .monospaced)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityLabel("Companion activity state \(stateReadout)")
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .padding(12)
        .frame(width: 230)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
        .onChange(of: phase) { _ in if overriding { apply() } }
        .onChange(of: agent) { _ in if overriding { apply() } }
        .onChange(of: toolKind) { _ in if overriding { apply() } }
        .onChange(of: cycling) { active in
            if active {
                overriding = true
                apply()
            }
        }
        .onReceive(cycleTimer) { _ in
            guard cycling else { return }
            let all = CompanionActivityPhase.allCases
            let index = all.firstIndex(of: phase) ?? 0
            phase = all[(index + 1) % all.count]
        }
        .onAppear {
            if model.activitySimulatorAutoCycles {
                phase = .toolRunning
                overriding = true
                cycling = true
                apply()
            }
        }
        .onDisappear { model.simulatedActivity = nil }
    }

    /// Round-trip proof for QA: reads back what `companionActivity` actually
    /// publishes, not what the pickers requested.
    private var stateReadout: String {
        let state = model.companionActivity
        var parts = [state.phase.rawValue, state.activeAgent.rawValue]
        if let toolKind = state.toolKind { parts.append(toolKind.rawValue) }
        if state.userTyping { parts.append("typing") }
        return parts.joined(separator: " · ")
    }

    private func apply() {
        model.simulatedActivity = CompanionActivityState(
            phase: phase,
            activeAgent: agent,
            toolKind: phase == .toolRunning ? toolKind : nil,
            userTyping: model.userTyping,
            unreadCount: model.unreadCount,
            hasCards: !model.cards.isEmpty
        )
    }
}
