import AppKit
import SwiftUI

// First-run onboarding (INF-153): launch to first spoken card in under two
// minutes. Four steps: the model in one sentence, source detection, voice
// pick with preview, and proving the loop with a demo event through the
// normal pipeline. Fully keyboard navigable; Escape offers to skip; skipping
// lands in a sane state and the flow is re-runnable from Settings and Help.

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case sources
    case voice
    case finish

    var title: String {
        switch self {
        case .welcome: return "Welcome to Attaché"
        case .sources: return "Connect your agents"
        case .voice: return "Pick a voice"
        case .finish: return "Pick a personality"
        }
    }
}

/// Filesystem probes for known agent session stores. Counts are capped; the
/// point is "found something" plus a rough magnitude, not an exact census.
enum OnboardingSourceProbe {
    static func codexSessionCount(limit: Int = 200) -> Int {
        count(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions"), suffix: ".jsonl", limit: limit)
    }

    static func claudeCodeSessionCount(limit: Int = 200) -> Int {
        count(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects"), suffix: ".jsonl", limit: limit)
    }

    private static func count(root: URL, suffix: String, limit: Int) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
        var found = 0
        for case let url as URL in enumerator {
            if url.lastPathComponent.hasSuffix(suffix) {
                found += 1
                if found >= limit { break }
            }
        }
        return found
    }
}

struct OnboardingSheet: View {
    @ObservedObject var model: AppModel
    @State private var step: OnboardingStep = .welcome
    @State private var codexCount = 0
    @State private var claudeCount = 0
    @State private var probed = false
    @State private var demoSent = false
    @State private var confirmSkip = false
    @State private var showCustomEditor = false
    @State private var customName = ""
    @State private var customPrompt = ""
    @State private var customCreatedID: String?

    private var accent: Color { model.theme.signatureColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            stepBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
            Divider()
            footer
        }
        .frame(width: 560, height: 560)
        .onAppear(perform: probeIfNeeded)
        .onExitCommand { confirmSkip = true }
        .alert("Skip setup?", isPresented: $confirmSkip) {
            Button("Keep going", role: .cancel) {}
            Button("Skip") { model.completeOnboarding() }
        } message: {
            Text("You can run the welcome again anytime from Settings or the Help menu.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.circle.fill")
                .typoIcon(size: 22, .semibold)
                .foregroundStyle(accent)
            Text(LocalizedStringKey(step.title)).typoTitle()
            Spacer()
            Text("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                .typoCaption(.medium, monoDigit: true)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder private var stepBody: some View {
        switch step {
        case .welcome: welcomeStep
        case .sources: sourcesStep
        case .voice: voiceStep
        case .finish: finishStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Attaché gives your AI agents a voice.")
                .typoSection()
            Text("Agents leave you voicemail in your Inbox; you can put one Live to hear it narrated in real time.")
                .typoBody()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Label("Two minutes, three choices, then you hear it work.", systemImage: "timer")
                .typoLabel()
                .foregroundStyle(.secondary)
        }
    }

    private var sourcesStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if codexCount > 0 || claudeCount > 0 {
                Text("Found agent sessions on this Mac. Enable the sources you want Attaché to follow.")
                    .typoBody()
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No agent sessions found yet. Install one of these, or continue and try the demo; Attaché picks up new sessions automatically.")
                    .typoBody()
                    .fixedSize(horizontal: false, vertical: true)
            }
            sourceRow(
                name: "Codex CLI",
                detail: codexCount > 0 ? "\(codexCount)\(codexCount >= 200 ? "+" : "") sessions in ~/.codex" : "Not found (install: github.com/openai/codex)",
                found: codexCount > 0,
                isOn: Binding(get: { model.codexSourceEnabled },
                              set: { model.setCodexSourceEnabled($0) })
            )
            sourceRow(
                name: "Claude Code",
                detail: claudeCount > 0 ? "\(claudeCount)\(claudeCount >= 200 ? "+" : "") sessions in ~/.claude" : "Not found (install: claude.com/claude-code)",
                found: claudeCount > 0,
                isOn: Binding(get: { model.claudeCodeSourceEnabled },
                              set: { model.setClaudeCodeSourceEnabled($0) })
            )
            Spacer()
        }
    }

