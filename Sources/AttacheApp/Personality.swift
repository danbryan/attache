import AttacheCore
import Foundation

/// The main text model a personality owns. Legacy `nil` values are filled from
/// the current app model when persistence loads. Advanced per-task model
/// overrides remain available internally for compatibility. The live
/// conversation fallback order belongs to the character, so switching
/// characters switches the complete model recovery policy too.
struct PersonalityModelRef: Codable, Equatable {
    var provider: AttachePresentationProvider
    var model: String
    var reasoningEffort: String?
    var serviceTier: String?
    var fallbackProviders: [AttachePresentationProvider]

    init(
        provider: AttachePresentationProvider,
        model: String,
        reasoningEffort: String? = nil,
        serviceTier: String? = nil,
        fallbackProviders: [AttachePresentationProvider] = []
    ) {
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.fallbackProviders = fallbackProviders.filter { $0 != provider }
    }

    private enum CodingKeys: String, CodingKey {
        case provider, model, reasoningEffort, serviceTier, fallbackProviders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawProvider = try container.decode(String.self, forKey: .provider)
        let legacyLMStudio = AttachePresentationProvider.isLegacyLMStudio(
            explicitValue: rawProvider,
            baseURLText: nil
        )
        if legacyLMStudio {
            provider = .ollama
            model = AttachePresentationProvider.ollama.defaultModel
            reasoningEffort = AttachePresentationProvider.ollama.defaultReasoningEffort
            serviceTier = nil
            fallbackProviders = []
            return
        }
        let decodedProvider: AttachePresentationProvider
        if let known = AttachePresentationProvider(rawValue: rawProvider) {
            decodedProvider = known
        } else if ["groq", "groq_llm", "groq-llm"].contains(rawProvider) {
            // The Groq presentation provider was retired (INF-388). It was a
            // hosted OpenAI-compatible endpoint, so a personality stored with
            // it falls back to Custom rather than making the file unreadable.
            decodedProvider = .custom
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .provider,
                in: container,
                debugDescription: "Unknown presentation provider \(rawProvider)"
            )
        }
        provider = decodedProvider
        model = try container.decode(String.self, forKey: .model)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        serviceTier = try container.decodeIfPresent(String.self, forKey: .serviceTier)
        fallbackProviders = try container.decodeIfPresent(
            [AttachePresentationProvider].self,
            forKey: .fallbackProviders
        ) ?? []
        fallbackProviders.removeAll { $0 == provider }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider.rawValue, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(serviceTier, forKey: .serviceTier)
        try container.encode(fallbackProviders, forKey: .fallbackProviders)
    }

    static func capture(from defaults: UserDefaults) -> PersonalityModelRef {
        let explicitProvider = defaults.string(forKey: AttachePreferenceKey.presentationLLMProvider)
        let baseURL = defaults.string(forKey: AttachePreferenceKey.presentationLLMBaseURL)
        let legacyLMStudio = AttachePresentationProvider.isLegacyLMStudio(
            explicitValue: explicitProvider,
            baseURLText: baseURL
        )
        let provider = AttachePresentationProvider.from(
            explicitValue: explicitProvider,
            baseURLText: baseURL
        )
        let savedModel = defaults.string(forKey: AttachePreferenceKey.presentationLLMModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = legacyLMStudio || savedModel.isEmpty ? provider.defaultModel : savedModel
        let effort = defaults.string(forKey: AttachePreferenceKey.presentationReasoningEffort)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tier = defaults.string(forKey: AttachePreferenceKey.presentationServiceTier)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackProviders = ((defaults.array(
            forKey: AttachePreferenceKey.conversationFallbackChainProviders
        ) as? [String]) ?? []).compactMap(AttachePresentationProvider.init(rawValue:))
        return PersonalityModelRef(
            provider: provider,
            model: model,
            reasoningEffort: provider.supportsReasoningEffort
                ? (effort?.isEmpty == false ? effort : provider.defaultReasoningEffort)
                : nil,
            serviceTier: provider.supportsServiceTier && tier?.isEmpty == false ? tier : nil,
            fallbackProviders: defaults.bool(
                forKey: AttachePreferenceKey.conversationFallbackChainEnabled
            ) ? fallbackProviders : []
        )
    }
}

