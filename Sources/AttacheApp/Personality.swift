import AttacheCore
import Foundation

/// A single, self-contained companion personality. One prompt defines tone,
/// attitude, level of detail, and language; the app adds the hidden functional
/// scaffolding (output format, "speak to the user", etc.) at presentation time.
struct Personality: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var prompt: String
    var isBuiltIn: Bool
    /// The engine + voice this personality speaks in. `nil` means "inherit the
    /// app's current global voice selection", which keeps lists persisted before
    /// personalities owned a voice working unchanged.
    var voiceRef: PersonalityVoiceRef?
    /// The pet character shown while this personality is active. `nil` renders
    /// the default robot (Attaché).
    var petCharacter: BubblesPetCharacter?
    /// Optional per-personality accent (hex), used by the switcher chip and the
    /// pet greeting. Non-load-bearing.
    var accentColorHex: String?

    init(
        id: String,
        name: String,
        prompt: String,
        isBuiltIn: Bool = false,
        voiceRef: PersonalityVoiceRef? = nil,
        petCharacter: BubblesPetCharacter? = nil,
        accentColorHex: String? = nil
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.isBuiltIn = isBuiltIn
        self.voiceRef = voiceRef
        self.petCharacter = petCharacter
        self.accentColorHex = accentColorHex
    }
}

extension Personality {
    static let defaultActiveID = "builtin.bigPicture"

    /// The Cowboy's preferred on-device voice: a low, weathered classic that
    /// reads like a trail boss. If it is not installed, voice resolution
    /// (`PersonalityVoiceRef.resolved(availableSystemVoiceIDs:)`) drops it and
    /// falls back to the app default rather than failing.
    static let cowboyPreferredVoiceID = "com.apple.speech.synthesis.voice.Fred"

    static let newTemplate = """
    Describe how Attaché should deliver updates: tone, attitude, level of detail, \
    and language. For example: \
    "Speak like a calm senior engineer. Two sentences max. Lead with the decision, \
    then the one risk that matters."
    """

    /// Built-ins retired in the personality slim-down; removed from lists
    /// persisted by older versions on next launch.
    static let retiredBuiltInIDs: Set<String> = [
        "builtin.conciseBrief", "builtin.balancedBrief", "builtin.actionCoach"
    ]

    // Four built-ins. Each is written as a character with a point of view, not a
    // task description, so a user feels like someone is reporting to them, and
    // each must read for any profession, never just developers. Custom
    // personalities are meant to lead.
    static let builtIns: [Personality] = [
        Personality(id: "builtin.explainer", name: "Explainer", isBuiltIn: true, petCharacter: .robot, prompt: """
        You're the Explainer, and you genuinely light up when something clicks for \
        someone. You narrate what the agents did like you're walking a sharp friend \
        through it, never a lecture: name what happened, why it matters, and what it \
        makes possible next. You translate anything technical or specialized into \
        plain human terms and never read raw codes, numbers, identifiers, or file \
        names aloud, back-filling just enough context that nothing lands as jargon. \
        You read the room: linger on a decision that actually matters, breeze past a \
        routine one. You never talk down, and when something goes well you let a \
        little warmth through. Keep it tight; if a deeper version is worth having, \
        offer it in a few words rather than dumping it.
        """),
        Personality(id: "builtin.bigPicture", name: "Big Picture", isBuiltIn: true, petCharacter: .robot, prompt: """
        You're Big Picture, constitutionally incapable of losing the plot. You don't \
        care how the work got done, the false starts, the back-and-forth, and the \
        redos are none of your concern; you care where things stand and where they're \
        heading. Every result, you connect to the arc: what's done, what's now \
        possible, what's closer to the goal. You're calm and a little visionary, the \
        steady voice that keeps someone oriented when they're buried in detail. One or \
        two sentences: lead with the outcome, then the single so-what that matters. \
        Never narrate the intermediate steps, and if the only honest headline is a \
        problem, say it plainly and stop.
        """),
        Personality(id: "builtin.inquisitive", name: "Inquisitive", isBuiltIn: true, petCharacter: .robot, prompt: """
        You're Inquisitive, always thinking half a step ahead. You give the update \
        straight, in a sentence or two, then you can't quite help yourself: you wonder \
        about the thing that isn't obvious yet, the edge case, the assumption worth \
        testing, the "but what happens when...". You surface the question they didn't \
        think to ask, gently, the good kind of curious that makes someone feel sharper, \
        never nagged. Raise exactly one thing worth wondering about, phrased as an \
        invitation ("Worth checking whether..." / "You might look at..."), and when \
        nothing genuinely useful comes to mind, just deliver the update and let it be.
        """),
        Personality(id: "builtin.cowboy", name: "Cowboy", isBuiltIn: true, petCharacter: .cowboy, voiceRef: .systemVoice(Personality.cowboyPreferredVoiceID), prompt: """
        You're the Cowboy, an old trail boss with a level voice and a lot of miles \
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
        """)
    ]

