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
    @State private var oneFinished = false
    @State private var subAgents = 0
    /// Sub-agents assigned per fleet slot by the "Add subs" button, so you can
    /// load several sessions (including non-focused ones), not just one.
    @State private var subsBySlot: [Int: Int] = [:]
    @State private var nextSubSlot = 0
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
                    model.simulatedFleetFocusID = nil
                }
                .disabled(!overriding)
            }
            .typoCaption(.medium)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
                momentButton("Celebrate", .celebrate)
                momentButton("Pop", .cardArrived)
                momentButton("Drowsy", .drowsy)
                momentButton("Needs you", .needsYou)
                momentButton("Greet", .greet)
                momentButton("Farewell", .farewell)
                momentButton("Configuring", .configuring)
                momentButton("Compacting", .compacting)
                momentButton("Errored", .errored)
                momentButton("Permission", .permissionAsk)
                momentButton("Denied", .permissionDenied)
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
                Toggle("Done", isOn: $oneFinished)
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("Simulate one finished session")
                Stepper("Subs: \(subAgents)", value: $subAgents, in: 0...30)
                    .accessibilityLabel("Sub-agents to add per click")
            }
            .typoCaption(.medium)
            HStack(spacing: 6) {
                Button("Add subs to a session") { addSubsToNextSession() }
                    .disabled(claudeCount + codexCount == 0 || subAgents == 0)
                    .accessibilityLabel("Add sub-agents to the next session")
                Button("Clear subs") { subsBySlot = [:]; nextSubSlot = 0; applyIfSimulating() }
                    .accessibilityLabel("Clear simulated sub-agents")
            }
            .typoCaption(.medium)
            HStack(spacing: 6) {
                Button(demoElapsed >= 0 ? "Fleet demo running" : "Fleet demo") { startFleetDemo() }
                    .disabled(demoElapsed >= 0)
                    .accessibilityLabel("Run fleet demo")
                Button("Speak sample") {
                    // Real speech needs the real signal path: drop the
                    // override so the speaking phase, mouth sync, arcs, and
                    // captions all fire as they would live.
                    overriding = false
                    cycling = false
                    model.simulatedActivity = nil
                    model.playback.preview("""
                    Here's a taste of narration so you can watch the mouth, the arcs, \
                    and the karaoke captions all move together. The agents wrapped two \
                    tasks while you were away, and nothing needs your attention yet.
                    """)
                }
                .accessibilityLabel("Speak a sample with captions")
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
        .onChange(of: claudeCount) { _ in applyIfSimulating() }
        .onChange(of: codexCount) { _ in applyIfSimulating() }
        .onChange(of: workShare) { _ in applyIfSimulating() }
        .onChange(of: oneBlocked) { _ in applyIfSimulating() }
        .onChange(of: oneFinished) { _ in applyIfSimulating() }
        .onChange(of: model.simulatedFleetFocusID) { _ in applyIfSimulating() }
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
        .onDisappear {
            model.simulatedActivity = nil
            model.simulatedFleetFocusID = nil
        }
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

    /// A moment preview button. Full-width in its grid cell and never truncated,
    /// so labels like "Configuring" and "Permission" always show in full.
    @ViewBuilder
    private func momentButton(_ title: String, _ kind: CompanionActivityMoment.Kind) -> some View {
        Button(title) { model.triggerMoment(kind, agent: agent) }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("\(title) moment")
    }

    /// Assign the current Subs count to the next session in rotation, so
    /// repeated clicks load several sessions, focused or not.
    private func addSubsToNextSession() {
        let total = claudeCount + codexCount
        guard total > 0 else { return }
        subsBySlot[nextSubSlot % total] = subAgents
        nextSubSlot += 1
        applyIfSimulating()
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

    /// Fabricates a fleet from the panel's knobs: the focused session is the
    /// last one clicked on the ring (first Claude by default) and carries
    /// the sub-agents, the last Claude is the blocked one when that toggle
    /// is on, the second-to-last the finished one, and the working share
    /// fills front to back.
    private func simulatedFleet() -> [CompanionFleetSession] {
        func sessions(_ count: Int, agent: CompanionAgentIdentity, prefix: String) -> [CompanionFleetSession] {
            guard count > 0 else { return [] }
            let workingCount = workShare == 0 ? 0 : (workShare == 1 ? (count + 1) / 2 : count)
            return (0..<count).map { index in
                var state: CompanionFleetSession.State = index < workingCount ? .working : .quiet
                if oneFinished, agent == .claude, index == max(0, count - 2) { state = .finished }
                if oneBlocked, agent == .claude, index == count - 1 { state = .blocked }
                return CompanionFleetSession(
                    id: "sim-\(prefix)-\(index)",
                    agent: agent,
                    state: state,
                    isFocused: false,
                    activeSubAgents: 0,
                    title: "\(prefix) \(index + 1)"
                )
            }
        }
        var fleet = sessions(claudeCount, agent: .claude, prefix: "Claude")
            + sessions(codexCount, agent: .codex, prefix: "Codex")
        guard !fleet.isEmpty else { return fleet }
        let focusIndex = fleet.firstIndex { $0.id == model.simulatedFleetFocusID } ?? 0
        fleet[focusIndex].isFocused = true
        // Sub-agents come from the "Add subs" button per slot, so any sessions
        // (including non-focused ones) can carry them, not just one.
        for index in fleet.indices {
            fleet[index].activeSubAgents = subsBySlot[index] ?? 0
        }
        return fleet
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
        case ..<26:     oneBlocked = true; oneFinished = true
        case ..<32:     workShare = 1
        default:        claudeCount = 24; codexCount = 6; workShare = 2; oneBlocked = false; oneFinished = false
        }
        apply()
    }
}