/// A single, self-contained Attaché personality. One prompt defines tone,
/// attitude, level of detail, and language; the app adds the hidden functional
/// scaffolding (output format, "speak to the user", etc.) at presentation time.
struct Personality: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var prompt: String
    var isBuiltIn: Bool
    /// The engine + voice this personality speaks in. Persistence migration fills
    /// legacy `nil` values so every user-facing personality owns an explicit voice.
    var voiceRef: PersonalityVoiceRef?
    /// The character shown while this personality is active. `nil` renders
    /// the default robot (Attaché).
    var character: AttacheCharacter?
    /// The complete visual presence. `.character` renders `character`; `.bars`
    /// keeps the original abstract voice-bars presence with no character. `nil`
    /// is the migration-compatible "keep the current app visual" behavior.
    var visualMode: AttacheVisualMode?
    /// The preferred main text model. Persistence migration fills a legacy `nil`.
    /// Its ordered fallback providers travel with the personality. Advanced
    /// per-task overrides remain separate recovery policy.
    var modelRef: PersonalityModelRef?
    /// Playback pace is part of the character's voice performance. Legacy
    /// personalities are filled from the previous app-wide playback setting.
    var playbackSpeed: Double?
    /// Optional per-personality accent (hex), used by the switcher chip and the
    /// character greeting. Non-load-bearing.
    var accentColorHex: String?
    /// Optional per-personality context strategy override (INF-305). A
    /// personality references policy; it does not duplicate mutable detected
    /// capability facts. `nil` means fall back to the global default strategy.
    var contextStrategy: AttacheContextStrategy?
    /// A visible, non-blocking explanation when an older Custom strategy could
    /// not be recovered safely. The invalid values are never applied silently.
    var contextStrategyMigrationNotice: String?
    /// Per-personality MCP tool grants (INF-373), keyed by namespaced tool name
    /// (`mcp__server__tool`). Servers are shared app-wide; capability is not.
    /// A missing key (and a legacy personality without the field) decodes as
    /// empty, i.e. every tool defaults to Not offered.
    var mcpToolGrants: MCPToolGrants

    init(
        id: String,
        name: String,
        prompt: String,
        isBuiltIn: Bool = false,
        voiceRef: PersonalityVoiceRef? = nil,
        character: AttacheCharacter? = nil,
        visualMode: AttacheVisualMode? = nil,
        modelRef: PersonalityModelRef? = nil,
        playbackSpeed: Double? = nil,
        accentColorHex: String? = nil,
        contextStrategy: AttacheContextStrategy? = nil,
        contextStrategyMigrationNotice: String? = nil,
        mcpToolGrants: MCPToolGrants = [:]
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.isBuiltIn = isBuiltIn
        self.voiceRef = voiceRef
        self.character = character
        self.visualMode = visualMode
        self.modelRef = modelRef
        self.playbackSpeed = playbackSpeed
        self.accentColorHex = accentColorHex
        self.contextStrategy = contextStrategy
        self.contextStrategyMigrationNotice = contextStrategyMigrationNotice
        self.mcpToolGrants = mcpToolGrants
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, prompt, isBuiltIn, voiceRef, character, visualMode
        case modelRef, playbackSpeed, accentColorHex, contextStrategy
        case contextStrategyMigrationNotice, mcpToolGrants
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        prompt = try container.decode(String.self, forKey: .prompt)
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        voiceRef = try container.decodeIfPresent(PersonalityVoiceRef.self, forKey: .voiceRef)
        character = try container.decodeIfPresent(AttacheCharacter.self, forKey: .character)
        visualMode = try container.decodeIfPresent(AttacheVisualMode.self, forKey: .visualMode)
        modelRef = try container.decodeIfPresent(PersonalityModelRef.self, forKey: .modelRef)
        playbackSpeed = try container.decodeIfPresent(Double.self, forKey: .playbackSpeed)
        accentColorHex = try container.decodeIfPresent(String.self, forKey: .accentColorHex)
        mcpToolGrants = try container.decodeIfPresent(MCPToolGrants.self, forKey: .mcpToolGrants) ?? [:]
        let decodedContextStrategy = try container.decodeIfPresent(
            AttacheContextStrategy.self,
            forKey: .contextStrategy
        )
        let decodedMigrationNotice = try container.decodeIfPresent(
            String.self,
            forKey: .contextStrategyMigrationNotice
        )
        if let decodedContextStrategy, !Self.contextStrategyIsValid(decodedContextStrategy) {
            contextStrategy = nil
            contextStrategyMigrationNotice = decodedMigrationNotice
                ?? "This Attaché had an incomplete Custom context profile. Attaché restored the app default so unsafe limits are never applied silently."
        } else {
            contextStrategy = decodedContextStrategy
            contextStrategyMigrationNotice = decodedMigrationNotice
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(isBuiltIn, forKey: .isBuiltIn)
        try container.encodeIfPresent(voiceRef, forKey: .voiceRef)
        try container.encodeIfPresent(character, forKey: .character)
        try container.encodeIfPresent(visualMode, forKey: .visualMode)
        try container.encodeIfPresent(modelRef, forKey: .modelRef)
        try container.encodeIfPresent(playbackSpeed, forKey: .playbackSpeed)
        try container.encodeIfPresent(accentColorHex, forKey: .accentColorHex)
        if !mcpToolGrants.isEmpty {
            try container.encode(mcpToolGrants, forKey: .mcpToolGrants)
        }
        try container.encodeIfPresent(contextStrategy, forKey: .contextStrategy)
        try container.encodeIfPresent(
            contextStrategyMigrationNotice,
            forKey: .contextStrategyMigrationNotice
        )
    }

    private static func contextStrategyIsValid(_ strategy: AttacheContextStrategy) -> Bool {
        guard strategy.kind == .custom else { return true }
        guard let custom = strategy.custom else { return false }
        do {
            try custom.validate()
            return true
        } catch {
            return false
        }
    }
}