    private func sourceRow(name: String, detail: String, found: Bool, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: found ? "checkmark.circle.fill" : "circle.dashed")
                .typoIcon(size: 16)
                .foregroundStyle(found ? accent : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).typoBody(.semibold)
                Text(detail).typoCaption().foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Enable \(name)")
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
    }

    private var voiceStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick the voice for spoken recaps. Preview plays a short line.")
                .typoBody()
            ForEach(recommendedVoices) { option in
                voiceRow(option)
            }
            HStack(spacing: 8) {
                Text("More voices").typoCaption(.medium).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { model.speechProvider == .system ? model.speechVoiceIdentifier : nil },
                    set: { id in
                        if let option = model.speechVoiceOptions.first(where: { $0.id == id }) {
                            pickVoice(option)
                        } else {
                            model.speechVoiceIdentifier = id
                        }
                    })) {
                    Text("Recommended").tag(String?.none)
                    ForEach(model.speechVoiceOptions) { option in
                        Text(option.title).tag(Optional(option.id))
                    }
                }
                .labelsHidden()
                .frame(width: 240)
                .accessibilityLabel("All voices")
                Spacer()
                Text("Changeable anytime in Settings > Voice & Captions.")
                    .typoCaption()
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 2)
            if let downloaded = model.newlyDownloadedVoice {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(downloaded.name) is downloaded. Attaché needs a quick relaunch to load it; you'll come right back here with it selected.", systemImage: "checkmark.circle.fill")
                        .typoCaption(.medium)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Relaunch and continue") {
                        model.relaunchForNewVoice(resumeStep: OnboardingStep.voice.rawValue)
                    }
                    .typoCaption(.semibold)
                    .accessibilityLabel("Relaunch and continue")
                }
                .padding(10)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            } else if !hasEnhancedVoice {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Only compact voices are installed. Premium voices sound much better:")
                        .typoCaption(.medium)
                        .foregroundStyle(.primary)
                    Text("1. Open voice settings, then click the info button next to System voice.")
                        .typoCaption()
                        .foregroundStyle(.secondary)
                    Text("2. Pick your language and download a Premium voice.")
                        .typoCaption()
                        .foregroundStyle(.secondary)
                    Text("3. Click back here. A relaunch button will bring you right back.")
                        .typoCaption()
                        .foregroundStyle(.secondary)
                    Button("Open voice settings") {
                        // Deep link to the speech pane (Read & Speak on newer
                        // macOS, Spoken Content on older); the legacy anchor
                        // still resolves there in System Settings.
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?TextToSpeech")!)
                    }
                    .typoCaption(.medium)
                    .accessibilityLabel("Open voice settings")
                }
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer()
        }
    }

    // Onboarding only offers macOS system voices, so a pick must also switch
    // the engine to the system provider. Otherwise a preview keeps using
    // whatever cloud voice is configured and every row sounds identical.
    private func pickVoice(_ option: CompanionVoiceOption) {
        model.speechProvider = .system
        model.speechVoiceIdentifier = option.id
    }

    private func voiceRow(_ option: CompanionVoiceOption) -> some View {
        let selected = model.speechProvider == .system && model.speechVoiceIdentifier == option.id
        return HStack(spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .typoIcon(size: 14)
                .foregroundStyle(selected ? accent : Color.secondary)
            Text(option.title).typoBody(selected ? .semibold : .regular)
            Spacer()
            Button("Preview") {
                pickVoice(option)
                model.previewAssistantVoice()
            }
            .typoCaption(.medium)
            .accessibilityLabel("Preview \(option.name)")
        }
        .padding(10)
        .background(selected ? accent.opacity(0.12) : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onTapGesture { pickVoice(option) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Voice \(option.name)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { pickVoice(option) }
    }

    private static let welcomePersonalities: [(id: String, blurb: String)] = [
        ("builtin.conciseBrief", "Tight and factual. The outcome, then one blocker if there is one."),
        ("builtin.bigPicture", "Outcomes only. What shipped or what's stuck, never the play-by-play."),
        ("builtin.inquisitive", "Summarizes, then suggests one worthwhile next move.")
    ]

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Personalities shape how recaps are written and spoken. Pick one; edit or add more later in Settings > Personalities.")
                .typoCaption()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Self.welcomePersonalities, id: \.id) { entry in
                if let personality = model.personalities.first(where: { $0.id == entry.id }) {
                    personalityRow(personality, blurb: entry.blurb)
                }
            }
            customPersonalityRow
            Divider().padding(.vertical, 2)
            HStack(spacing: 10) {
                Button {
                    model.onboardingProveTheLoop()
                    demoSent = true
                } label: {
                    Label(demoSent ? "Demo sent, listen…" : "Send my first update",
                          systemImage: demoSent ? "checkmark.circle.fill" : "paperplane.fill")
                        .typoBody(.semibold)
                }
                .keyboardShortcut(demoSent ? nil : .defaultAction)
                .accessibilityLabel("Send my first update")
                if demoSent {
                    Text("It's in your Inbox too; replay it anytime.")
                        .typoCaption()
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func personalityRow(_ personality: Personality, blurb: String) -> some View {
        let selected = model.activePersonalityID == personality.id
        return HStack(spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .typoIcon(size: 14)
                .foregroundStyle(selected ? accent : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(personality.name).typoBody(selected ? .semibold : .regular)
                Text(blurb).typoCaption().foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? accent.opacity(0.12) : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onTapGesture { model.selectPersonality(personality.id) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Personality \(personality.name)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selectPersonality(personality.id) }
    }

    @ViewBuilder private var customPersonalityRow: some View {
        if showCustomEditor {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name (e.g. Calm Senior Engineer)", text: $customName)
                    .textFieldStyle(.roundedBorder)
                    .typoCaption()
                    .accessibilityLabel("Custom personality name")
                TextField("How should updates sound? Tone, attitude, level of detail.", text: $customPrompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...3)
                    .typoCaption()
                    .accessibilityLabel("Custom personality description")
                HStack {
                    Button("Create and use") {
                        customCreatedID = model.createPersonality(name: customName, prompt: customPrompt)
                        showCustomEditor = false
                    }
                    .typoCaption(.semibold)
                    .disabled(customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Create and use custom personality")
                    Button("Cancel") { showCustomEditor = false }
                        .typoCaption()
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        } else if let createdID = customCreatedID,
                  let custom = model.personalities.first(where: { $0.id == createdID }) {
            personalityRow(custom, blurb: "Your custom personality.")
        } else {
            Button {
                showCustomEditor = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle").typoIcon(size: 14).foregroundStyle(accent)
                    Text("Create your own").typoBody()
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Create your own personality")
        }
    }

    private var footer: some View {
        HStack {
            Button("Skip for now") { model.completeOnboarding() }
                .typoLabel()
                .accessibilityLabel("Skip for now")
            Spacer()
            if step != .welcome {
                Button("Back") { move(-1) }
                    .typoLabel()
            }
            if step != .finish {
                Button(step == .welcome ? "Get started" : "Continue") { move(1) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .accessibilityLabel(step == .welcome ? "Get started" : "Continue")
            } else {
                Button("Finish") { model.completeOnboarding() }
                    .keyboardShortcut(demoSent ? .defaultAction : nil)
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .accessibilityLabel("Finish welcome")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: helpers

    private var recommendedVoices: [CompanionVoiceOption] {
        var picks = Array(CompanionVoiceCatalog.recommended(from: model.speechVoiceOptions).prefix(3))
        // The selected voice must always be visible, e.g. right after the
        // relaunch that loaded a voice picked mid-flow.
        if let selectedID = model.speechVoiceIdentifier,
           !picks.contains(where: { $0.id == selectedID }),
           let selected = model.speechVoiceOptions.first(where: { $0.id == selectedID }) {
            picks[picks.count - 1] = selected
        }
        return picks
    }

    private var hasEnhancedVoice: Bool {
        model.speechVoiceOptions.contains { Self.qualityTier($0) == 0 }
    }

    private static func qualityTier(_ option: CompanionVoiceOption) -> Int {
        CompanionVoiceCatalog.qualityTier(option)
    }

    private func probeIfNeeded() {
        guard !probed else { return }
        probed = true
        codexCount = OnboardingSourceProbe.codexSessionCount()
        claudeCount = OnboardingSourceProbe.claudeCodeSessionCount()
        if let resume = model.takeOnboardingResumeStep(),
           let resumeStep = OnboardingStep(rawValue: resume) {
            step = resumeStep
        }
        if model.speechVoiceIdentifier == nil {
            // Auto-pick prefers a modern voice; a legacy pick like Ralph stays
            // in the list for deliberate selection but is never the default.
            let picks = recommendedVoices
            model.speechVoiceIdentifier = (picks.first { Self.qualityTier($0) <= 1 } ?? picks.first)?.id
        }
    }

    private func move(_ delta: Int) {
        let next = OnboardingStep(rawValue: step.rawValue + delta) ?? step
        withAnimation(.easeInOut(duration: 0.15)) { step = next }
    }
}
