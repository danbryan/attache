import Foundation

/// A personality's bundled voice selection: which engine, which voice, and the
/// provider-specific fields needed to actually speak. It mirrors the app's
/// global speech `CompanionPreferenceKey`s so a personality can carry its own
/// voice instead of every personality sharing one global setting.
///
/// A `nil` `PersonalityVoiceRef` on a `Personality` means "inherit the current
/// global voice". A ref with `provider == .system` and a `nil`
/// `systemVoiceIdentifier` means "the app default on-device voice".
struct PersonalityVoiceRef: Codable, Equatable {
    var provider: CompanionSpeechProvider
    var systemVoiceIdentifier: String?
    var elevenLabsVoiceID: String?
    var elevenLabsVoiceName: String?
    var elevenLabsModelID: String?
    var elevenLabsOutputFormat: String?
    var xaiVoiceID: String?
    var xaiVoiceName: String?
    var xaiBaseURL: String?
    var xaiLanguage: String?
    var openaiVoiceID: String?
    var openaiVoiceName: String?

    init(
        provider: CompanionSpeechProvider = .system,
        systemVoiceIdentifier: String? = nil,
        elevenLabsVoiceID: String? = nil,
        elevenLabsVoiceName: String? = nil,
        elevenLabsModelID: String? = nil,
        elevenLabsOutputFormat: String? = nil,
        xaiVoiceID: String? = nil,
        xaiVoiceName: String? = nil,
        xaiBaseURL: String? = nil,
        xaiLanguage: String? = nil,
        openaiVoiceID: String? = nil,
        openaiVoiceName: String? = nil
    ) {
        self.provider = provider
        self.systemVoiceIdentifier = systemVoiceIdentifier
        self.elevenLabsVoiceID = elevenLabsVoiceID
        self.elevenLabsVoiceName = elevenLabsVoiceName
        self.elevenLabsModelID = elevenLabsModelID
        self.elevenLabsOutputFormat = elevenLabsOutputFormat
        self.xaiVoiceID = xaiVoiceID
        self.xaiVoiceName = xaiVoiceName
        self.xaiBaseURL = xaiBaseURL
        self.xaiLanguage = xaiLanguage
        self.openaiVoiceID = openaiVoiceID
        self.openaiVoiceName = openaiVoiceName
    }

    /// A voice on the on-device engine, by `AVSpeechSynthesisVoice` identifier.
    /// `nil` selects the app's default on-device voice.
    static func systemVoice(_ identifier: String?) -> PersonalityVoiceRef {
        PersonalityVoiceRef(provider: .system, systemVoiceIdentifier: identifier)
    }
}

extension PersonalityVoiceRef {
    /// Snapshot the app's current global voice selection (provider plus every
    /// per-provider voice key) into a ref, so a migrating or newly-created
    /// personality can adopt whatever the user already had configured.
    static func capture(from defaults: UserDefaults) -> PersonalityVoiceRef {
        let provider = defaults.string(forKey: CompanionPreferenceKey.speechProvider)
            .flatMap(CompanionSpeechProvider.init(rawValue:)) ?? .system
        func value(_ key: String) -> String? {
            let raw = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw?.isEmpty == false) ? raw : nil
        }
        return PersonalityVoiceRef(
            provider: provider,
            systemVoiceIdentifier: value(CompanionPreferenceKey.speechVoiceIdentifier),
            elevenLabsVoiceID: value(CompanionPreferenceKey.elevenLabsVoiceID),
            elevenLabsVoiceName: value(CompanionPreferenceKey.elevenLabsVoiceName),
            elevenLabsModelID: value(CompanionPreferenceKey.elevenLabsModelID),
            elevenLabsOutputFormat: value(CompanionPreferenceKey.elevenLabsOutputFormat),
            xaiVoiceID: value(CompanionPreferenceKey.xaiVoiceID),
            xaiVoiceName: value(CompanionPreferenceKey.xaiVoiceName),
            xaiBaseURL: value(CompanionPreferenceKey.xaiBaseURL),
            xaiLanguage: value(CompanionPreferenceKey.xaiLanguage),
            openaiVoiceID: value(CompanionPreferenceKey.openaiVoiceID),
            openaiVoiceName: value(CompanionPreferenceKey.openaiVoiceName)
        )
    }

    /// Write this ref back onto the global voice keys so the speech path (which
    /// reads those keys) speaks in this personality's voice. Only the provider
    /// and the fields this ref carries are written; a `nil` field is left as-is
    /// so a partial ref never wipes unrelated configuration. A `.system` ref
    /// with no identifier clears the saved voice so the app default is used.
    func apply(to defaults: UserDefaults) {
        defaults.set(provider.rawValue, forKey: CompanionPreferenceKey.speechProvider)
        if provider == .system, systemVoiceIdentifier == nil {
            defaults.removeObject(forKey: CompanionPreferenceKey.speechVoiceIdentifier)
        } else if let systemVoiceIdentifier {
            defaults.set(systemVoiceIdentifier, forKey: CompanionPreferenceKey.speechVoiceIdentifier)
        }
        func put(_ v: String?, _ key: String) { if let v { defaults.set(v, forKey: key) } }
        put(elevenLabsVoiceID, CompanionPreferenceKey.elevenLabsVoiceID)
        put(elevenLabsVoiceName, CompanionPreferenceKey.elevenLabsVoiceName)
        put(elevenLabsModelID, CompanionPreferenceKey.elevenLabsModelID)
        put(elevenLabsOutputFormat, CompanionPreferenceKey.elevenLabsOutputFormat)
        put(xaiVoiceID, CompanionPreferenceKey.xaiVoiceID)
        put(xaiVoiceName, CompanionPreferenceKey.xaiVoiceName)
        put(xaiBaseURL, CompanionPreferenceKey.xaiBaseURL)
        put(xaiLanguage, CompanionPreferenceKey.xaiLanguage)
        put(openaiVoiceID, CompanionPreferenceKey.openaiVoiceID)
        put(openaiVoiceName, CompanionPreferenceKey.openaiVoiceName)
    }

    /// Resolve against the set of installed on-device voice identifiers: if this
    /// ref names a system voice that is not installed, drop the identifier so the
    /// app default voice is used instead of a silent or failed selection.
    /// Non-system refs are returned unchanged.
    func resolved(availableSystemVoiceIDs: Set<String>) -> PersonalityVoiceRef {
        guard provider == .system, let identifier = systemVoiceIdentifier else { return self }
        return availableSystemVoiceIDs.contains(identifier) ? self : .systemVoice(nil)
    }
}