extension Personality {
    /// Create a user-owned copy without dropping any part of the character's
    /// loadout. In particular, nil still means “inherit the app context
    /// strategy,” while every named or valid Custom override is preserved.
    func duplicated(withID id: String, name: String? = nil) -> Personality {
        Personality(
            id: id,
            name: name ?? "\(self.name) Copy",
            prompt: prompt,
            isBuiltIn: false,
            voiceRef: voiceRef,
            character: character,
            visualMode: visualMode,
            modelRef: modelRef,
            playbackSpeed: playbackSpeed,
            accentColorHex: accentColorHex,
            contextStrategy: contextStrategy,
            contextStrategyMigrationNotice: contextStrategyMigrationNotice,
            mcpToolGrants: mcpToolGrants
        )
    }

    static let defaultActiveID = "builtin.bigPicture"

    /// Retained for migrating personalities that stored the old cowboy voice;
    /// built-ins now default to the Attaché Premium voice (2026-07-18, INF-379
    /// follow-up), falling back to the system voice until weights install.
    static let cowboyPreferredVoiceID = "com.apple.speech.synthesis.voice.Fred"
    static let defaultPreferredVoiceID = "com.apple.speech.synthesis.voice.Alex"

    static let newTemplate = """
    Describe how Attaché should deliver updates: tone, attitude, level of detail, \
    and language. For example: \
    "Speak like a calm senior engineer. Two sentences max. Lead with the decision, \
    then the one risk that matters."
    """

    /// Built-ins retired in the personality slim-down; removed from lists
    /// persisted by older versions on next launch. Big Picture and Cowboy keep
    /// their stable ids because they became Attaché and Colt respectively.
    static let retiredBuiltInIDs: Set<String> = [
        "builtin.conciseBrief", "builtin.balancedBrief", "builtin.actionCoach",
        "builtin.explainer", "builtin.inquisitive"
    ]

