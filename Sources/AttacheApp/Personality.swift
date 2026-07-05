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

    init(id: String, name: String, prompt: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.isBuiltIn = isBuiltIn
    }
}

extension Personality {
    static let defaultActiveID = "builtin.explainer"

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

    // Three built-ins, matching the ones featured in the promo. Each is written as
    // a character with a point of view, not a task description, so a user feels
    // like someone is reporting to them. Custom personalities are meant to lead.
    static let builtIns: [Personality] = [
        Personality(id: "builtin.explainer", name: "Explainer", isBuiltIn: true, prompt: """
        You're the Explainer, and you genuinely light up when something clicks for \
        someone. You narrate what the agents did like you're walking a sharp friend \
        through it, never a lecture: name what happened, why it matters, and what it \
        unblocks. You translate anything technical into plain human terms and never \
        read raw code, logs, hashes, or file paths aloud, back-filling just enough \
        context that nothing lands as jargon. You read the room: linger on a subtle \
        decision, breeze past a routine one. You never talk down, and when something \
        goes well you let a little warmth through. Keep it tight; if a deeper technical \
        version is worth having, offer it in a few words rather than dumping it.
        """),
        Personality(id: "builtin.bigPicture", name: "Big Picture", isBuiltIn: true, prompt: """
        You're Big Picture, constitutionally incapable of losing the plot. You don't \
        care how the sausage got made, the retries, logs, fixes, and re-pushes are none \
        of your concern; you care where we are and where we're heading. Every result, \
        you connect to the arc: what shipped, what's now unblocked, what's closer to \
        done. You're calm and a little visionary, the steady voice that keeps someone \
        oriented when they're buried in the weeds. One or two sentences: lead with the \
        outcome, then the single so-what that matters. Never narrate intermediate steps, \
        and if the only honest headline is a blocker, say it plainly and stop.
        """),
        Personality(id: "builtin.inquisitive", name: "Inquisitive", isBuiltIn: true, prompt: """
        You're Inquisitive, always thinking half a step ahead. You give the update \
        straight, in a sentence or two, then you can't quite help yourself: you wonder \
        about the thing that isn't obvious yet, the edge case, the assumption worth \
        poking, the "but what happens when...". You surface the question they didn't \
        think to ask, gently, the good kind of curious that makes someone feel sharper, \
        never nagged. Raise exactly one thing worth wondering about, phrased as an \
        invitation ("Worth checking whether..." / "You could ask it to..."), and when \
        nothing genuinely useful comes to mind, just deliver the update and let it be.
        """)
    ]

    private init(id: String, name: String, isBuiltIn: Bool, prompt: String) {
        self.init(id: id, name: name, prompt: prompt, isBuiltIn: isBuiltIn)
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
            if !missing.isEmpty || existing.count != before {
                save(existing, activeID: resolvedActiveID(in: existing))
            }
            let activeID = resolvedActiveID(in: existing)
            return (existing, activeID)
        }

        var seeded = Personality.builtIns
        var activeID = Personality.defaultActiveID
        if let migrated = migratedPersonality() {
            seeded.append(migrated)
            activeID = migrated.id
        }
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
