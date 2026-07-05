import AppKit
import Foundation

struct CompanionVoiceOption: Identifiable, Equatable {
    var id: String
    var name: String
    var gender: String
    var localeIdentifier: String

    var title: String {
        let locale = localeIdentifier.replacingOccurrences(of: "_", with: "-")
        return locale.isEmpty ? name : "\(name) (\(locale))"
    }

    var isFemale: Bool {
        gender.lowercased().contains("female")
    }
}

enum CompanionVoiceCatalog {
    static func options() -> [CompanionVoiceOption] {
        // QA affordance: render the compact-only experience (onboarding
        // guidance box, recommendations) without deleting installed voices.
        // The --print-voices helper inherits the environment, so download
        // detection stays consistent with the simulated catalog.
        let hidePremium = ProcessInfo.processInfo.environment["ATTACHE_COMPACT_VOICES_ONLY"] != nil
        return NSSpeechSynthesizer.availableVoices
            .map(option)
            .filter { !hidePremium || (!$0.id.contains(".premium.") && !$0.id.contains(".enhanced.")) }
            .sorted { lhs, rhs in
                if lhs.localeIdentifier == "en_US", rhs.localeIdentifier != "en_US" { return true }
                if lhs.localeIdentifier != "en_US", rhs.localeIdentifier == "en_US" { return false }
                if lhs.isFemale != rhs.isFemale { return lhs.isFemale }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func option(for identifier: String) -> CompanionVoiceOption? {
        options().first { $0.id == identifier }
    }

    /// Re-enumerates voices in a fresh helper process. The in-process registry
    /// is cached for the process lifetime, so this is the only way a running
    /// app can see voices downloaded after launch. Returns nil on failure.
    static func freshOptions() -> [CompanionVoiceOption]? {
        guard let binary = Bundle.main.executableURL else { return nil }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--print-voices"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return nil
        }
        let parsed = output.split(whereSeparator: \.isNewline).compactMap { line -> CompanionVoiceOption? in
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 4 else { return nil }
            return CompanionVoiceOption(id: parts[0], name: parts[1], gender: parts[2], localeIdentifier: parts[3])
        }
        return parsed.isEmpty ? nil : parsed
    }

    /// The best voice that appeared since the current catalog was read
    /// (i.e. downloaded after launch). Any variant counts; premium beats
    /// enhanced beats compact when several arrived together.
    static func newlyAvailableVoice(fresh: [CompanionVoiceOption],
                                    current: [CompanionVoiceOption]) -> CompanionVoiceOption? {
        let known = Set(current.map(\.id))
        let added = fresh.filter { !known.contains($0.id) }
        return added.first { $0.id.contains(".premium.") }
            ?? added.first { $0.id.contains(".enhanced.") }
            ?? added.first
    }

    static func preferredFemaleVoiceID() -> String? {
        let available = options().filter(\.isFemale)
        let preferredNames = ["Samantha", "Ava", "Zoe", "Allison", "Susan", "Victoria", "Karen", "Serena"]
        for name in preferredNames {
            if let match = available.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                return match.id
            }
        }
        return available.first(where: { $0.localeIdentifier == "en_US" })?.id ?? available.first?.id
    }

    static func fileExportFallbackVoiceID() -> String? {
        let candidates = [
            "com.apple.speech.synthesis.voice.Alex",
            "com.apple.voice.compact.en-GB.Daniel",
            "com.apple.voice.compact.en-US.Samantha",
            "com.apple.voice.compact.en-AU.Karen",
            "com.apple.voice.compact.en-IE.Moira"
        ]
        let availableIDs = Set(options().map(\.id))
        return candidates.first { availableIDs.contains($0) }
            ?? options().first(where: { $0.localeIdentifier == "en_US" })?.id
            ?? options().first?.id
    }

    static func statusText(for identifier: String?) -> String {
        guard let identifier,
              let option = option(for: identifier) else {
            if let fallbackIdentifier = fileExportFallbackVoiceID(),
               let option = option(for: fallbackIdentifier) {
                return "Assistant voice: \(option.title)"
            }
            return "Assistant voice: system default"
        }
        return "Assistant voice: \(option.title)"
    }

    private static func option(_ voice: NSSpeechSynthesizer.VoiceName) -> CompanionVoiceOption {
        let attributes = NSSpeechSynthesizer.attributes(forVoice: voice)
        let name = attributes[.name] as? String ?? voice.rawValue
        let gender = attributes[.gender] as? String ?? ""
        let locale = attributes[.localeIdentifier] as? String ?? ""
        return CompanionVoiceOption(
            id: voice.rawValue,
            name: name,
            gender: gender,
            localeIdentifier: locale
        )
    }
}

extension CompanionVoiceCatalog {
    /// 0 = downloaded premium/enhanced, 1 = modern compact, 2 = legacy
    /// MacinTalk and novelty voices, never recommended unless hand-picked.
    static func qualityTier(_ option: CompanionVoiceOption) -> Int {
        if option.id.contains(".premium.") || option.id.contains(".enhanced.") { return 0 }
        if option.id.contains(".compact.") { return 1 }
        return 2
    }

    /// The exact compact recommendations for English systems, in order.
    static let handPickedEnglish = ["Joelle", "Ralph", "Jamie"]

    /// Installed premium and enhanced voices always lead, best-known first.
    static let premiumOrder = ["Ava", "Zoe", "Jamie", "Allison"]

    /// Fine as fallbacks when a hand-picked voice is missing, never ahead of one.
    static let demotedNames = ["Samantha", "Karen", "Daniel", "Susan"]

    static func voiceLanguage(_ option: CompanionVoiceOption) -> String {
        option.localeIdentifier
            .components(separatedBy: CharacterSet(charactersIn: "_-")).first?.lowercased() ?? ""
    }

    /// Onboarding recommendation order. English systems get installed
    /// premiums first, then the hand-picked trio (which may deliberately
    /// surface a legacy voice like Ralph), then neutral fallbacks, with
    /// demoted names last. A non-English primary system language promotes
    /// that language's voices to the front so users hear recommendations
    /// they understand.
    static func recommended(from options: [CompanionVoiceOption],
                            primaryLanguage: String? = nil) -> [CompanionVoiceOption] {
        let primary = primaryLanguage
            ?? Locale.preferredLanguages.first?.components(separatedBy: "-").first?.lowercased()
            ?? "en"

        func score(_ option: CompanionVoiceOption) -> Int {
            let language = voiceLanguage(option)
            let tier = qualityTier(option)
            var score: Int
            if primary != "en", language == primary {
                score = 0
            } else if language == "en" {
                score = 10_000
            } else {
                score = 40_000
            }
            if tier == 0 {
                let rank = premiumOrder.firstIndex { option.name.localizedCaseInsensitiveContains($0) } ?? premiumOrder.count
                return score + rank
            }
            if let index = handPickedEnglish.firstIndex(where: { option.name.localizedCaseInsensitiveContains($0) }) {
                return score + 100 + index
            }
            if demotedNames.contains(where: { option.name.localizedCaseInsensitiveContains($0) }) {
                return score + 3000
            }
            return score + (tier == 1 ? 1000 : 2000)
        }

        return options.enumerated()
            .sorted { ( score($0.element), $0.offset ) < ( score($1.element), $1.offset ) }
            .map(\.element)
    }
}