    // Three complete defaults, organized around the presence a person chooses:
    // Attaché the robot, Colt the cowboy, or Echo's character-free voice bars. Each
    // reads for any profession, never just developers.
    static let builtIns: [Personality] = [
        Personality(id: "builtin.bigPicture", name: "Attaché", isBuiltIn: true, character: .robot, visualMode: .character, voiceRef: PersonalityVoiceRef(provider: .attachePremium), prompt: """
        You're Attaché, constitutionally incapable of losing the plot. You don't \
        care how the work got done, the false starts, the back-and-forth, and the \
        redos are none of your concern; you care where things stand and where they're \
        heading. Every result, you connect to the arc: what's done, what's now \
        possible, what's closer to the goal. You're calm and a little visionary, the \
        steady voice that keeps someone oriented when they're buried in detail. One or \
        two sentences: lead with the outcome, then the single so-what that matters. \
        Never narrate the intermediate steps, and if the only honest headline is a \
        problem, say it plainly and stop.
        """),
        Personality(id: "builtin.cowboy", name: "Colt", isBuiltIn: true, character: .cowboy, visualMode: .character, voiceRef: PersonalityVoiceRef(provider: .attachePremium), prompt: """
        You're Colt, an old trail boss with a level voice and a lot of miles \
        behind you, and these agents are your herd. You talk plain and easy with a \
        little dust on your words: reckon, y'all, ain't, "hold your horses", "riding \
        point", sprinkled where they land natural, never so thick they slow the \
        telling. You're no museum piece: models, ledgers, lab results, contracts, \
        none of it spooks you; you just speak of it like ranch work, wrangling \
        strays, mending fences, counting the herd through the gate, and you never \
        dodge a modern question just to stay in character. Deliver the news like \
        you're leaning on the corral rail at sundown: what got done, whether it'll \
        hold, and what needs riding out at first light. Dry wit, big heart. When the \
        work went well you tip your hat in a word or two; when it went sideways you \
        say so straight, no sugar on it, then point at the path through. Keep it to \
        a couple sentences, partner. Nobody ever drove a herd faster by hollering \
        longer.
        """),
        Personality(
            id: "builtin.echo",
            name: "Echo",
            prompt: """
            You're Echo, a calm voice in the room rather than a character asking for \
            attention. You make agent work easy to absorb without flattening what \
            matters: lead with the result, translate specialized language into plain \
            speech, and name one consequence or next move only when it is useful. You \
            sound warm, modern, and lightly conversational, never robotic and never \
            theatrical. Do not refer to having a face, body, character, or costume. Keep \
            routine updates to one or two crisp sentences and let silence do the rest.
            """,
            isBuiltIn: true,
            voiceRef: PersonalityVoiceRef(provider: .attachePremium),
            character: nil,
            visualMode: .bars,
            modelRef: nil,
            playbackSpeed: 1.0
        )
    ]

    private init(
        id: String,
        name: String,
        isBuiltIn: Bool,
        character: AttacheCharacter,
        visualMode: AttacheVisualMode,
        voiceRef: PersonalityVoiceRef? = .systemVoice(Personality.defaultPreferredVoiceID),
        prompt: String
    ) {
        self.init(
            id: id, name: name, prompt: prompt, isBuiltIn: isBuiltIn,
            voiceRef: voiceRef,
            character: character,
            visualMode: visualMode,
            // Built-ins ship only presence, prompt, and voice. The model is
            // inherited from whatever the user actually connects; a nil modelRef
            // is filled from their configuration for customs, and displayed live
            // for built-ins (never a hardcoded assumption). See Decisions of
            // Record and AppModel.displayModelSummary(for:).
            modelRef: nil,
            playbackSpeed: 1.0
        )
    }
}

