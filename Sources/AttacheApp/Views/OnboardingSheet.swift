import AppKit
import AttacheCore
import SwiftUI
import UniformTypeIdentifiers

// First-run onboarding (INF-153): launch to first spoken card in under two
// minutes. Five steps: the product in one sentence, source detection, voice,
// a verified model integration, and the character who ties it all together.
// normal pipeline. Fully keyboard navigable; Escape offers to skip; skipping
// lands in a sane state and the flow is re-runnable from Settings and Help.

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case sources
    case voice
    case integrations
    case finish

    var title: String {
        switch self {
        case .welcome: return "Welcome to Attaché"
        case .sources: return "Connect your agents"
        case .voice: return "Pick a voice"
        case .integrations: return "Connect a model"
        case .finish: return "Pick a character"
        }
    }
}

/// Filesystem probes for known agent session stores. Counts are capped; the
/// point is "found something" plus a rough magnitude, not an exact census.
enum OnboardingSourceProbe {
    static func codexSessionCount(limit: Int = 200) -> Int {
        count(root: CodexPaths.sessionsDirectory(), suffix: ".jsonl", limit: limit)
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
    @ObservedObject private var contextUI = AttacheContextUIState.shared
    @State private var step: OnboardingStep = .welcome
    @State private var codexCount = 0
    @State private var claudeCount = 0
    @State private var probed = false
    @State private var demoSent = false
    @State private var confirmSkip = false
    @State private var setupProvider: AttachePresentationProvider = .ollama
    @State private var pendingCloudModel: AttachePresentationProvider?

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
        .frame(width: 720, height: 650)
        .onAppear {
            probeIfNeeded()
            model.checkAllIntegrations()
        }
        .onExitCommand { confirmSkip = true }
        .alert("Skip setup?", isPresented: $confirmSkip) {
            Button("Keep going", role: .cancel) {}
            Button("Skip") { skipOnboarding() }
        } message: {
            Text("You can run the welcome again anytime from Settings or the Help menu.")
        }
        .sheet(item: $pendingCloudModel) { provider in
            CloudConsentSheet(
                providerName: provider.title,
                produces: "personality responses",
                sends: "your agent's output, session transcripts, and files the model is asked to read",
                onEnable: {
                    model.acknowledgeCloudConsent(for: provider)
                    model.useHealthyModelProviderForOnboarding(provider)
                    pendingCloudModel = nil
                },
                onCancel: { pendingCloudModel = nil }
            )
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
        case .integrations: integrationsStep
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
            if model.isScanningVoices && recommendedVoices.isEmpty {
                Text("Scanning voices…")
                    .typoCaption().foregroundStyle(.secondary)
            }
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
    private func pickVoice(_ option: AttacheVoiceOption) {
        model.speechProvider = .system
        model.speechVoiceIdentifier = option.id
        // The voice belongs to the active personality, not an orphan global.
        model.captureCurrentVoiceIntoActivePersonality()
    }

    private func voiceRow(_ option: AttacheVoiceOption) -> some View {
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

    private var integrationsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Attaché needs one working model for personality summaries and live conversation. Pick any connected option below, or set one up here.")
                .typoBody()
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(AttachePresentationProvider.personalityInferenceCases) { provider in
                    onboardingProviderCard(provider)
                }
            }

            modelSetupPanel

            if model.onboardingModelReady {
                Label("Ready: \(model.presentationProvider.title) · \(model.presentationModel)", systemImage: "checkmark.circle.fill")
                    .typoCaption(.semibold)
                    .foregroundStyle(.green)
            } else {
                Label("Test an integration, then click Use before continuing.", systemImage: "info.circle")
                    .typoCaption()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func onboardingProviderCard(_ provider: AttachePresentationProvider) -> some View {
        let health = model.healthStatus(model.integrationID(for: provider))
        let selected = model.onboardingModelReady && model.presentationProvider == provider
        return Button {
            setupProvider = provider
            if case .healthy = health { requestOnboardingProvider(provider) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    onboardingHealthIcon(health)
                    Text(provider.title).typoBody(.semibold).lineLimit(1)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
                }
                Text(providerSetupDetail(provider))
                    .typoCaption()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
            .background(
                selected ? accent.opacity(0.13) : Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? accent.opacity(0.65) : (setupProvider == provider ? accent.opacity(0.3) : Color.primary.opacity(0.07)))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(provider.title), \(healthLabel(health))")
    }

    private var modelSetupPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Set up \(setupProvider.title)").typoLabel(.semibold)
                Spacer()
                Link("Setup guide", destination: modelGuideURL(setupProvider))
                    .typoCaption(.medium)
            }

            switch setupProvider {
            case .xai:
                RevealableAPIKeyField(
                    placeholder: "xAI API key",
                    accessibilityName: "xAI API key",
                    text: $model.xaiAPIKey
                )
            case .groq:
                RevealableAPIKeyField(
                    placeholder: "Groq API key",
                    accessibilityName: "Groq API key",
                    text: $model.groqAPIKey
                )
            case .custom:
                TextField("OpenAI-compatible /v1 endpoint", text: $model.customBaseURL).textFieldStyle(.roundedBorder)
                RevealableAPIKeyField(
                    placeholder: "API key",
                    accessibilityName: "OpenAI-compatible API key",
                    text: $model.customAPIKey
                )
            case .ollama:
                TextField("Ollama /v1 endpoint", text: $model.ollamaBaseURL).textFieldStyle(.roundedBorder)
            case .codexCLI:
                Text("Codex subscription inference is disabled until Codex CLI can guarantee that native file-reading tools are off.")
                    .typoCaption().foregroundStyle(.secondary)
            case .claudeCLI:
                Text("Install and sign in to Claude Code. Attaché uses a one-shot run with tools and project settings disabled.")
                    .typoCaption().foregroundStyle(.secondary)
            }

            HStack {
                Text(healthLabel(model.healthStatus(model.integrationID(for: setupProvider))))
                    .typoCaption()
                    .foregroundStyle(healthColor(model.healthStatus(model.integrationID(for: setupProvider))))
                    .lineLimit(2)
                Spacer()
                Button(setupProvider.requiresAPIKey ? "Save & Test" : "Test") {
                    testOnboardingProvider(setupProvider)
                }
                if case .healthy = model.healthStatus(model.integrationID(for: setupProvider)) {
                    Button("Use") { requestOnboardingProvider(setupProvider) }
                        .buttonStyle(.borderedProminent)
                        .tint(accent)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func onboardingHealthIcon(_ health: IntegrationHealth) -> some View {
        switch health {
        case .unconfigured: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .checking: ProgressView().scaleEffect(0.55).frame(width: 16, height: 16)
        case .healthy: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .unhealthy: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func healthLabel(_ health: IntegrationHealth) -> String {
        switch health {
        case .unconfigured: return "Not connected"
        case .checking: return "Testing…"
        case .healthy: return "Connected"
        case .unhealthy(let message): return "Failed: \(message)"
        }
    }

    private func healthColor(_ health: IntegrationHealth) -> Color {
        switch health {
        case .healthy: return .green
        case .unhealthy: return .red
        case .unconfigured, .checking: return .secondary
        }
    }

    private func providerSetupDetail(_ provider: AttachePresentationProvider) -> String {
        switch provider {
        case .ollama: return "Local · no key"
        case .codexCLI, .claudeCLI: return "Uses your CLI login"
        case .xai: return "Grok models"
        case .groq: return "Fast cloud inference"
        case .custom: return "Any compatible endpoint"
        }
    }

    private func testOnboardingProvider(_ provider: AttachePresentationProvider) {
        switch provider {
        case .xai: model.saveXAIIntegration()
        case .groq: model.saveGroqIntegration()
        case .custom: model.saveCustomIntegration()
        case .ollama, .codexCLI, .claudeCLI: break
        }
        model.checkIntegration(model.integrationID(for: provider))
    }

    private func requestOnboardingProvider(_ provider: AttachePresentationProvider) {
        if model.presentationProviderSendsToCloud(provider),
           !model.cloudConsentAcknowledged(for: provider) {
            pendingCloudModel = provider
        } else {
            model.useHealthyModelProviderForOnboarding(provider)
        }
    }

    private func modelGuideURL(_ provider: AttachePresentationProvider) -> URL {
        let guide: AttacheDocumentationLinks.ModelIntegrationGuide
        switch provider {
        case .xai: guide = .xai
        case .ollama: guide = .ollama
        case .groq: guide = .groq
        case .custom: guide = .openAICompatible
        case .codexCLI: guide = .codexCLI
        case .claudeCLI: guide = .claudeCode
        }
        return AttacheDocumentationLinks.modelIntegration(guide)
    }

    static let welcomePersonalities: [(id: String, blurb: String)] = [
        ("builtin.bigPicture", "The robot. Outcome first, always oriented."),
        ("builtin.cowboy", "The cowboy. Plainspoken, dry, and weathered."),
        ("builtin.echo", "Abstract presence. A calm voice with responsive bars.")
    ]

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose who meets you in Attaché. Your voice and current model stay attached to this character. You can fine-tune both or build more later.")
                .typoCaption()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(Self.welcomePersonalities, id: \.id) { entry in
                    if let personality = model.personalities.first(where: { $0.id == entry.id }) {
                        personalityCard(personality, blurb: entry.blurb)
                    }
                }
            }

            if let custom = model.activePersonality, !custom.isBuiltIn {
                HStack(spacing: 10) {
                    Text(custom.characterAvatarEmoji)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(custom.name).typoBody(.semibold)
                        Text("Your custom character is selected.").typoCaption().foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                }
                .padding(9)
                .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 10) {
                Button {
                    NotificationCenter.default.post(name: .attacheOpenPersonalityStudio, object: PersonalityStudioRequest.create)
                } label: {
                    Label("Create custom character", systemImage: "sparkles")
                }
                Button {
                    importOnboardingCharacter()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                Link(
                    "Character artwork guide",
                    destination: AttacheDocumentationLinks.characterArtwork
                )
                .typoCaption(.medium)
            }

            memoryChoice

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

    private var memoryChoice: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("Memory").typoLabel(.semibold)
                Spacer()
                Text("Optional and local by default")
                    .typoCaption()
                    .foregroundStyle(.secondary)
            }
            Picker("Memory", selection: onboardingMemoryBinding) {
                Text("Off").tag(Optional(AttacheMemoryProposalMode.off))
                Text("Suggest").tag(Optional(AttacheMemoryProposalMode.suggest))
                Text("Automatic").tag(Optional(AttacheMemoryProposalMode.automatic))
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Choose memory mode")
            .accessibilityValue(
                contextUI.memoryChoiceWasExplicit
                    ? onboardingMemoryLabel(contextUI.memoryMode)
                    : "Not chosen"
            )

            Text(onboardingMemoryExplanation)
                .typoCaption()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("First-run memory choice")
    }

    private func personalityCard(_ personality: Personality, blurb: String) -> some View {
        let selected = model.activePersonalityID == personality.id
        return VStack(spacing: 7) {
            PersonalityPresencePreview(personality: personality, animatedBars: true)
                .frame(height: 88)
            HStack(spacing: 5) {
                Text(personality.name).typoBody(.semibold)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(accent)
                }
            }
            Text(blurb)
                .typoCaption()
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(personality.modelSummary)
                .typoCaption(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Preview") {
                model.previewPersonality(personality)
            }
            .typoCaption(.medium)
            .buttonStyle(.borderless)
            .accessibilityLabel("Hear \(personality.name) sample")
        }
        .padding(9)
        .background(selected ? accent.opacity(0.12) : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? accent.opacity(0.65) : Color.primary.opacity(0.07)))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { selectWelcomePersonality(personality.id) }
        .accessibilityLabel("Personality \(personality.name)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selectWelcomePersonality(personality.id) }
    }

    private var footer: some View {
        HStack {
            Button("Skip for now") { skipOnboarding() }
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
                    .disabled(
                        step == .integrations
                            && !model.onboardingModelReady
                            && ProcessInfo.processInfo.environment["ATTACHE_UI_TEST"] != "1"
                    )
            } else {
                Button("Finish") {
                    model.captureCurrentVoiceIntoActivePersonality()
                    model.captureCurrentModelIntoActivePersonality()
                    model.completeOnboarding()
                }
                    .keyboardShortcut(demoSent ? .defaultAction : nil)
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .accessibilityLabel("Finish welcome")
                    .disabled(!contextUI.memoryChoiceWasExplicit)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: helpers

    private func selectWelcomePersonality(_ id: String) {
        model.selectOnboardingPersonality(id)
    }

    private var onboardingMemoryBinding: Binding<AttacheMemoryProposalMode?> {
        Binding(
            get: {
                contextUI.memoryChoiceWasExplicit ? contextUI.memoryMode : nil
            },
            set: { choice in
                if let choice { contextUI.setMemoryMode(choice) }
            }
        )
    }

    private var onboardingMemoryExplanation: String {
        guard contextUI.memoryChoiceWasExplicit else {
            return "Choose whether Attaché may notice durable details you tell it directly. Skipping setup leaves memory Off."
        }
        switch contextUI.memoryMode {
        case .off:
            return "Nothing new is proposed or saved. You can turn memory on later in Settings."
        case .suggest:
            return "Attaché asks before saving every durable detail it notices."
        case .automatic:
            return "Low-sensitivity facts you state clearly may be saved; sensitive or uncertain details still require approval."
        }
    }

    private func onboardingMemoryLabel(_ mode: AttacheMemoryProposalMode) -> String {
        switch mode {
        case .off: return "Off"
        case .suggest: return "Suggest"
        case .automatic: return "Automatic"
        }
    }

    private func skipOnboarding() {
        contextUI.leaveMemoryOffForSkippedOnboarding()
        model.completeOnboarding()
    }

    private func importOnboardingCharacter() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK,
           let url = panel.url,
           let data = try? Data(contentsOf: url) {
            model.importPersonality(from: data)
        }
    }

    private var recommendedVoices: [AttacheVoiceOption] {
        var picks = Array(AttacheVoiceCatalog.recommended(from: model.speechVoiceOptions).prefix(3))
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

    private static func qualityTier(_ option: AttacheVoiceOption) -> Int {
        AttacheVoiceCatalog.qualityTier(option)
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
