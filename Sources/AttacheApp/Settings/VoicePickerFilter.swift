import AttacheCore
import Foundation

/// Quality tier shown as a filter chip in the voice picker. Distinct from
/// `AttacheVoiceCatalog.qualityTier`, which only separates installed
/// premium/enhanced voices (tier 0) from compact (tier 1) from legacy
/// MacinTalk/novelty voices (tier 2) for sorting purposes. The picker needs
/// Premium and Enhanced as separate chips (INF-352), so this splits tier 0 by
/// checking the same `.premium.` / `.enhanced.` id substrings the catalog
/// already keys off. Legacy voices (tier 2) fold into `.compact` here: the
/// ticket specifies exactly three chips and does not call for a fourth
/// "Legacy" chip.
enum VoicePickerQuality: String, CaseIterable, Identifiable, Equatable, Codable {
    case premium
    case enhanced
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        case .compact: return "Compact"
        }
    }

    static func forSystemVoice(_ option: AttacheVoiceOption) -> VoicePickerQuality {
        if option.id.contains(".premium.") { return .premium }
        if option.id.contains(".enhanced.") { return .enhanced }
        return .compact
    }
}

/// One normalized row in the voice picker. System, xAI, and OpenAI voices are
/// unified into this single shape so search/filter/group logic never has to
/// branch on engine-specific option types. ElevenLabs is intentionally out of
/// scope for the rebuilt picker (INF-352 scopes engine chips to System / Grok
/// / OpenAI); its selection keeps using the pre-existing per-engine picker.
struct VoicePickerEntry: Identifiable, Equatable {
    var id: String
    var voiceID: String
    var name: String
    var engine: AttacheSpeechProvider
    var languageCode: String
    var languageName: String
    var quality: VoicePickerQuality?
}

struct VoicePickerLanguageGroup: Identifiable, Equatable {
    var languageCode: String
    var languageName: String
    var entries: [VoicePickerEntry]

    var id: String { languageCode }
}

struct VoicePickerFilterState: Equatable {
    var searchText: String = ""
    var engines: Set<AttacheSpeechProvider> = [.system, .xai, .openai]
    var qualities: Set<VoicePickerQuality> = Set(VoicePickerQuality.allCases)
    /// nil (or empty) means "All languages".
    var languageCode: String?
}

struct VoicePickerResult: Equatable {
    var recommended: [VoicePickerEntry]
    var groups: [VoicePickerLanguageGroup]
}

/// Pure, view-free filtering/grouping logic for the voice picker (INF-352
/// step 5). Takes a fixed catalog of voice options plus filter state and
/// returns a deterministic result, so it is unit-testable without touching
/// SwiftUI, NSSpeechSynthesizer, or any network voice list.
enum VoicePickerFilter {
    static func languageName(for code: String) -> String {
        guard !code.isEmpty else { return "Multilingual" }
        return Locale.current.localizedString(forLanguageCode: code)?
            .capitalized(with: Locale.current) ?? code.uppercased()
    }

    /// Normalizes the app's raw voice sources into the unified entry list the
    /// picker filters. System voices come from an already-computed options
    /// list (never a fresh `AttacheVoiceCatalog.options()` call, see step 6);
    /// cloud voices come from whatever the engine's already-loaded remote
    /// list currently holds.
    static func entries(
        systemOptions: [AttacheVoiceOption],
        xaiOptions: [RemoteVoiceOption],
        openaiOptions: [RemoteVoiceOption]
    ) -> [VoicePickerEntry] {
        let system = systemOptions.map { option -> VoicePickerEntry in
            let code = AttacheVoiceCatalog.voiceLanguage(option)
            return VoicePickerEntry(
                id: "system:\(option.id)",
                voiceID: option.id,
                name: option.name,
                engine: .system,
                languageCode: code,
                languageName: languageName(for: code),
                quality: VoicePickerQuality.forSystemVoice(option)
            )
        }
        // xAI voices carry a language code in `detail` (e.g. "en"); OpenAI's
        // built-in voices are multilingual and carry a style description in
        // `detail` instead (e.g. "warm"), so they group under "Multilingual".
        let xai = xaiOptions.map { option -> VoicePickerEntry in
            let code = option.detail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return VoicePickerEntry(
                id: "xai:\(option.id)",
                voiceID: option.id,
                name: option.name,
                engine: .xai,
                languageCode: code,
                languageName: languageName(for: code),
                quality: nil
            )
        }
        let openai = openaiOptions.map { option -> VoicePickerEntry in
            VoicePickerEntry(
                id: "openai:\(option.id)",
                voiceID: option.id,
                name: option.name,
                engine: .openai,
                languageCode: "",
                languageName: languageName(for: ""),
                quality: nil
            )
        }
        return system + xai + openai
    }