extension Personality {
    /// A short, human label for this personality's voice, for list rows and the
    /// editor. Never surfaces provider internals like a raw voice id.
    ///
    /// Takes an already-computed system voice options list (e.g.
    /// `AppModel.speechVoiceOptions`) rather than calling
    /// `AttacheVoiceCatalog.options()` itself, which re-filters and re-sorts
    /// the whole catalog on every call. Character cards recompute this on
    /// every render, so a fresh catalog call there was the largest avoidable
    /// per-render cost in the personality list (INF-352 step 6). Callers with
    /// no options handy (e.g. a personality known not to use a system voice)
    /// can pass an empty array; only the `.system` branch consults it.
    func voiceSummary(in systemOptions: [AttacheVoiceOption]) -> String {
        guard let ref = voiceRef else { return "Voice not set" }
        switch ref.provider {
        case .system:
            guard let identifier = ref.systemVoiceIdentifier else { return "Voice not set" }
            return systemOptions.first(where: { $0.id == identifier })?.title ?? identifier
        case .attachePremium:
            return "Azelma (Premium)"
        case .elevenLabs:
            return "ElevenLabs" + (ref.elevenLabsVoiceName.map { ": \($0)" } ?? " voice")
        case .xai:
            return "xAI" + (ref.xaiVoiceName.map { ": \($0)" } ?? " voice")
        case .openai:
            return "OpenAI" + (ref.openaiVoiceName.map { ": \($0)" } ?? " voice")
        }
    }

    /// The character avatar emoji shown in list rows (🤖 default / 🤠 Colt).
    var characterAvatarEmoji: String {
        if visualMode == .bars { return "🎙️" }
        return (character ?? .robot).avatarEmoji
    }

    var presenceSummary: String {
        switch visualMode {
        case .bars: return "Echo voice bars"
        case .character, .none: return (character ?? .robot).title
        }
    }

    var modelSummary: String {
        guard let modelRef else { return "Uses your connected model" }
        let effort = (modelRef.reasoningEffort ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = ["", "default", "none"].contains(effort.lowercased())
            ? ""
            : " · \(effort.capitalized)"
        return "\(modelRef.provider.title) · \(modelRef.model)\(suffix)"
    }
}

/// Persists the personality list and the active selection in UserDefaults,
/// seeding the built-ins and migrating any existing custom persona on first run.
final class PersonalityStore {
    private let defaults: UserDefaults
    private let listKey = "attache.personalities"
    private let activeKey = "attache.activePersonalityID"
    /// Persisted ids of built-in personalities the user deleted. A tombstoned
    /// built-in is never re-seeded by `load()`; deleting one records the id and
    /// undo (or Restore defaults) removes it. Lives in the same defaults suite.
    private let deletedBuiltInsKey = "attache.deletedBuiltInPersonalityIDs"
    /// Supplies the voice list `fillingExplicitConfiguration` validates
    /// system voice references against. Defaults to the shared voice
    /// catalog's already-loaded snapshot (never a fresh enumeration, see
    /// INF-350) but is injectable so tests never touch real voice
    /// enumeration and can exercise the empty-snapshot backfill path.
    private let voiceOptionsProvider: () -> [AttacheVoiceOption]

    init(defaults: UserDefaults = .standard,
         voiceOptionsProvider: @escaping () -> [AttacheVoiceOption] = { AttacheVoiceCatalog.options() }) {
        self.defaults = defaults
        self.voiceOptionsProvider = voiceOptionsProvider
    }

