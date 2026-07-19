import Foundation

/// Deterministic per-engine readiness for a personality's chosen voice.
///
/// One pure decision feeds two surfaces: the personality editor's warning
/// banner (which must tell the truth per engine, not recycle the cloud-key
/// copy) and the speak-time fallback disclosure shown when preview or playback
/// resolves to a different voice than the one the user chose. Pure inputs so
/// tests can drive every engine state without AV, network, or dlopen probes.
enum PersonalityVoiceReadiness: Equatable {
    case ready
    /// The Attaché Premium neural runtime or downloaded weights are missing.
    case attachePremiumNotInstalled
    /// The chosen Apple voice identifier is not installed on this Mac, so
    /// AVSpeechSynthesizer would silently substitute a lesser voice.
    case systemVoiceAssetMissing(identifier: String)
    /// The cloud engine has no API key configured in Integrations.
    case cloudKeyMissing(provider: AttacheSpeechProvider)

    static func evaluate(
        ref: PersonalityVoiceRef,
        installedSystemVoiceIDs: Set<String>,
        premiumVoiceReady: Bool,
        connectedCloudEngines: Set<AttacheSpeechProvider>
    ) -> PersonalityVoiceReadiness {
        switch ref.provider {
        case .system:
            if let identifier = ref.systemVoiceIdentifier,
               !installedSystemVoiceIDs.contains(identifier) {
                return .systemVoiceAssetMissing(identifier: identifier)
            }
            return .ready
        case .attachePremium:
            return premiumVoiceReady ? .ready : .attachePremiumNotInstalled
        case .elevenLabs, .xai, .openai:
            return connectedCloudEngines.contains(ref.provider)
                ? .ready
                : .cloudKeyMissing(provider: ref.provider)
        }
    }

    /// The editor banner text. Nil when the engine is genuinely ready, so a
    /// working configuration never shows a warning.
    var warningText: String? {
        switch self {
        case .ready:
            return nil
        case .attachePremiumNotInstalled:
            return "Attaché Premium voice is not installed yet. Preview and playback will use an on-device system voice until it is set up in Settings > Voice."
        case .systemVoiceAssetMissing:
            return "This Apple voice is not downloaded on this Mac, so playback will use a lesser voice. Download it in System Settings > Accessibility > Spoken Content > System Voice."
        case .cloudKeyMissing(let provider):
            return "\(provider.title) is not configured. Preview and playback will use an on-device voice until its key is added in Integrations."
        }
    }

    /// The quiet speak-time note for the click site. Nil when playback uses
    /// exactly the chosen voice; otherwise names the substitute and the reason.
    func fallbackDisclosure(fallbackVoiceName: String) -> String? {
        switch self {
        case .ready:
            return nil
        case .attachePremiumNotInstalled:
            return "Using fallback voice: \(fallbackVoiceName). Attaché Premium voice is not installed yet."
        case .systemVoiceAssetMissing:
            return "Using fallback voice: \(fallbackVoiceName). The chosen Apple voice is not downloaded on this Mac."
        case .cloudKeyMissing(let provider):
            return "Using fallback voice: \(fallbackVoiceName). \(provider.title) has no API key configured."
        }
    }
}