    /// Matches CharacterSwitcherPalette's grammar: search text is split into
    /// whitespace-separated terms, each matched case-insensitively as a
    /// substring against the searchable text (name and language name here),
    /// and every term must match (AND across terms).
    static func matches(_ entry: VoicePickerEntry, query: String) -> Bool {
        let terms = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return true }
        let searchable = "\(entry.name) \(entry.languageName)"
        return terms.allSatisfy { searchable.localizedCaseInsensitiveContains($0) }
    }

    static func filtered(_ entries: [VoicePickerEntry], state: VoicePickerFilterState) -> [VoicePickerEntry] {
        entries.filter { entry in
            guard state.engines.contains(entry.engine) else { return false }
            if entry.engine == .system, let quality = entry.quality, !state.qualities.contains(quality) {
                return false
            }
            if let languageCode = state.languageCode, !languageCode.isEmpty, entry.languageCode != languageCode {
                return false
            }
            return matches(entry, query: state.searchText)
        }
    }

    static func grouped(_ entries: [VoicePickerEntry], userLanguageCode: String) -> [VoicePickerLanguageGroup] {
        let byLanguage = Dictionary(grouping: entries, by: \.languageCode)
        let groups = byLanguage.map { code, entries in
            VoicePickerLanguageGroup(
                languageCode: code,
                languageName: languageName(for: code),
                entries: entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            )
        }
        return groups.sorted { lhs, rhs in
            if lhs.languageCode == userLanguageCode, rhs.languageCode != userLanguageCode { return true }
            if lhs.languageCode != userLanguageCode, rhs.languageCode == userLanguageCode { return false }
            return lhs.languageName.localizedCaseInsensitiveCompare(rhs.languageName) == .orderedAscending
        }
    }

    /// Builds the full result: a Recommended section (delegating directly to
    /// `AttacheVoiceCatalog.recommended`, never reimplementing its ordering)
    /// capped at 3 entries to match the app's existing onboarding convention
    /// (`OnboardingSheet.swift`'s `.prefix(3)`), restricted to system voices
    /// that also pass the active filter, followed by the filtered/grouped
    /// list for browsing.
    static func result(
        systemOptions: [AttacheVoiceOption],
        xaiOptions: [RemoteVoiceOption],
        openaiOptions: [RemoteVoiceOption],
        state: VoicePickerFilterState,
        primaryLanguage: String? = nil,
        userLanguageCode: String? = nil
    ) -> VoicePickerResult {
        let all = entries(systemOptions: systemOptions, xaiOptions: xaiOptions, openaiOptions: openaiOptions)
        let filtered = filtered(all, state: state)
        let filteredByID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.voiceID, $0) })

        let recommended: [VoicePickerEntry]
        if state.engines.contains(.system) {
            let recommendedOptions = AttacheVoiceCatalog.recommended(from: systemOptions, primaryLanguage: primaryLanguage)
            recommended = recommendedOptions.compactMap { filteredByID[$0.id] }.prefix(3).map { $0 }
        } else {
            recommended = []
        }

        let userLanguage = userLanguageCode
            ?? primaryLanguage
            ?? Locale.preferredLanguages.first?.components(separatedBy: "-").first?.lowercased()
            ?? "en"
        let groups = grouped(filtered, userLanguageCode: userLanguage)
        return VoicePickerResult(recommended: recommended, groups: groups)
    }

    /// Installed languages across all three engines, for the Language filter
    /// menu, with the user's current language pinned first and the rest
    /// alphabetical. "All" is represented by `nil` and is handled by the view.
    static func availableLanguages(
        systemOptions: [AttacheVoiceOption],
        xaiOptions: [RemoteVoiceOption],
        openaiOptions: [RemoteVoiceOption],
        userLanguageCode: String
    ) -> [(code: String, name: String)] {
        let all = entries(systemOptions: systemOptions, xaiOptions: xaiOptions, openaiOptions: openaiOptions)
        var seen = Set<String>()
        var result: [(code: String, name: String)] = []
        for entry in all where !seen.contains(entry.languageCode) {
            seen.insert(entry.languageCode)
            result.append((entry.languageCode, entry.languageName))
        }
        return result.sorted { lhs, rhs in
            if lhs.code == userLanguageCode, rhs.code != userLanguageCode { return true }
            if lhs.code != userLanguageCode, rhs.code == userLanguageCode { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