    func load() -> (personalities: [Personality], activeID: String) {
        if var existing = decodeList(), !existing.isEmpty {
            // Drop retired built-ins, then merge in any new ones. User customs and
            // their order are preserved.
            let before = existing.count
            existing.removeAll { Personality.retiredBuiltInIDs.contains($0.id) }
            let known = Set(existing.map(\.id))
            let tombstoned = deletedBuiltInIDs()
            let missing = Personality.builtIns
                .filter { !known.contains($0.id) && !tombstoned.contains($0.id) }
                .map(fillingExplicitConfiguration)
            if !missing.isEmpty {
                let lastBuiltIn = existing.lastIndex(where: \.isBuiltIn).map { $0 + 1 } ?? existing.count
                existing.insert(contentsOf: missing, at: lastBuiltIn)
            }
            // Big Picture and Cowboy kept stable ids while becoming Attaché and
            // Colt. Refresh built-in identity text to the canonical version while
            // preserving user-owned voice/model choices and every custom entry.
            var canonicalizedBuiltIns = false
            for index in existing.indices where existing[index].isBuiltIn {
                if let canonical = Personality.builtIns.first(where: { $0.id == existing[index].id }) {
                    if existing[index].name != canonical.name {
                        existing[index].name = canonical.name
                        canonicalizedBuiltIns = true
                    }
                    if existing[index].prompt != canonical.prompt {
                        existing[index].prompt = canonical.prompt
                        canonicalizedBuiltIns = true
                    }
                    if existing[index].character == nil, canonical.character != nil {
                        existing[index].character = canonical.character
                        canonicalizedBuiltIns = true
                    }
                    if existing[index].voiceRef == nil, canonical.voiceRef != nil {
                        existing[index].voiceRef = canonical.voiceRef
                        canonicalizedBuiltIns = true
                    }
                    if existing[index].visualMode == nil {
                    existing[index].visualMode = canonical.visualMode
                        canonicalizedBuiltIns = true
                    }
                }
            }

            for index in existing.indices {
                let configured = fillingExplicitConfiguration(existing[index])
                if configured != existing[index] {
                    existing[index] = configured
                    canonicalizedBuiltIns = true
                }
            }

            var activeID = resolvedActiveID(in: existing)
            var changed = !missing.isEmpty || existing.count != before || canonicalizedBuiltIns
            if migrateVoiceAndCharacterIfNeeded(list: &existing, activeID: &activeID) { changed = true }
            if changed {
                save(existing, activeID: activeID)
            }
            return (existing, activeID)
        }

        let tombstoned = deletedBuiltInIDs()
        var seeded = Personality.builtIns
            .filter { !tombstoned.contains($0.id) }
            .map(fillingExplicitConfiguration)
        var activeID = seeded.first?.id ?? Personality.defaultActiveID
        if let migrated = migratedPersonality() {
            seeded.append(migrated)
            activeID = migrated.id
        }
        _ = migrateVoiceAndCharacterIfNeeded(list: &seeded, activeID: &activeID)
        save(seeded, activeID: activeID)
        return (seeded, activeID)
    }

    /// Re-validates every personality's system voice reference against the
    /// current voice list. `load()` may have run before the voice catalog's
    /// background scan published real voices (INF-350: a first launch with
    /// no disk snapshot starts with an empty options list rather than
    /// blocking on enumeration), leaving system-voice personalities on the
    /// generic fallback ID. Call this once the catalog's `onUpdate` fires so
    /// those personalities pick up the user's actual system voice. Pure and
    /// idempotent; the caller decides whether the result differs enough to
    /// persist.
    func reconcilingVoiceReferences(_ personalities: [Personality]) -> [Personality] {
        personalities.map(fillingExplicitConfiguration)
    }

    func save(_ personalities: [Personality], activeID: String) {
        if let data = try? JSONEncoder().encode(personalities) {
            defaults.set(data, forKey: listKey)
        }
        defaults.set(activeID, forKey: activeKey)
    }

    /// The ids of built-in personalities the user has deleted. `load()` will not
    /// re-seed any id in this set.
    func deletedBuiltInIDs() -> Set<String> {
        Set((defaults.array(forKey: deletedBuiltInsKey) as? [String]) ?? [])
    }

    /// Whether any built-in is currently tombstoned. Drives the "Restore default
    /// personalities" affordance, which is hidden while this is false.
    var hasDeletedBuiltIns: Bool { !deletedBuiltInIDs().isEmpty }

    private func writeDeletedBuiltInIDs(_ ids: Set<String>) {
        if ids.isEmpty {
            defaults.removeObject(forKey: deletedBuiltInsKey)
        } else {
            defaults.set(ids.sorted(), forKey: deletedBuiltInsKey)
        }
    }

