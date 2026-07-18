import AttacheCore
import SwiftUI

/// Playground for the Attaché activity contract (INF-268): pick any phase,
/// agent, tool kind, or one-shot expression and every renderer follows because
/// the override flows through the same `attacheActivity` they already consume.
/// The override never persists. The environment flag still opens the panel for
/// automated QA, but people can also open it from a character's context menu.
struct ActivitySimulatorPanel: View {
    @ObservedObject var model: AppModel
    var onClose: () -> Void
    @State private var phase: AttacheActivityPhase = .idle
    @State private var agent: AttacheAgentIdentity = .codex
    @State private var toolKind: AttacheToolKind = .shell
    @State private var overriding = false
    @State private var cycling = false
    @State private var claudeCount = 0
    @State private var codexCount = 0
    @State private var workShare = 2
    @State private var oneBlocked = false
    @State private var oneFinished = false
    @State private var subAgents = 0
    /// Sub-agents assigned per fleet slot by "Add subs to focused", kept when
    /// focus moves so several sessions (including non-focused ones) can carry them.
    @State private var subsBySlot: [Int: Int] = [:]
    /// When set, the character compacts (ramping squish) as if the focused session
    /// fired PreCompact, for previewing the sustained compaction.
    @State private var compactingSince: Date?
    @State private var demoElapsed = -1.0
    private let cycleTimer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()
    private let demoTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Activity simulator")
                    .typoCaption(.bold)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Cycle", isOn: $cycling)
                    .toggleStyle(.checkbox)
                    .typoCaption(.medium)
                    .accessibilityLabel("Cycle activity phases")
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close activity simulator")
            }
            .padding(12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Activity source", selection: $overriding) {
                        Text("Preview controls").tag(true)
                        Text("Follow the app").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Activity simulator source")

                    Text(overriding
                         ? "The controls below are driving the Attaché preview."
                         : "Your Attaché is following real app activity.")
                        .typoCaption(.medium)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    GroupBox("Activity") {
                        VStack(alignment: .leading, spacing: 9) {
                            Picker("Phase", selection: $phase) {
                                ForEach(AttacheActivityPhase.allCases, id: \.self) { phase in
                                    Text(phaseTitle(phase)).tag(phase)
                                }
                            }
                            .accessibilityLabel("Simulated phase")

                            Picker("Agent", selection: $agent) {
                                ForEach(AttacheAgentIdentity.allCases, id: \.self) { agent in
                                    Text(agentTitle(agent)).tag(agent)
                                }
                            }
                            .accessibilityLabel("Simulated agent")

                            if phase == .toolRunning {
                                Picker("Tool gesture", selection: $toolKind) {
                                    ForEach(AttacheToolKind.allCases, id: \.self) { kind in
                                        Text(toolTitle(kind)).tag(kind)
                                    }
                                }
                                .accessibilityLabel("Simulated tool kind")

                                Text("Tool gestures preview how your Attaché reacts to editing, reading, shell commands, and web tools.")
                                    .typoCaption(.medium)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("One-shot expressions") {
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                            alignment: .leading,
                            spacing: 8
                        ) {
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Agent fleet") {
                        VStack(alignment: .leading, spacing: 9) {
                            Stepper("Claude Code sessions: \(claudeCount)", value: $claudeCount, in: 0...40)
                                .accessibilityLabel("Simulated Claude fleet size")
                            Stepper("Codex sessions: \(codexCount)", value: $codexCount, in: 0...40)
                                .accessibilityLabel("Simulated Codex fleet size")
                            Picker("Working sessions", selection: $workShare) {
                                Text("None").tag(0)
                                Text("Half").tag(1)
                                Text("All").tag(2)
                            }
                            .accessibilityLabel("Simulated working share")

                            HStack(spacing: 16) {
                                Toggle("One blocked", isOn: $oneBlocked)
                                    .toggleStyle(.checkbox)
                                    .accessibilityLabel("Simulate one blocked session")
                                Toggle("One finished", isOn: $oneFinished)
                                    .toggleStyle(.checkbox)
                                    .accessibilityLabel("Simulate one finished session")
                            }

                            Stepper("Subagents to add: \(subAgents)", value: $subAgents, in: 0...30)
                                .accessibilityLabel("Sub-agents to add per click")

                            LazyVGrid(
                                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                                spacing: 8
                            ) {
                                simulatorButton("Add subagents to focused session") {
                                    addSubsToFocusedSession()
                                }
                                .disabled(claudeCount + codexCount == 0 || subAgents == 0)
                                .accessibilityLabel("Add sub-agents to the focused session")

                                simulatorButton("Clear all subagents") {
                                    subsBySlot = [:]
                                    applyIfSimulating()
                                }
                                .accessibilityLabel("Clear simulated sub-agents")
                            }

                            simulatorButton(compactingSince == nil ? "Start compaction preview" : "Stop compaction preview") {
                                compactingSince = compactingSince == nil ? Date() : nil
                                applyIfSimulating()
                            }
                            .accessibilityLabel("Toggle sustained compaction preview")

                            LazyVGrid(
                                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                                spacing: 8
                            ) {
                                simulatorButton(demoElapsed >= 0 ? "Fleet demo running" : "Run fleet demo") {
                                    startFleetDemo()
                                }
                                .disabled(demoElapsed >= 0)
                                .accessibilityLabel("Run fleet demo")

                                simulatorButton("Speak sample") {
                                    // Real speech needs the real signal path: drop the
                                    // override so the speaking phase, mouth sync, arcs,
                                    // and captions all fire as they would live.
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
                        }
                        .typoCaption(.medium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text(stateReadout)
                        .typoCaption(.medium, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Attache activity state \(stateReadout)")
                }
                .padding(12)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(width: 410)
        .frame(maxHeight: 680)
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
        .onChange(of: overriding) { active in
            if active {
                apply()
            } else {
                cycling = false
                model.simulatedActivity = nil
                model.simulatedFleetFocusID = nil
            }
        }
        .onChange(of: cycling) { active in
            if active {
                overriding = true
                apply()
            }
        }
        .onReceive(cycleTimer) { _ in
            guard cycling else { return }
            let all = AttacheActivityPhase.allCases
            let index = all.firstIndex(of: phase) ?? 0
            phase = all[(index + 1) % all.count]
        }
        .onAppear {
            if model.activitySimulatorAutoCycles {
                phase = .toolRunning
                overriding = true
                cycling = true
                apply()
            } else {
                overriding = true
                apply()
            }
        }
        .onDisappear {
            model.simulatedActivity = nil
            model.simulatedFleetFocusID = nil
        }
    }

    /// Round-trip proof for QA: reads back what `attacheActivity` actually
    /// publishes, not what the pickers requested.
    private var stateReadout: String {
        let state = model.attacheActivity
        var parts = [state.phase.rawValue, state.activeAgent.rawValue]
        if let toolKind = state.toolKind { parts.append(toolKind.rawValue) }
        if state.userTyping { parts.append("typing") }
        return parts.joined(separator: " · ")
    }

    /// A moment preview button. Full-width in its grid cell and never truncated,
    /// so labels like "Configuring" and "Permission" always show in full.
    @ViewBuilder
    private func momentButton(_ title: String, _ kind: AttacheActivityMoment.Kind) -> some View {
        Button {
            model.triggerMoment(kind, agent: agent)
        } label: {
            Text(title)
                .lineLimit(nil)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 18)
        }
            .accessibilityLabel("\(title) moment")
    }

    /// Simulator controls are allowed to wrap and grow vertically. A fixed
    /// one-line label silently reintroduces ellipses as soon as the app text
    /// scale or a localization is wider than the English default.
    private func simulatorButton<Label: StringProtocol>(
        _ title: Label,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .lineLimit(nil)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 20)
        }
    }

    private func phaseTitle(_ phase: AttacheActivityPhase) -> String {
        switch phase {
        case .sleeping: return "Sleeping"
        case .idle: return "Idle"
        case .agentThinking: return "Agent thinking"
        case .agentResponding: return "Agent responding"
        case .toolRunning: return "Tool running"
        case .speaking: return "Speaking"
        case .paused: return "Playback paused"
        case .blockedOnUser: return "Needs your input"
        case .error: return "Error"
        }
    }

    private func agentTitle(_ agent: AttacheAgentIdentity) -> String {
        switch agent {
        case .none: return "No agent"
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        }
    }

    private func toolTitle(_ tool: AttacheToolKind) -> String {
        switch tool {
        case .edit: return "Editing files"
        case .read: return "Reading or searching"
        case .shell: return "Shell command"
        case .web: return "Web or external tool"
        case .other: return "Other tool"
        }
    }

    /// Assign the current Subs count to the currently focused session, and keep
    /// it there when focus moves. Focus a session, set the count, add; then
    /// focus another and add to it, to load several sessions.
    private func addSubsToFocusedSession() {
        let ids = (0..<claudeCount).map { "sim-Claude-\($0)" }
            + (0..<codexCount).map { "sim-Codex-\($0)" }
        guard !ids.isEmpty else { return }
        let focusIndex = ids.firstIndex { $0 == model.simulatedFleetFocusID } ?? 0
        subsBySlot[focusIndex] = subAgents
        applyIfSimulating()
    }

    private func apply() {
        model.simulatedActivity = AttacheActivityState(
            phase: phase,
            activeAgent: agent,
            toolKind: phase == .toolRunning ? toolKind : nil,
            userTyping: model.userTyping,
            unreadCount: model.unreadCount,
            hasCards: !model.cards.isEmpty,
            fleet: simulatedFleet(),
            compactingSince: compactingSince
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
    private func simulatedFleet() -> [AttacheFleetSession] {
        func sessions(_ count: Int, agent: AttacheAgentIdentity, prefix: String) -> [AttacheFleetSession] {
            guard count > 0 else { return [] }
            let workingCount = workShare == 0 ? 0 : (workShare == 1 ? (count + 1) / 2 : count)
            return (0..<count).map { index in
                var state: AttacheFleetSession.State = index < workingCount ? .working : .quiet
                if oneFinished, agent == .claude, index == max(0, count - 2) { state = .finished }
                if oneBlocked, agent == .claude, index == count - 1 { state = .blocked }
                return AttacheFleetSession(
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