    private init(
        id: String,
        name: String,
        isBuiltIn: Bool,
        petCharacter: BubblesPetCharacter,
        voiceRef: PersonalityVoiceRef? = nil,
        prompt: String
    ) {
        self.init(
            id: id, name: name, prompt: prompt, isBuiltIn: isBuiltIn,
            voiceRef: voiceRef, petCharacter: petCharacter
        )
    }
}

/// Persists the personality list and the active selection in UserDefaults,
/// seeding the built-ins and migrating any existing custom persona on first run.
final class PersonalityStore {
    private let defaults: UserDefaults
    private let listKey = "attache.personalities"
    private let activeKey = "attache.activePersonalityID"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> (personalities: [Personality], activeID: String) {
        if var existing = decodeList(), !existing.isEmpty {
            // Drop retired built-ins, then merge in any new ones. User customs and
            // their order are preserved.
            let before = existing.count
            existing.removeAll { Personality.retiredBuiltInIDs.contains($0.id) }
            let known = Set(existing.map(\.id))
            let missing = Personality.builtIns.filter { !known.contains($0.id) }
            if !missing.isEmpty {
                let lastBuiltIn = existing.lastIndex(where: \.isBuiltIn).map { $0 + 1 } ?? existing.count
                existing.insert(contentsOf: missing, at: lastBuiltIn)
            }
            var activeID = resolvedActiveID(in: existing)
            var changed = !missing.isEmpty || existing.count != before
            if migrateVoiceAndPetIfNeeded(list: &existing, activeID: &activeID) { changed = true }
            if changed {
                save(existing, activeID: activeID)
            }
            return (existing, activeID)
        }

        var seeded = Personality.builtIns
        var activeID = Personality.defaultActiveID
        if let migrated = migratedPersonality() {
            seeded.append(migrated)
            activeID = migrated.id
        }
        _ = migrateVoiceAndPetIfNeeded(list: &seeded, activeID: &activeID)
        save(seeded, activeID: activeID)
        return (seeded, activeID)
    }

    func save(_ personalities: [Personality], activeID: String) {
        if let data = try? JSONEncoder().encode(personalities) {
            defaults.set(data, forKey: listKey)
        }
        defaults.set(activeID, forKey: activeKey)
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

    private let voicePetMigratedKey = "attache.personalityVoicePetMigrated"

    /// One-time upgrade for users whose voice and pet were separate global
    /// settings before personalities owned them. Folds the current global voice
    /// and pet into the active personality so nothing is lost, without ever
    /// overwriting a value the user already set or mutating a built-in's designed
    /// default. Runs exactly once, guarded by a defaults flag. Returns whether it
    /// changed the list or the active selection.
    private func migrateVoiceAndPetIfNeeded(list: inout [Personality], activeID: inout String) -> Bool {
        guard !defaults.bool(forKey: voicePetMigratedKey) else { return false }
        defaults.set(true, forKey: voicePetMigratedKey)

        let globalVoice = PersonalityVoiceRef.capture(from: defaults)
        let globalPet = defaults.string(forKey: CompanionPreferenceKey.petCharacter)
            .flatMap(BubblesPetCharacter.init(rawValue:))
        let voiceIsCustom = globalVoice.provider != .system || globalVoice.systemVoiceIdentifier != nil

        guard let index = list.firstIndex(where: { $0.id == activeID }) else { return false }
        let active = list[index]

        if active.isBuiltIn {
            // Preserve the user's exact prior setup as an owned, editable copy and
            // switch to it; leave the built-in's designed default untouched. Only
            // when they had actually customized voice or pet.
            let petDiffers = globalPet != nil && globalPet != active.petCharacter
            guard voiceIsCustom || petDiffers else { return false }
            let copy = Personality(
                id: "custom.migrated.\(active.id)",
                name: "My \(active.name)",
                prompt: active.prompt,
                isBuiltIn: false,
                voiceRef: voiceIsCustom ? globalVoice : active.voiceRef,
                petCharacter: globalPet ?? active.petCharacter
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
        if updated.petCharacter == nil, let globalPet {
            updated.petCharacter = globalPet
            changed = true
        }
        if changed { list[index] = updated }
        return changed
    }

    /// Preserves a persona the user defined before personalities existed (from the
    /// UserDefaults prompt key or the legacy CompanionPersonality.md file).
    private func migratedPersonality() -> Personality? {
        let baseline = CompanionPersonality.defaultProfilePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [
            defaults.string(forKey: CompanionPreferenceKey.personalityPrompt),
            try? String(contentsOf: CompanionAppSupport.supportDirectory()
                .appendingPathComponent("CompanionPersonality.md"), encoding: .utf8)
        ]
        for candidate in candidates {
            let trimmed = (candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != baseline {
                return Personality(id: "custom.migrated", name: "My Personality", prompt: trimmed)
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
    /// a built-in. Voice, pet, prompt, name, and accent are preserved.
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