    /// Record that a built-in was deleted so it is not re-seeded on the next
    /// load. A no-op for ids that are not built-ins.
    func recordDeletedBuiltIn(_ id: String) {
        guard Personality.builtIns.contains(where: { $0.id == id }) else { return }
        var ids = deletedBuiltInIDs()
        ids.insert(id)
        writeDeletedBuiltInIDs(ids)
    }

    /// Undo a single built-in deletion by clearing its tombstone.
    func clearDeletedBuiltIn(_ id: String) {
        var ids = deletedBuiltInIDs()
        guard ids.remove(id) != nil else { return }
        writeDeletedBuiltInIDs(ids)
    }

    /// Clear every built-in tombstone and re-add any missing built-ins in
    /// canonical form. The re-add mirrors `load()`'s merge (fresh explicit
    /// configuration, built-ins ahead of customs) so a restored set matches a
    /// never-deleted one. Returns the merged list; the caller persists it.
    func restoringDefaultBuiltIns(into existing: [Personality]) -> [Personality] {
        writeDeletedBuiltInIDs([])
        let known = Set(existing.map(\.id))
        let missing = Personality.builtIns
            .filter { !known.contains($0.id) }
            .map(fillingExplicitConfiguration)
        guard !missing.isEmpty else { return existing }
        var result = existing
        let insertAt = result.lastIndex(where: \.isBuiltIn).map { $0 + 1 } ?? 0
        result.insert(contentsOf: missing, at: insertAt)
        return result
    }

    private func decodeList() -> [Personality]? {
        guard let data = defaults.data(forKey: listKey) else { return nil }
        return try? JSONDecoder().decode([Personality].self, from: data)
    }

    private func resolvedActiveID(in list: [Personality]) -> String {
        let stored = defaults.string(forKey: activeKey) ?? ""
        if list.contains(where: { $0.id == stored }) { return stored }
        return list.first?.id ?? Personality.defaultActiveID
    }

    // Keep the original persisted key so users who already completed this
    // one-time migration never repeat it after the terminology cleanup.
    private let voiceCharacterMigratedKey = "attache.personalityVoicePetMigrated"

    private func fillingExplicitConfiguration(_ personality: Personality) -> Personality {
        var configured = personality
        if configured.voiceRef == nil {
            configured.voiceRef = PersonalityVoiceRef.capture(from: defaults)
        }
        if var voice = configured.voiceRef, voice.provider == .system {
            let voiceOptions = voiceOptionsProvider()
            let available = Set(voiceOptions.map(\.id))
            if voice.systemVoiceIdentifier.map({ !available.contains($0) }) ?? true {
                voice.systemVoiceIdentifier = AttacheVoiceCatalog.fileExportFallbackVoiceID(in: voiceOptions)
                    ?? Personality.defaultPreferredVoiceID
                configured.voiceRef = voice
            }
        }
        // Built-ins deliberately carry no model: they inherit whatever the user
        // connects, shown live by AppModel.displayModelSummary(for:). Only legacy
        // custom personalities (which stored a concrete model before this change)
        // get their missing model filled from the current configuration.
        if configured.modelRef == nil, !configured.isBuiltIn {
            configured.modelRef = PersonalityModelRef.capture(from: defaults)
        }
        if configured.playbackSpeed == nil {
            let legacy = defaults.object(forKey: AttachePreferenceKey.playbackSpeed) == nil
                ? 1.0
                : defaults.double(forKey: AttachePreferenceKey.playbackSpeed)
            configured.playbackSpeed = min(1.6, max(0.8, legacy))
        }
        if configured.visualMode == nil {
            configured.visualMode = .character
        }
        return configured
    }

