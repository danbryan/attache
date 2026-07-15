import Foundation

/// A personality's bundled voice selection: which engine, which voice, and the
/// provider-specific fields needed to actually speak. It mirrors the app's
/// global speech `AttachePreferenceKey`s so a personality can carry its own
/// voice instead of every personality sharing one global setting.
///
/// A `nil` value exists only for decoding older saved personalities. The store
/// immediately fills it, so every personality exposed in the app has its own
/// voice. A legacy system ref may still have a nil identifier; the store
/// resolves it to a concrete installed voice before exposing the personality.
struct PersonalityVoiceRef: Codable, Equatable {
    var provider: AttacheSpeechProvider
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
        provider: AttacheSpeechProvider = .system,
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
    /// `nil` is accepted only for decoding and migrating older personalities.
    static func systemVoice(_ identifier: String?) -> PersonalityVoiceRef {
        PersonalityVoiceRef(provider: .system, systemVoiceIdentifier: identifier)
    }
}

extension PersonalityVoiceRef {
    /// Snapshot the app's current global voice selection (provider plus every
    /// per-provider voice key) into a ref, so a migrating or newly-created
    /// personality can adopt whatever the user already had configured.
    static func capture(from defaults: UserDefaults) -> PersonalityVoiceRef {
        let provider = defaults.string(forKey: AttachePreferenceKey.speechProvider)
            .flatMap(AttacheSpeechProvider.init(rawValue:)) ?? .system
        func value(_ key: String) -> String? {
            let raw = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw?.isEmpty == false) ? raw : nil
        }
        return PersonalityVoiceRef(
            provider: provider,
            systemVoiceIdentifier: value(AttachePreferenceKey.speechVoiceIdentifier),
            elevenLabsVoiceID: value(AttachePreferenceKey.elevenLabsVoiceID),
            elevenLabsVoiceName: value(AttachePreferenceKey.elevenLabsVoiceName),
            elevenLabsModelID: value(AttachePreferenceKey.elevenLabsModelID),
            elevenLabsOutputFormat: value(AttachePreferenceKey.elevenLabsOutputFormat),
            xaiVoiceID: value(AttachePreferenceKey.xaiVoiceID),
            xaiVoiceName: value(AttachePreferenceKey.xaiVoiceName),
            xaiBaseURL: value(AttachePreferenceKey.xaiBaseURL),
            xaiLanguage: value(AttachePreferenceKey.xaiLanguage),
            openaiVoiceID: value(AttachePreferenceKey.openaiVoiceID),
            openaiVoiceName: value(AttachePreferenceKey.openaiVoiceName)
        )
    }

    /// Write this ref back onto the global voice keys so the speech path (which
    /// reads those keys) speaks in this personality's voice. Only the provider
    /// and the fields this ref carries are written; a `nil` field is left as-is
    /// so a partial ref never wipes unrelated configuration. A `.system` ref
    /// with no identifier clears the saved voice so the app default is used.
    func apply(to defaults: UserDefaults) {
        defaults.set(provider.rawValue, forKey: AttachePreferenceKey.speechProvider)
        if provider == .system, systemVoiceIdentifier == nil {
            defaults.removeObject(forKey: AttachePreferenceKey.speechVoiceIdentifier)
        } else if let systemVoiceIdentifier {
            defaults.set(systemVoiceIdentifier, forKey: AttachePreferenceKey.speechVoiceIdentifier)
        }
        func put(_ v: String?, _ key: String) { if let v { defaults.set(v, forKey: key) } }
        put(elevenLabsVoiceID, AttachePreferenceKey.elevenLabsVoiceID)
        put(elevenLabsVoiceName, AttachePreferenceKey.elevenLabsVoiceName)
        put(elevenLabsModelID, AttachePreferenceKey.elevenLabsModelID)
        put(elevenLabsOutputFormat, AttachePreferenceKey.elevenLabsOutputFormat)
        put(xaiVoiceID, AttachePreferenceKey.xaiVoiceID)
        put(xaiVoiceName, AttachePreferenceKey.xaiVoiceName)
        put(xaiBaseURL, AttachePreferenceKey.xaiBaseURL)
        put(xaiLanguage, AttachePreferenceKey.xaiLanguage)
        put(openaiVoiceID, AttachePreferenceKey.openaiVoiceID)
        put(openaiVoiceName, AttachePreferenceKey.openaiVoiceName)
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
