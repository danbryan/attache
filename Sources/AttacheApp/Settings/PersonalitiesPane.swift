import AppKit
import AttacheCore
import SwiftUI
import UniformTypeIdentifiers

/// A wardrobe first, not a database editor. The pane is for switching among
/// finished characters; creation and editing happen in the focused studio sheet.
struct PersonalitiesPane: View {
    @ObservedObject var model: AppModel

    @State private var pendingDeletePersonality: Personality?

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 230), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if let active = model.activePersonality {
                activeCharacter(active)
            }
            wardrobe
            if let deleted = model.recentlyDeletedPersonality {
                undoBar(for: deleted)
            }
        }
        .onDisappear { model.clearRecentlyDeletedPersonality() }
        .confirmationDialog(
            pendingDeletePersonality.map { "Delete \($0.name)?" } ?? "Delete personality?",
            isPresented: Binding(
                get: { pendingDeletePersonality != nil },
                set: { presented in if !presented { pendingDeletePersonality = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = pendingDeletePersonality {
                    model.deletePersonality(id: target.id)
                }
                pendingDeletePersonality = nil
            }
            .accessibilityLabel("Delete personality confirm")
            Button("Cancel", role: .cancel) { pendingDeletePersonality = nil }
        } message: {
            Text("This removes its prompt, voice, presence, and model choices. This cannot be undone after you leave Settings.")
        }
    }

    private func undoBar(for deleted: AppModel.DeletedPersonalitySnapshot) -> some View {
        HStack(spacing: 10) {
            Text("Deleted \"\(deleted.personality.name)\".")
                .typoCaption()
                .foregroundStyle(.secondary)
            Button("Undo") { model.undoDeletePersonality() }
                .buttonStyle(.borderless)
                .accessibilityLabel("Undo delete personality")
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Personalities").typoTitle()
                    Text("Build the character you want to spend time with.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { importPersonality() } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                Button {
                    openStudio(.create)
                } label: {
                    Label("Create character", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func activeCharacter(_ personality: Personality) -> some View {
        HStack(spacing: 18) {
            PersonalityPresencePreview(personality: personality, animatedBars: true)
                .frame(width: 150, height: 150)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(personality.name).typoDisplay(size: 24, .semibold)
                    Text("ACTIVE")
                        .typoCaption(.bold)
                        .foregroundStyle(model.theme.signatureColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(model.theme.signatureColor.opacity(0.12), in: Capsule())
                }

                HStack(spacing: 7) {
                    CharacterDetailChip(icon: "person.crop.circle", text: personality.presenceSummary)
                    CharacterDetailChip(icon: "speaker.wave.2", text: personality.voiceSummary(in: model.speechVoiceOptions))
                    CharacterDetailChip(icon: "cpu", text: personality.modelSummary)
                }

                Text(personality.prompt)
                    .typoCaption()
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 9) {
                    Button {
                        model.previewPersonality(personality)
                    } label: {
                        Label("Preview personality", systemImage: "play.fill")
                    }
                    Button(personality.isBuiltIn ? "Customize" : "Edit") {
                        openStudio(personality.isBuiltIn ? .customize(personality) : .edit(personality))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [model.theme.signatureColor.opacity(0.13), Color(nsColor: .controlBackgroundColor)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(model.theme.signatureColor.opacity(0.24)))
    }

    private var wardrobe: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your wardrobe").typoSection()
                Spacer()
                Text("Switching changes personality, voice, presence, and preferred model together.")
                    .typoCaption()
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(model.personalities) { personality in
                    wardrobeCard(personality)
                }
            }

            Text("Personality files can reuse any presence shown here. Credentials are never included in imports or exports.")
                .typoCaption()
                .foregroundStyle(.tertiary)
        }
    }

    private func wardrobeCard(_ personality: Personality) -> some View {
        let active = personality.id == model.activePersonalityID
        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                PersonalityPresencePreview(personality: personality, animatedBars: false)
                    .frame(maxWidth: .infinity)
                    .frame(height: 112)

                Menu {
                    wardrobeCardMenuItems(personality)
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .typoIcon(size: 17)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            HStack(spacing: 6) {
                Text(personality.name).typoBody(.semibold).lineLimit(1)
                if personality.isBuiltIn {
                    Text("Built-in").typoCaption(.medium).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if active {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(model.theme.signatureColor)
                }
            }
            Text("\(personality.presenceSummary) · \(personality.voiceSummary(in: model.speechVoiceOptions))")
                .typoCaption()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(
            active ? model.theme.signatureColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 13)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(active ? model.theme.signatureColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: active ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 13))
        // Double click opens the editor; single click switches. Also reachable
        // via the ellipsis Menu above and the context menu below.
        .onTapGesture(count: 2) {
            openStudio(personality.isBuiltIn ? .customize(personality) : .edit(personality))
        }
        .onTapGesture { model.switchPersonalityFromUI(personality.id) }
        .contextMenu { wardrobeCardMenuItems(personality) }
        .help("Click to switch, double-click to \(personality.isBuiltIn ? "customize" : "edit").")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(personality.name), \(active ? "active" : "available") personality")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.switchPersonalityFromUI(personality.id) }
        .accessibilityAction(named: Text(personality.isBuiltIn ? "Customize character" : "Edit character")) {
            openStudio(personality.isBuiltIn ? .customize(personality) : .edit(personality))
        }
    }

    @ViewBuilder
    private func wardrobeCardMenuItems(_ personality: Personality) -> some View {
        if personality.isBuiltIn {
            Button("Customize") { openStudio(.customize(personality)) }
        } else {
            Button("Edit") { openStudio(.edit(personality)) }
        }
        Button("Duplicate") { model.duplicatePersonality(id: personality.id) }
        Button("Export") { exportPersonality(personality) }
        if !personality.isBuiltIn {
            Divider()
            Button("Delete", role: .destructive) { pendingDeletePersonality = personality }
        }
    }

    private func exportPersonality(_ personality: Personality) {
        guard let data = model.exportPersonalityData(id: personality.id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(personality.name).json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    private func importPersonality() {
        let environment = ProcessInfo.processInfo.environment
        if environment["ATTACHE_UI_TEST"] == "1",
           let path = environment["ATTACHE_UI_TEST_IMPORT_PERSONALITY_PATH"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            model.importPersonality(from: data)
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            model.importPersonality(from: data)
        }
    }

    private func openStudio(_ request: PersonalityStudioRequest) {
        NotificationCenter.default.post(name: .attacheOpenPersonalityStudio, object: request)
    }
}

struct PersonalityStudioRequest: Identifiable {
    enum Mode { case create, edit, customize }

    var mode: Mode
    var source: Personality?

    static var create: PersonalityStudioRequest { PersonalityStudioRequest(mode: .create, source: nil) }
    static func edit(_ source: Personality) -> PersonalityStudioRequest { PersonalityStudioRequest(mode: .edit, source: source) }
    static func customize(_ source: Personality) -> PersonalityStudioRequest { PersonalityStudioRequest(mode: .customize, source: source) }

    var id: String {
        switch mode {
        case .create: return "create"
        case .edit: return "edit.\(source?.id ?? "unknown")"
        case .customize: return "customize.\(source?.id ?? "unknown")"
        }
    }

    var replacingID: String? { mode == .edit ? source?.id : nil }
}

struct PersonalityStudioSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var contextUI = AttacheContextUIState.shared
    let request: PersonalityStudioRequest
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var draft: Personality
    @State private var previewText = ""
    @State private var previewPreparing = false
    @State private var modelOptions: [AttachePresentationModelOption] = []
    @State private var modelDiscoveryStatus = ""
    @State private var pendingCloudVoice: AttacheSpeechProvider?
    @State private var previewAfterCloudVoiceConsent = false
    @State private var pendingVoicePickerSelection: VoicePickerEntry?
    @State private var voicePickerPresented = false
    @State private var pendingCloudModel: AttachePresentationProvider?
    @State private var personalityLibraryPresented = false
    @State private var personalityQuery = ""
    @State private var selectedTemplateID: String?

    init(model: AppModel, request: PersonalityStudioRequest, onClose: (() -> Void)? = nil) {
        self.model = model
        self.request = request
        self.onClose = onClose

        let initial: Personality
        if var source = request.source {
            if request.mode == .customize {
                source.name = "My \(source.name)"
                source.isBuiltIn = false
            }
            initial = source
            _selectedTemplateID = State(initialValue: source.id)
        } else {
            let starter = Personality.builtIns.first { $0.id == Personality.defaultActiveID } ?? Personality.builtIns[0]
            initial = Personality(
                id: "draft",
                name: "My Personality",
                prompt: starter.prompt,
                voiceRef: model.currentPersonalityVoiceRef,
                character: .robot,
                visualMode: .character,
                modelRef: model.currentPersonalityModelRef,
                playbackSpeed: model.playbackSpeed
            )
            _selectedTemplateID = State(initialValue: starter.id)
        }
        _draft = State(initialValue: initial)
    }

    var body: some View {
        HStack(spacing: 0) {
            auditionStage
                .frame(width: 280)

            Divider()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        studioHeader
                        HStack(alignment: .top, spacing: 20) {
                            VStack(alignment: .leading, spacing: 18) {
                                presenceSection
                                personalitySection
                            }
                            .frame(maxWidth: .infinity, alignment: .top)

                            Divider()

                            VStack(alignment: .leading, spacing: 18) {
                                voiceSection
                                modelSection
                                contextSection
                            }
                            .frame(width: 390, alignment: .top)
                        }
                    }
                    .padding(22)
                }
                Divider()
                footer
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
            }
            .frame(minWidth: 850)
        }
        .frame(
            minWidth: 1_100,
            idealWidth: 1_160,
            maxWidth: .infinity,
            minHeight: 680,
            idealHeight: 740,
            maxHeight: .infinity
        )
        .attacheTextScale(model.uiTextScale)
        .onAppear {
            if let modelID = draft.modelRef?.model {
                selectDraftModel(modelID)
            }
            loadRemoteVoicesIfNeeded()
            loadDraftModels()
        }
        .onDisappear { model.cancelPersonalityPreview() }
        .sheet(item: $pendingCloudVoice) { engine in
            let requestedXAIBaseURL = draftXAIBaseURL(for: engine)
            CloudConsentSheet(
                providerName: engine.title,
                produces: "speech",
                sends: "the preview greeting and future recap text",
                destination: model.voiceConsentDestination(
                    for: engine,
                    xaiBaseURL: requestedXAIBaseURL
                ),
                onEnable: {
                    model.acknowledgeCloudVoiceConsent(
                        for: engine,
                        xaiBaseURL: requestedXAIBaseURL
                    )
                    if let entry = pendingVoicePickerSelection {
                        applyVoiceSelection(entry)
                        pendingVoicePickerSelection = nil
                    } else {
                        setVoiceProvider(engine)
                    }
                    pendingCloudVoice = nil
                    if previewAfterCloudVoiceConsent {
                        previewAfterCloudVoiceConsent = false
                        beginPersonalityPreview()
                    }
                },
                onCancel: {
                    previewAfterCloudVoiceConsent = false
                    pendingVoicePickerSelection = nil
                    pendingCloudVoice = nil
                }
            )
        }
        .sheet(item: $pendingCloudModel) { provider in
            CloudConsentSheet(
                providerName: provider.title,
                produces: "personality responses",
                sends: "your agent's output, session transcripts, and files the model is asked to read",
                onEnable: {
                    model.acknowledgeCloudConsent(for: provider)
                    setModelProvider(provider)
                    pendingCloudModel = nil
                },
                onCancel: { pendingCloudModel = nil }
            )
        }
    }

    private var auditionStage: some View {
        VStack(spacing: 18) {
            Spacer()
            PersonalityPresencePreview(personality: draft, animatedBars: true)
                .frame(width: 230, height: 230)
                .id("\(draft.visualMode?.rawValue ?? "inherit").\(draft.character?.rawValue ?? "robot")")
                .transition(.opacity.combined(with: .scale(scale: 0.82)))
                .animation(.spring(response: 0.42, dampingFraction: 0.8), value: draft.visualMode)
                .animation(.spring(response: 0.42, dampingFraction: 0.8), value: draft.character)

            VStack(spacing: 5) {
                Text(draft.name.isEmpty ? "Your character" : draft.name)
                    .typoDisplay(size: 25, .semibold)
                    .multilineTextAlignment(.center)
                Text("\(draft.presenceSummary) · \(draft.voiceSummary(in: model.speechVoiceOptions))")
                    .typoCaption()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: requestPersonalityPreview) {
                Label(previewPreparing ? "Preparing…" : "Preview personality", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(previewPreparing || !canSave)

            if !previewText.isEmpty {
                Text("“\(previewText)”")
                    .typoBody(.medium)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            } else {
                Text("Preview is the only time a character greets you automatically.")
                    .typoCaption()
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(24)
        .background(
            LinearGradient(
                colors: [model.theme.signatureColor.opacity(0.16), Color(nsColor: .windowBackgroundColor)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var studioHeader: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(request.mode == .edit ? "Edit character" : "Create a character").typoTitle()
                Text("Every character owns its personality, voice, and model.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Character name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .accessibilityLabel("Character name")
        }
    }

    private var presenceSection: some View {
        studioSection(title: "Wardrobe", trailing: AnyView(spriteHelpLink)) {
            HStack(spacing: 10) {
                ForEach(WardrobeChoice.allCases) { choice in
                    Button {
                        choice.apply(to: &draft)
                    } label: {
                        VStack(spacing: 7) {
                            PersonalityPresencePreview(personality: choice.personalityPreview, animatedBars: false)
                                .frame(width: 100, height: 86)
                            Text(choice.title).typoLabel(.semibold)
                            Text(choice.detail)
                                .typoCaption()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            choice.matches(draft) ? model.theme.signatureColor.opacity(0.14) : Color.primary.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 11)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 11)
                                .stroke(choice.matches(draft) ? model.theme.signatureColor.opacity(0.7) : Color.primary.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose \(choice.title) presence")
                }
            }
            Text("Echo is the voice-bars presence with no character. Imported personalities can reuse any compatible appearance.")
                .typoCaption()
                .foregroundStyle(.secondary)
        }
    }

    private var personalitySection: some View {
        studioSection(title: "Personality") {
            HStack(spacing: 8) {
                Button {
                    personalityLibraryPresented = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Starting point").typoCaption().foregroundStyle(.secondary)
                            Text(selectedTemplateName).typoBody(.medium).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $personalityLibraryPresented, arrowEdge: .bottom) {
                    personalityLibrary
                }
                Button {
                    startNewPersonality()
                } label: {
                    Label("New", systemImage: "plus")
                }
                .accessibilityLabel("Write a new personality")
            }

            TextEditor(text: $draft.prompt)
                .typoBody(design: .default)
                .frame(minHeight: 170)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                .accessibilityLabel("Personality instructions")
                .onChange(of: draft.prompt) { value in
                    if let selectedTemplateID,
                       model.personalities.first(where: { $0.id == selectedTemplateID })?.prompt != value {
                        self.selectedTemplateID = nil
                    }
                }
            Text("Describe tone, attitude, level of detail, and language. Attaché adds the safety and spoken-output rules.")
                .typoCaption()
                .foregroundStyle(.secondary)
        }
    }

    private var selectedTemplateName: String {
        guard let selectedTemplateID,
              let template = model.personalities.first(where: { $0.id == selectedTemplateID }) else {
            return "Custom personality"
        }
        return template.name
    }

    private var filteredPersonalityTemplates: [Personality] {
        let query = personalityQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.personalities }
        return model.personalities.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.prompt.localizedCaseInsensitiveContains(query)
        }
    }

    private var personalityLibrary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a starting personality").typoSection()
            TextField("Search personalities", text: $personalityQuery)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search personality library")

            Button {
                startNewPersonality()
            } label: {
                Label("Write a new personality", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)

            Divider()

            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(filteredPersonalityTemplates) { template in
                        Button {
                            selectPersonalityTemplate(template)
                        } label: {
                            HStack(spacing: 9) {
                                Text(template.characterAvatarEmoji)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text(template.name).typoBody(.medium)
                                        if template.isBuiltIn {
                                            Text("Built-in").typoCaption().foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(template.creatorBlurb)
                                        .typoCaption()
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if selectedTemplateID == template.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(model.theme.signatureColor)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use \(template.name) personality")
                    }
                }
            }
            if filteredPersonalityTemplates.isEmpty {
                Text("No matching personalities. Start a new one instead.")
                    .typoCaption()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 380, height: 420)
    }

    private func selectPersonalityTemplate(_ template: Personality) {
        selectedTemplateID = template.id
        withAnimation(.easeInOut(duration: 0.16)) {
            draft.prompt = template.prompt
        }
        personalityLibraryPresented = false
        personalityQuery = ""
    }

    private func startNewPersonality() {
        selectedTemplateID = nil
        draft.prompt = ""
        personalityLibraryPresented = false
        personalityQuery = ""
    }

    private var spriteHelpLink: some View {
        Link(
            destination: AttacheDocumentationLinks.customSprite
        ) {
            Label("Sprite format", systemImage: "questionmark.circle")
                .typoCaption(.medium)
        }
        .help("Learn about the custom sprite format and planned import support")
        .accessibilityLabel("Learn about custom sprites")
    }

    private var voiceSection: some View {
        studioSection(title: "Voice") {
            if let voice = draft.voiceRef {
                Picker("Engine", selection: Binding(
                    get: { voice.provider },
                    set: { requestVoiceProvider($0) }
                )) {
                    ForEach(voiceEngineOptions) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Character voice engine")

                voicePicker(for: voice.provider)

                if !model.connectedVoiceEngines.contains(voice.provider) {
                    Label("\(voice.provider.title) is not configured. Preview and playback will use an on-device voice until its key is added in Integrations.", systemImage: "exclamationmark.triangle.fill")
                        .typoCaption()
                        .foregroundStyle(.orange)
                }

                if voice.provider.sendsToCloud {
                    Label("The preview greeting and future spoken text are sent to this voice provider.", systemImage: "cloud")
                        .typoCaption()
                        .foregroundStyle(.orange)
                } else {
                    Label("On-device voice. Spoken text stays on this Mac.", systemImage: "lock.shield")
                        .typoCaption()
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Text("Pace")
                    Slider(
                        value: Binding(
                            get: { draft.playbackSpeed ?? 1.0 },
                            set: { draft.playbackSpeed = $0 }
                        ),
                        in: 0.8...1.6,
                        step: 0.05
                    )
                    .accessibilityLabel("Character playback speed")
                    Text(String(format: "%.2fx", draft.playbackSpeed ?? 1.0))
                        .typoCaption(.medium, monoDigit: true)
                        .frame(width: 42, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                Text("This pace follows the character for live speech and voicemail replay.")
                    .typoCaption()
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func voicePicker(for provider: AttacheSpeechProvider) -> some View {
        switch provider {
        case .system, .xai, .openai:
            voicePickerLauncher
        case .elevenLabs:
            remoteVoicePicker(
                options: model.elevenLabsVoiceOptions,
                selectedID: draft.voiceRef?.elevenLabsVoiceID ?? "",
                fallbackName: draft.voiceRef?.elevenLabsVoiceName,
                select: { option in updateVoice { $0.elevenLabsVoiceID = option.id; $0.elevenLabsVoiceName = option.name } },
                reload: { model.loadElevenLabsVoices() }
            )
        }
    }

    /// System, xAI, and OpenAI voice choice all go through the rebuilt
    /// picker (INF-352): search, engine/quality/language filters, grouped
    /// rows, and per-row preview, presented as a sheet within the studio.
    /// ElevenLabs keeps the pre-existing plain picker above.
    private var voicePickerLauncher: some View {
        Button {
            voicePickerPresented = true
        } label: {
            HStack {
                Image(systemName: "waveform")
                Text(draft.voiceSummary(in: model.speechVoiceOptions))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Browse voices")
        .accessibilityValue(draft.voiceSummary(in: model.speechVoiceOptions))
        .sheet(isPresented: $voicePickerPresented) {
            VoicePickerView(
                model: model,
                currentEngine: draft.voiceRef?.provider ?? .system,
                currentSystemVoiceID: draft.voiceRef?.systemVoiceIdentifier,
                currentXAIVoiceID: draft.voiceRef?.xaiVoiceID,
                currentOpenAIVoiceID: draft.voiceRef?.openaiVoiceID,
                onSelect: { entry in requestVoiceSelection(entry) },
                onClose: { voicePickerPresented = false }
            )
        }
    }

    private func requestVoiceSelection(_ entry: VoicePickerEntry) {
        previewAfterCloudVoiceConsent = false
        let provider = entry.engine
        if provider.sendsToCloud,
           !model.cloudVoiceConsentAcknowledged(
               for: provider,
               xaiBaseURL: draftXAIBaseURL(for: provider)
           ) {
            // Close the voice picker sheet first so the consent sheet
            // presents on the studio itself rather than stacking on top of
            // an already-presented sheet.
            pendingVoicePickerSelection = entry
            voicePickerPresented = false
            pendingCloudVoice = provider
        } else {
            applyVoiceSelection(entry)
        }
    }

    private func applyVoiceSelection(_ entry: VoicePickerEntry) {
        setVoiceProvider(entry.engine)
        updateVoice { ref in
            switch entry.engine {
            case .system:
                ref.systemVoiceIdentifier = entry.voiceID
            case .xai:
                ref.xaiVoiceID = entry.voiceID
                ref.xaiVoiceName = entry.name
            case .openai:
                ref.openaiVoiceID = entry.voiceID
                ref.openaiVoiceName = entry.name
            case .elevenLabs:
                break
            }
        }
        voicePickerPresented = false
    }

    private func remoteVoicePicker(
        options: [RemoteVoiceOption],
        selectedID: String,
        fallbackName: String?,
        select: @escaping (RemoteVoiceOption) -> Void,
        reload: @escaping () -> Void
    ) -> some View {
        HStack {
            Picker("Voice", selection: Binding(
                get: { selectedID },
                set: { id in if let option = options.first(where: { $0.id == id }) { select(option) } }
            )) {
                if !selectedID.isEmpty, !options.contains(where: { $0.id == selectedID }) {
                    Text(fallbackName?.isEmpty == false ? fallbackName! : selectedID).tag(selectedID)
                }
                ForEach(options) { option in Text(option.title).tag(option.id) }
            }
            .accessibilityLabel("Cloud character voice")
            Button(action: reload) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Reload voices")
        }
    }

    private var modelSection: some View {
        studioSection(title: "Model") {
            if let modelRef = draft.modelRef {
                Picker("Provider", selection: Binding(
                    get: { modelRef.provider },
                    set: { requestModelProvider($0) }
                )) {
                    if !modelRef.provider.supportsSafePersonalityInference {
                        Text("\(modelRef.provider.title) (disabled)").tag(modelRef.provider)
                            .disabled(true)
                    }
                    ForEach(modelProviderOptions) {
                        Label($0.title, systemImage: modelProviderIcon($0)).tag($0)
                    }
                }
                .accessibilityLabel("Character model provider")

                HStack {
                    if modelOptions.isEmpty {
                        TextField("Model ID", text: Binding(
                            get: { draft.modelRef?.model ?? "" },
                            set: { value in selectDraftModel(value) }
                        ))
                        .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("Model", selection: Binding(
                            get: { draft.modelRef?.model ?? modelRef.provider.defaultModel },
                            set: { value in selectDraftModel(value) }
                        )) {
                            if !modelOptions.contains(where: { $0.id == modelRef.model }) {
                                Text("\(modelRef.model) (not installed)").tag(modelRef.model)
                            }
                            ForEach(modelOptions) { option in Text(option.title).tag(option.id) }
                        }
                    }
                    Button { loadDraftModels() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Load models")
                }

                if modelRef.provider.supportsReasoningEffort {
                    let reasoningOptions = draftReasoningOptions
                    if reasoningOptions.isEmpty {
                        HStack {
                            Text(modelRef.provider == .claudeCLI ? "Effort" : "Reasoning")
                            Spacer()
                            Text("This model does not advertise adjustable reasoning.")
                                .typoCaption()
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker(
                            modelRef.provider == .claudeCLI ? "Effort" : "Reasoning",
                            selection: Binding(
                                get: { normalizedDraftReasoning(in: reasoningOptions) },
                                set: { value in updateModel { $0.reasoningEffort = value } }
                            )
                        ) {
                            ForEach(reasoningOptions, id: \.self) { option in
                                Text(reasoningLabel(option, provider: modelRef.provider, options: reasoningOptions)).tag(option)
                            }
                        }
                        .accessibilityLabel("Character reasoning effort")
                        Text("Lower effort answers faster. Higher effort spends more time working through the response.")
                            .typoCaption()
                            .foregroundStyle(.secondary)
                    }
                }

                if !modelDiscoveryStatus.isEmpty {
                    Text(modelDiscoveryStatus).typoCaption().foregroundStyle(.secondary)
                }
                if !model.connectedTextProviders.contains(modelRef.provider) {
                    Label(
                        modelRef.provider.supportsSafePersonalityInference
                            ? "\(modelRef.provider.title) is not configured yet. This selection stays attached to the character, and safe fallback applies until Integrations is ready."
                            : "Codex subscription inference is disabled because Codex CLI cannot yet guarantee that native file-reading tools are off. Choose another provider before saving.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                        .typoCaption()
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Fallbacks").typoLabel(.medium)
                        Spacer()
                        if !fallbackProviderOptions.isEmpty {
                            Menu {
                                ForEach(fallbackProviderOptions) { provider in
                                    Button(provider.title) {
                                        updateModel { $0.fallbackProviders.append(provider) }
                                    }
                                }
                            } label: {
                                Label("Add", systemImage: "plus.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                    if modelRef.fallbackProviders.isEmpty {
                        Text("None. A model failure will ask you to choose another model.")
                            .typoCaption()
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(modelRef.fallbackProviders.enumerated()), id: \.element) { index, provider in
                            HStack(spacing: 7) {
                                Text("\(index + 1). \(provider.title)")
                                    .typoCaption(.medium)
                                if !provider.supportsSafePersonalityInference {
                                    Text("Disabled")
                                        .typoCaption(.medium)
                                        .foregroundStyle(.orange)
                                }
                                Spacer()
                                Button {
                                    updateModel { ref in
                                        guard index > 0 else { return }
                                        ref.fallbackProviders.swapAt(index, index - 1)
                                    }
                                } label: { Image(systemName: "chevron.up") }
                                    .buttonStyle(.plain)
                                    .disabled(index == 0)
                                    .accessibilityLabel("Move \(provider.title) earlier")
                                Button {
                                    updateModel { ref in
                                        guard index + 1 < ref.fallbackProviders.count else { return }
                                        ref.fallbackProviders.swapAt(index, index + 1)
                                    }
                                } label: { Image(systemName: "chevron.down") }
                                    .buttonStyle(.plain)
                                    .disabled(index == modelRef.fallbackProviders.count - 1)
                                    .accessibilityLabel("Move \(provider.title) later")
                                Button {
                                    updateModel { $0.fallbackProviders.removeAll { $0 == provider } }
                                } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Remove \(provider.title)")
                            }
                        }
                    }
                }
                .padding(9)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))

                Text("The preferred model and ordered fallbacks travel with this character. Attaché announces a live-call fallback once, then returns to the preferred model on the next call.")
                    .typoCaption()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var contextSection: some View {
        studioSection(title: "Context") {
            ContextStrategyEditor(
                strategyOverride: Binding(
                    get: { draft.contextStrategy },
                    set: { strategy in
                        draft.contextStrategy = strategy
                        draft.contextStrategyMigrationNotice = nil
                    }
                ),
                globalStrategy: contextUI.globalStrategy,
                allowsInheritance: true,
                capabilitySummary: draftCapabilitySummary,
                modelLabel: draft.modelSummary,
                capabilityNotice: draftCapabilityNotice,
                migrationNotice: draft.contextStrategyMigrationNotice,
                onDismissMigrationNotice: {
                    draft.contextStrategyMigrationNotice = nil
                },
                onRefreshCapabilities: loadDraftModels
            )
            Text("This character can inherit the app default or carry its own context policy. Model facts are detected separately and are never overwritten by Custom limits.")
                .typoCaption()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { closeStudio() }
                .keyboardShortcut(.cancelAction)
            Button(request.mode == .edit ? "Save character" : "Create character") {
                _ = model.savePersonality(draft, replacingID: request.replacingID)
                closeStudio()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
        }
    }

    private func closeStudio() {
        model.cancelPersonalityPreview()
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.voiceRef != nil
            && draftVoiceIsComplete
            && draft.modelRef?.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && draft.modelRef?.provider.supportsSafePersonalityInference == true
            && draft.modelRef?.fallbackProviders.allSatisfy(\.supportsSafePersonalityInference) == true
            && draftReasoningIsValid
            && (draft.contextStrategy?.isValidForSaving ?? true)
    }

    private var voiceEngineOptions: [AttacheSpeechProvider] {
        AttacheSpeechProvider.allCases
    }

    private var modelProviderOptions: [AttachePresentationProvider] {
        AttachePresentationProvider.personalityInferenceCases
    }

    private func requestVoiceProvider(_ provider: AttacheSpeechProvider) {
        previewAfterCloudVoiceConsent = false
        if provider.sendsToCloud,
           !model.cloudVoiceConsentAcknowledged(
               for: provider,
               xaiBaseURL: draftXAIBaseURL(for: provider)
           ) {
            pendingCloudVoice = provider
        } else {
            setVoiceProvider(provider)
        }
    }

    private func requestPersonalityPreview() {
        guard let provider = draft.voiceRef?.provider else { return }
        if provider.sendsToCloud,
           !model.cloudVoiceConsentAcknowledged(
               for: provider,
               xaiBaseURL: draftXAIBaseURL(for: provider)
           ) {
            previewAfterCloudVoiceConsent = true
            pendingCloudVoice = provider
            return
        }
        beginPersonalityPreview()
    }

    private func beginPersonalityPreview() {
        previewPreparing = true
        model.previewPersonality(draft) { greeting in
            previewText = greeting
            previewPreparing = false
        }
    }

    private func draftXAIBaseURL(for provider: AttacheSpeechProvider) -> String? {
        guard provider == .xai else { return nil }
        let imported = (draft.voiceRef?.xaiBaseURL ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return imported.isEmpty ? model.xaiBaseURL : imported
    }

    private func setVoiceProvider(_ provider: AttacheSpeechProvider) {
        var ref = model.currentPersonalityVoiceRef
        ref.provider = provider
        draft.voiceRef = ref
        loadRemoteVoicesIfNeeded()
    }

    private func updateVoice(_ change: (inout PersonalityVoiceRef) -> Void) {
        var ref = draft.voiceRef ?? model.currentPersonalityVoiceRef
        change(&ref)
        draft.voiceRef = ref
    }

    private func loadRemoteVoicesIfNeeded() {
        switch draft.voiceRef?.provider {
        case .elevenLabs: if model.elevenLabsVoiceOptions.isEmpty { model.loadElevenLabsVoices() }
        case .xai: if model.xaiVoiceOptions.isEmpty { model.loadXAIVoices() }
        case .openai: if model.openaiVoiceOptions.isEmpty { model.loadOpenAIVoices() }
        case .system, .none: break
        }
    }

    private func requestModelProvider(_ provider: AttachePresentationProvider) {
        if model.presentationProviderSendsToCloud(provider), !model.cloudConsentAcknowledged(for: provider) {
            pendingCloudModel = provider
        } else {
            setModelProvider(provider)
        }
    }

    private func setModelProvider(_ provider: AttachePresentationProvider) {
        let supported = AttachePresentationModelService.fallbackReasoningEfforts(
            provider: provider,
            modelID: provider.defaultModel
        )
        draft.modelRef = PersonalityModelRef(
            provider: provider,
            model: provider.defaultModel,
            reasoningEffort: supported.isEmpty
                ? nil
                : AttachePresentationModelService.preferredReasoningEffort(
                    provider: provider,
                    modelID: provider.defaultModel,
                    supported: supported
                ),
            serviceTier: provider.defaultServiceTier,
            fallbackProviders: (draft.modelRef?.fallbackProviders ?? []).filter {
                $0 != provider && $0.supportsSafePersonalityInference
            }
        )
        loadDraftModels()
    }

    private var fallbackProviderOptions: [AttachePresentationProvider] {
        guard let ref = draft.modelRef else { return [] }
        return AttachePresentationProvider.personalityInferenceCases.filter {
            $0 != ref.provider && !ref.fallbackProviders.contains($0)
        }
    }

    private func updateModel(_ change: (inout PersonalityModelRef) -> Void) {
        guard var ref = draft.modelRef else { return }
        change(&ref)
        draft.modelRef = ref
    }

    private var draftReasoningOptions: [String] {
        guard let ref = draft.modelRef else { return [] }
        let discovered = modelOptions.first(where: { $0.id == ref.model })?.reasoningEfforts ?? []
        let fallback = AttachePresentationModelService.fallbackReasoningEfforts(
            provider: ref.provider,
            modelID: ref.model
        )
        return modelOptions.contains(where: { $0.id == ref.model }) ? discovered : fallback
    }

    private var draftCapabilitySummary: AttacheCapabilitySummary {
        guard let ref = draft.modelRef else {
            return .from(detected: .unknown, override: draft.contextStrategy?.custom)
        }
        let exactOption = modelOptions.first(where: { $0.id == ref.model })
        let detected = exactOption?.capabilityProfile
            ?? AttachePresentationModelService.capabilityProfile(
                provider: ref.provider,
                baseURLText: model.endpointForIntegration(ref.provider),
                modelID: ref.model
            )
        return .from(detected: detected, override: draft.contextStrategy?.custom)
    }

    private var draftCapabilityNotice: String? {
        guard let ref = draft.modelRef,
              ref.provider == .ollama,
              !modelOptions.isEmpty,
              !modelOptions.contains(where: { $0.id == ref.model }) else {
            return nil
        }
        return "\(ref.model) is not installed on this Ollama server. Choose a listed model or install it, then refresh to inspect its capacity and reasoning support."
    }

    private func normalizedDraftReasoning(in options: [String]) -> String {
        guard let current = draft.modelRef?.reasoningEffort,
              options.contains(current) else {
            guard let ref = draft.modelRef else { return options.first ?? "none" }
            return AttachePresentationModelService.preferredReasoningEffort(
                provider: ref.provider,
                modelID: ref.model,
                supported: options
            )
        }
        return current
    }

    private func selectDraftModel(_ modelID: String) {
        updateModel { ref in
            ref.model = modelID
            let discovered = modelOptions.first(where: { $0.id == modelID })?.reasoningEfforts ?? []
            let options = discovered.isEmpty
                ? AttachePresentationModelService.fallbackReasoningEfforts(provider: ref.provider, modelID: modelID)
                : discovered
            if options.isEmpty {
                ref.reasoningEffort = nil
            } else if ref.reasoningEffort.map({ !options.contains($0) }) ?? true {
                ref.reasoningEffort = AttachePresentationModelService.preferredReasoningEffort(
                    provider: ref.provider,
                    modelID: modelID,
                    supported: options
                )
            }
        }
    }

    private func loadDraftModels() {
        guard let provider = draft.modelRef?.provider else {
            modelOptions = []
            modelDiscoveryStatus = ""
            return
        }
        guard provider.supportsSafePersonalityInference else {
            modelOptions = []
            modelDiscoveryStatus = "Codex subscription inference is disabled until its CLI can guarantee native file-reading tools are off."
            return
        }
        modelDiscoveryStatus = "Loading \(provider.title) models…"
        Task {
            do {
                let options = try await model.personalityModelOptions(for: provider)
                await MainActor.run {
                    guard draft.modelRef?.provider == provider else { return }
                    modelOptions = options
                    if let modelID = draft.modelRef?.model {
                        selectDraftModel(modelID)
                    }
                    modelDiscoveryStatus = options.isEmpty
                        ? "No models returned."
                        : "Loaded \(options.count) models. Reasoning is matched to the selected model."
                }
            } catch {
                await MainActor.run {
                    guard draft.modelRef?.provider == provider else { return }
                    modelOptions = []
                    modelDiscoveryStatus = "Could not load models. Enter a model ID or check Integrations."
                }
            }
        }
    }

    private var draftVoiceIsComplete: Bool {
        guard let voice = draft.voiceRef else { return false }
        switch voice.provider {
        case .system:
            return voice.systemVoiceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .elevenLabs:
            return voice.elevenLabsVoiceID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .xai:
            return voice.xaiVoiceID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .openai:
            return voice.openaiVoiceID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    private var draftReasoningIsValid: Bool {
        let options = draftReasoningOptions
        guard !options.isEmpty else {
            return draft.modelRef?.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }
        guard let effort = draft.modelRef?.reasoningEffort else { return false }
        return options.contains(effort)
    }

    private func modelProviderIcon(_ provider: AttachePresentationProvider) -> String {
        switch provider {
        case .xai: return "x.circle.fill"
        case .ollama: return "desktopcomputer"
        case .groq: return "bolt.fill"
        case .custom: return "point.3.connected.trianglepath.dotted"
        case .claudeCLI: return "terminal.fill"
        case .codexCLI: return "chevron.left.forwardslash.chevron.right"
        }
    }

    private func reasoningLabel(
        _ value: String,
        provider: AttachePresentationProvider,
        options: [String]
    ) -> String {
        if provider == .ollama, options == ["none", "high"] {
            return value == "none" ? "Off" : "On"
        }
        return value == "xhigh" ? "Extra high" : value.capitalized
    }

    @ViewBuilder private func studioSection<Content: View>(
        title: String,
        trailing: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).typoSection()
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
        .padding(14)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }
}

private enum WardrobeChoice: String, CaseIterable, Identifiable {
    case robot
    case cowboy
    case bars

    var id: String { rawValue }

    var title: String {
        switch self {
        case .robot: return "Attaché"
        case .cowboy: return "Colt"
        case .bars: return "Echo"
        }
    }

    var detail: String {
        switch self {
        case .robot: return "Robot"
        case .cowboy: return "Cowboy"
        case .bars: return "Voice only"
        }
    }

    var personalityPreview: Personality {
        switch self {
        case .robot:
            return Personality(id: "preview.robot", name: title, prompt: "", character: .robot, visualMode: .character)
        case .cowboy:
            return Personality(id: "preview.cowboy", name: title, prompt: "", character: .cowboy, visualMode: .character)
        case .bars:
            return Personality(id: "preview.bars", name: title, prompt: "", character: .robot, visualMode: .bars)
        }
    }

    func matches(_ personality: Personality) -> Bool {
        switch self {
        case .robot: return personality.visualMode != .bars && (personality.character ?? .robot) == .robot
        case .cowboy: return personality.visualMode != .bars && personality.character == .cowboy
        case .bars: return personality.visualMode == .bars
        }
    }

    func apply(to personality: inout Personality) {
        switch self {
        case .robot:
            personality.visualMode = .character
            personality.character = .robot
        case .cowboy:
            personality.visualMode = .character
            personality.character = .cowboy
        case .bars:
            personality.visualMode = .bars
            personality.character = nil
        }
    }
}

struct PersonalityPresencePreview: View {
    var personality: Personality
    var animatedBars: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.primary.opacity(0.035))
            if personality.visualMode == .bars {
                VoiceBarsCharacterPreview(animated: animatedBars)
                    .padding(22)
            } else {
                AttacheCharacterFigure(
                    pose: .neutral,
                    arcColor: .accentColor,
                    bodyColor: Color(nsColor: .labelColor),
                    anatomy: .head,
                    character: personality.character ?? .robot,
                    accentColor: Color(nsColor: .labelColor),
                    accentIsLight: false
                )
                .padding(8)
            }
        }
    }
}

struct VoiceBarsCharacterPreview: View {
    var animated: Bool
    @State private var breathing = false

    private let heights: [CGFloat] = [0.25, 0.42, 0.68, 0.9, 0.58, 0.82, 0.48, 0.3]

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: max(3, proxy.size.width * 0.025)) {
                ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.accentColor.opacity(0.45), .accentColor],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: proxy.size.height * height)
                        .scaleEffect(y: animated && breathing ? 0.72 + CGFloat(index % 3) * 0.1 : 1)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Echo voice bars presence")
    }
}

private struct CharacterDetailChip: View {
    var icon: String
    var text: String

    var body: some View {
        Label(text, systemImage: icon)
            .typoCaption(.medium)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.055), in: Capsule())
    }
}

private extension Personality {
    var creatorBlurb: String {
        switch id {
        case "builtin.bigPicture": return "Outcome first, always oriented."
        case "builtin.cowboy": return "Plainspoken, dry, and weathered."
        case "builtin.echo": return "Calm, crisp, and voice-forward."
        default: return "A starting point you can rewrite."
        }
    }
}