    /// One-time upgrade for users whose voice and character were separate global
    /// settings before personalities owned them. Folds the current global voice
    /// and character into the active personality so nothing is lost, without ever
    /// overwriting a value the user already set or mutating a built-in's designed
    /// default. Runs exactly once, guarded by a defaults flag. Returns whether it
    /// changed the list or the active selection.
    private func migrateVoiceAndCharacterIfNeeded(list: inout [Personality], activeID: inout String) -> Bool {
        guard !defaults.bool(forKey: voiceCharacterMigratedKey) else { return false }
        defaults.set(true, forKey: voiceCharacterMigratedKey)

        // Only a profile that finished onboarding before this store first
        // loaded can hold a pre-unification setup worth preserving. On a
        // fresh or freshly-reset profile the store loads while onboarding is
        // still in progress, and any custom global voice was written moments
        // ago by onboarding itself; cloning it would fabricate a phantom
        // "My <name>" personality out of the user's own picks.
        guard defaults.bool(forKey: AttachePreferenceKey.onboardingCompleted) else { return false }

        let globalVoice = PersonalityVoiceRef.capture(from: defaults)
        let globalCharacter = defaults.string(forKey: AttachePreferenceKey.character)
            .flatMap(AttacheCharacter.init(rawValue:))
        let voiceIsCustom = globalVoice.provider != .system || globalVoice.systemVoiceIdentifier != nil

        guard let index = list.firstIndex(where: { $0.id == activeID }) else { return false }
        let active = list[index]

        if active.isBuiltIn {
            // Preserve the user's exact prior setup as an owned, editable copy and
            // switch to it; leave the built-in's designed default untouched. Only
            // when they had actually customized voice or character.
            let characterDiffers = globalCharacter != nil && globalCharacter != active.character
            guard voiceIsCustom || characterDiffers else { return false }
            let copy = Personality(
                id: "custom.migrated.\(active.id)",
                name: "My \(active.name)",
                prompt: active.prompt,
                isBuiltIn: false,
                voiceRef: voiceIsCustom ? globalVoice : active.voiceRef,
                character: globalCharacter ?? active.character,
                visualMode: active.visualMode,
                modelRef: active.modelRef,
                playbackSpeed: active.playbackSpeed,
                accentColorHex: active.accentColorHex
            )
            let insertAt = list.lastIndex(where: \.isBuiltIn).map { $0 + 1 } ?? list.count
            list.insert(copy, at: insertAt)
            activeID = copy.id
            return true
        }

        var updated = active
        var changed = false
        if updated.voiceRef == nil {
            updated.voiceRef = globalVoice
            changed = true
        }
        if updated.character == nil, let globalCharacter {
            updated.character = globalCharacter
            changed = true
        }
        if changed { list[index] = updated }
        return changed
    }

    /// Preserves a persona the user defined before personalities existed (from the
    /// UserDefaults prompt key or the legacy AttachePersonality.md file).
    private func migratedPersonality() -> Personality? {
        let baseline = AttachePersonality.defaultProfilePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [
            defaults.string(forKey: AttachePreferenceKey.personalityPrompt),
            try? String(contentsOf: AttacheAppSupport.supportDirectory()
                .appendingPathComponent("AttachePersonality.md"), encoding: .utf8)
        ]
        for candidate in candidates {
            let trimmed = (candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != baseline {
                return fillingExplicitConfiguration(
                    Personality(id: "custom.migrated", name: "My Personality", prompt: trimmed)
                )
            }
        }
        return nil
    }
}

extension PersonalityStore {
    /// Export a single personality as pretty JSON. This is the interchange format
    /// for import and export, mirroring the custom-themes registry.
    static func exportData(_ personality: Personality) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(personality)
    }

    /// Decode an imported personality, giving it a fresh id and clearing the
    /// built-in flag so an import never clobbers an existing entry or impersonates
    /// a built-in. Voice, character, prompt, name, and accent are preserved.
    static func importPersonality(
        from data: Data,
        newID: () -> String = { "custom.\(UUID().uuidString.prefix(8))" }
    ) throws -> Personality {
        var decoded = try JSONDecoder().decode(Personality.self, from: data)
        decoded.id = newID()
        decoded.isBuiltIn = false
        return decoded
    }
}
