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
    @State private var claudeCount = 0
    @State private var codexCount = 0
    @State private var workShare = 2
    @State private var oneBlocked = false
    @State private var subAgents = 0
    @State private var demoElapsed = -1.0
    private let cycleTimer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()
    private let demoTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

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

            HStack(spacing: 6) {
                Button("Celebrate") { model.triggerMoment(.celebrate, agent: agent) }
                    .accessibilityLabel("Celebrate moment")
                Button("Pop") { model.triggerMoment(.cardArrived, agent: agent) }
                    .accessibilityLabel("Pop moment")
                Button("Drowsy") { model.triggerMoment(.drowsy, agent: agent) }
                    .accessibilityLabel("Drowsy moment")
            }
            .typoCaption(.medium)

            Stepper("Claude fleet: \(claudeCount)", value: $claudeCount, in: 0...40)
                .typoCaption(.medium)
                .accessibilityLabel("Simulated Claude fleet size")
            Stepper("Codex fleet: \(codexCount)", value: $codexCount, in: 0...40)
                .typoCaption(.medium)
                .accessibilityLabel("Simulated Codex fleet size")
            Picker("Working", selection: $workShare) {
                Text("none").tag(0)
                Text("half").tag(1)
                Text("all").tag(2)
            }
            .accessibilityLabel("Simulated working share")
            HStack(spacing: 6) {
                Toggle("Blocked", isOn: $oneBlocked)
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("Simulate one blocked session")
                Stepper("Subs: \(subAgents)", value: $subAgents, in: 0...30)
                    .accessibilityLabel("Simulated sub-agents on the focused session")
            }
            .typoCaption(.medium)
            Button(demoElapsed >= 0 ? "Fleet demo running" : "Fleet demo") { startFleetDemo() }
                .disabled(demoElapsed >= 0)
                .typoCaption(.medium)
                .accessibilityLabel("Run fleet demo")

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
        .onChange(of: claudeCount) { _ in applyIfSimulating() }
        .onChange(of: codexCount) { _ in applyIfSimulating() }
        .onChange(of: workShare) { _ in applyIfSimulating() }
        .onChange(of: oneBlocked) { _ in applyIfSimulating() }
        .onChange(of: subAgents) { _ in applyIfSimulating() }
        .onReceive(demoTimer) { _ in advanceFleetDemo() }
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
            hasCards: !model.cards.isEmpty,
            fleet: simulatedFleet()
        )
    }

    private func applyIfSimulating() {
        if !overriding, claudeCount + codexCount > 0 {
            overriding = true
        }
        if overriding { apply() }
    }

    /// Fabricates a fleet from the panel's knobs: the first Claude session
    /// is focused (and carries the sub-agents), the last is the blocked one
    /// when that toggle is on, and the working share fills front to back.
    private func simulatedFleet() -> [CompanionFleetSession] {
        func sessions(_ count: Int, agent: CompanionAgentIdentity, prefix: String) -> [CompanionFleetSession] {
            guard count > 0 else { return [] }
            let workingCount = workShare == 0 ? 0 : (workShare == 1 ? (count + 1) / 2 : count)
            return (0..<count).map { index in
                var state: CompanionFleetSession.State = index < workingCount ? .working : .quiet
                if oneBlocked, agent == .claude, index == count - 1 { state = .blocked }
                let focused = agent == .claude && index == 0
                return CompanionFleetSession(
                    id: "sim-\(prefix)-\(index)",
                    agent: agent,
                    state: state,
                    isFocused: focused,
                    activeSubAgents: focused ? subAgents : 0,
                    title: "\(prefix) \(index + 1)"
                )
            }
        }
        return sessions(claudeCount, agent: .claude, prefix: "Claude")
            + sessions(codexCount, agent: .codex, prefix: "Codex")
    }

    /// A scripted 40 second fleet story for recordings: grow to a badge,
    /// ripple sub-agents, block one, park half, then surge to a
    /// 30-session fleet.
    private func startFleetDemo() {
        demoElapsed = 0
        overriding = true
        cycling = false
        phase = .idle
        agent = .claude
        applyDemoStage()
    }

    private func advanceFleetDemo() {
        guard demoElapsed >= 0 else { return }
        demoElapsed += 0.5
        if demoElapsed > 40 {
            demoElapsed = -1
            return
        }
        applyDemoStage()
    }

    private func applyDemoStage() {
        switch demoElapsed {
        case ..<4:      claudeCount = 1;  codexCount = 0; workShare = 2; oneBlocked = false; subAgents = 0
        case ..<8:      claudeCount = 3;  codexCount = 2
        case ..<14:     claudeCount = 12; codexCount = 3
        case ..<20:     subAgents = 8
        case ..<26:     oneBlocked = true
        case ..<32:     workShare = 1
        default:        claudeCount = 24; codexCount = 6; workShare = 2; oneBlocked = false
        }
        apply()
    }
}
