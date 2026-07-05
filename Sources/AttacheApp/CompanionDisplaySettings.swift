import AttacheCore
import AppKit
import Foundation
import SwiftUI

enum CompanionVisualMode: String, CaseIterable, Identifiable {
    case bars
    case wave
    case heat
    case pulse
    case flow
    case combined

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bars: return "Bars"
        case .wave: return "Wave Ribbon"
        case .heat: return "Spectral Heat"
        case .pulse: return "Pulse Field"
        case .flow: return "Flow Field"
        case .combined: return "Combined"
        }
    }
}

/// Light / dark control for the whole app. System follows the macOS appearance;
/// Light and Dark force the app appearance regardless of the system setting.
enum CompanionAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The appearance to force, or nil to follow the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// What sits at the center of the idle screen. The surface belongs to the
/// user, so the brand lockup is a default, not a watermark.
enum CompanionIdleBrand: String, CaseIterable, Identifiable {
    case mark
    case monogram
    case customText
    case customImage
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mark: return "Attaché"
        case .monogram: return "Monogram only"
        case .customText: return "Custom text"
        case .customImage: return "Custom image"
        case .none: return "Nothing"
        }
    }
}

/// How the spectrum is laid out. Mirrored resamples it outward from the
/// center, symmetric like a speaker grille; natural keeps the raw
/// low-to-high sweep. Both draw from the same deterministic audio state.
enum CompanionVisualSymmetry: String, CaseIterable, Identifiable {
    case mirrored
    case natural

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mirrored: return "Mirrored"
        case .natural: return "Natural"
        }
    }
}

/// How much of an agent's working turn is spoken. "Only when it needs you" stays
/// quiet until an agent is blocked or waiting on your input; "Milestones" (the
/// default) collapses a whole working turn into one recap when it finishes or
/// goes idle; "Play-by-play" narrates each step as it happens.
enum CompanionNarrationDetail: String, CaseIterable, Identifiable {
    case needsYou
    case milestones
    case playByPlay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .needsYou: return "Only when it needs you"
        case .milestones: return "Milestones"
        case .playByPlay: return "Play-by-play"
        }
    }

    var detail: String {
        switch self {
        case .needsYou: return "Stay quiet until an agent is blocked or waiting on you."
        case .milestones: return "One recap when a working turn finishes or goes idle."
        case .playByPlay: return "Narrate each step of the working turn as it happens."
        }
    }

    /// Idle polls (at the watcher's 2s interval) before a buffered turn flushes as
    /// one card. Needs-you disables the idle flush (`.max`), so cards fire only on
    /// a real boundary (a final answer, or you replying) or an explicit needs-you
    /// signal, never just because an agent paused.
    var coalescerQuietPolls: Int {
        switch self {
        case .needsYou: return .max
        case .milestones: return 15   // ~30s
        case .playByPlay: return 3    // ~6s
        }
    }
}

enum CompanionVoiceInputMode: String, CaseIterable, Identifiable {
    case pushToTalk
    case toggle
    case alwaysOn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pushToTalk: return "Push to talk"
        case .toggle: return "Toggle"
        case .alwaysOn: return "Always on"
        }
    }

    var detail: String {
        switch self {
        case .pushToTalk: return "Hold the mic to talk, release to send."
        case .toggle: return "Click to start, click again to send."
        case .alwaysOn: return "Hands-free; sends automatically when you pause."
        }
    }

    /// Short label for the dock chip.
    var shortLabel: String {
        switch self {
        case .pushToTalk: return "Hold"
        case .toggle: return "Toggle"
        case .alwaysOn: return "Always"
        }
    }

    var iconName: String {
        switch self {
        case .pushToTalk: return "mic"
        case .toggle: return "mic.fill"
        case .alwaysOn: return "waveform"
        }
    }

    var next: CompanionVoiceInputMode {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

struct CompanionThemeStop: Equatable, Codable {
    var red: Double
    var green: Double
    var blue: Double
}

enum CompanionTheme: String, CaseIterable, Identifiable {
    // Brass is the brand default: warm ink, amber accent, cream text.
    case brass
    case classic
    case cyberpunk
    case aurora
    case ember
    case paper
    case highContrast
    // A native option: the accent, highlight, and gradient defer to the macOS
    // system accent color, so the app looks like a stock Mac app for users who
    // prefer that over an opinionated theme.
    case macOS
    // A user-defined theme; colors come from CustomThemeStore.activeSpec and
    // fall back to Cyberpunk when no spec is active.
    case custom

    var id: String { rawValue }

    /// The live macOS accent color as a stop, resolved in the current appearance.
    static func systemAccentStop() -> CompanionThemeStop {
        let resolved = NSColor.controlAccentColor.usingColorSpace(.sRGB)
            ?? NSColor.controlAccentColor.usingColorSpace(.deviceRGB)
        guard let c = resolved else { return CompanionThemeStop(red: 0.0, green: 0.48, blue: 1.0) }
        return CompanionThemeStop(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
    }

    var title: String {
        switch self {
        case .brass: return "Brass"
        case .classic: return "Classic"
        case .cyberpunk: return "Cyberpunk"
        case .aurora: return "Aurora"
        case .ember: return "Ember"
        case .paper: return "Paper"
        case .highContrast: return "High Contrast"
        case .macOS: return "macOS"
        case .custom: return CustomThemeStore.activeSpec?.name ?? "Custom"
        }
    }

    var stops: [CompanionThemeStop] {
        switch self {
        case .brass:
            return [
                CompanionThemeStop(red: 0.24, green: 0.15, blue: 0.06),
                CompanionThemeStop(red: 0.66, green: 0.42, blue: 0.16),
                CompanionThemeStop(red: 0.909, green: 0.635, blue: 0.298)
            ]
        case .classic:
            return [
                CompanionThemeStop(red: 0.20, green: 0.18, blue: 0.42),
                CompanionThemeStop(red: 0.16, green: 0.52, blue: 0.55),
                CompanionThemeStop(red: 0.92, green: 0.62, blue: 0.32)
            ]
        case .cyberpunk:
            return [
                CompanionThemeStop(red: 0.20, green: 0.09, blue: 0.45),
                CompanionThemeStop(red: 0.58, green: 0.16, blue: 0.78),
                CompanionThemeStop(red: 0.98, green: 0.26, blue: 0.66)
            ]
        case .aurora:
            return [
                CompanionThemeStop(red: 0.10, green: 0.20, blue: 0.40),
                CompanionThemeStop(red: 0.14, green: 0.56, blue: 0.52),
                CompanionThemeStop(red: 0.52, green: 0.93, blue: 0.66)
            ]
        case .ember:
            return [
                CompanionThemeStop(red: 0.24, green: 0.10, blue: 0.16),
                CompanionThemeStop(red: 0.74, green: 0.22, blue: 0.16),
                CompanionThemeStop(red: 0.98, green: 0.78, blue: 0.34)
            ]
        case .paper:
            return [
                CompanionThemeStop(red: 0.86, green: 0.86, blue: 0.84),
                CompanionThemeStop(red: 0.70, green: 0.72, blue: 0.75),
                CompanionThemeStop(red: 0.55, green: 0.58, blue: 0.70)
            ]
        case .highContrast:
            return [
                CompanionThemeStop(red: 0.08, green: 0.08, blue: 0.08),
                CompanionThemeStop(red: 0.45, green: 0.45, blue: 0.45),
                CompanionThemeStop(red: 0.92, green: 0.92, blue: 0.92)
            ]
        case .macOS:
            let a = CompanionTheme.systemAccentStop()
            return [
                CompanionThemeStop(red: a.red * 0.42, green: a.green * 0.42, blue: a.blue * 0.42),
                CompanionThemeStop(red: a.red, green: a.green, blue: a.blue),
                CompanionThemeStop(red: min(1, a.red * 1.2 + 0.12), green: min(1, a.green * 1.2 + 0.12), blue: min(1, a.blue * 1.2 + 0.12))
            ]
        case .custom:
            return CustomThemeStore.activeSpec?.stops ?? CompanionTheme.cyberpunk.stops
        }
    }

    /// Themes that demand fully solid text plates regardless of the user's
    /// surface opacity setting.
    var wantsSolidPlates: Bool {
        if self == .custom { return CustomThemeStore.activeSpec?.wantsSolidPlates ?? false }
        return self == .highContrast
    }

    /// The accent used for selection, chips, and the caption highlight,
    /// per system appearance. Dark accents are the original theme stops;
    /// light accents are darkened variants so accent-on-white stays above
    /// the 4.5:1 contrast floor (values verified by ThemeContrastTests).
    func accentStop(darkScheme: Bool) -> CompanionThemeStop {
        if darkScheme {
            switch self {
            case .brass: return CompanionThemeStop(red: 0.909, green: 0.635, blue: 0.298)
            case .classic: return CompanionThemeStop(red: 0.92, green: 0.62, blue: 0.32)
            case .cyberpunk: return CompanionThemeStop(red: 0.98, green: 0.26, blue: 0.66)
            case .aurora: return CompanionThemeStop(red: 0.52, green: 0.93, blue: 0.66)
            case .ember: return CompanionThemeStop(red: 0.98, green: 0.78, blue: 0.34)
            case .paper: return CompanionThemeStop(red: 0.62, green: 0.66, blue: 0.94)
            case .highContrast: return CompanionThemeStop(red: 1.00, green: 0.84, blue: 0.25)
            case .macOS: return CompanionTheme.systemAccentStop()
            case .custom:
                return CustomThemeStore.activeSpec?.accentDark
                    ?? CompanionTheme.cyberpunk.accentStop(darkScheme: true)
            }
        }
        switch self {
        case .brass: return CompanionThemeStop(red: 0.60, green: 0.35, blue: 0.05)
        case .classic: return CompanionThemeStop(red: 0.63, green: 0.35, blue: 0.07)
        case .cyberpunk: return CompanionThemeStop(red: 0.78, green: 0.08, blue: 0.45)
        case .aurora: return CompanionThemeStop(red: 0.05, green: 0.45, blue: 0.27)
        case .ember: return CompanionThemeStop(red: 0.60, green: 0.36, blue: 0.02)
        case .paper: return CompanionThemeStop(red: 0.28, green: 0.31, blue: 0.55)
        case .highContrast: return CompanionThemeStop(red: 0.05, green: 0.22, blue: 0.65)
        case .macOS: return CompanionTheme.systemAccentStop()
        case .custom:
            return CustomThemeStore.activeSpec?.accentLight
                ?? CompanionTheme.cyberpunk.accentStop(darkScheme: false)
        }
    }

    var captionHighlightColor: Color {
        // Caption highlights follow the theme accent, validated per plate.
        signatureColor
    }

    /// The theme accent as an appearance-adaptive color, used to tint
    /// selection affordances (e.g. the session radio) so they follow the
    /// chosen theme instead of the system accent. Adapts per scheme so the
    /// accent holds the contrast floor on both plate colors.
    var signatureColor: Color {
        // The macOS theme defers to the live system accent (follows the user's
        // Appearance > Color choice and the light/dark scheme automatically).
        if self == .macOS { return Color(nsColor: .controlAccentColor) }
        let theme = self
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let stop = theme.accentStop(darkScheme: dark)
            return NSColor(srgbRed: stop.red, green: stop.green, blue: stop.blue, alpha: 1)
        })
    }

    var signatureForegroundColor: Color {
        let theme = self
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let stop = theme.accentStop(darkScheme: dark)
            let luminance = 0.2126 * stop.red + 0.7152 * stop.green + 0.0722 * stop.blue
            return luminance > 0.62 ? NSColor.black.withAlphaComponent(0.84) : NSColor.white
        })
    }
}

struct CompanionCaptionLanguage: Identifiable, Hashable {
    let id: String
    let name: String
    let speechLocale: String

    static let all: [CompanionCaptionLanguage] = [
        CompanionCaptionLanguage(id: "en", name: "English", speechLocale: "en-US"),
        CompanionCaptionLanguage(id: "ko", name: "Korean", speechLocale: "ko-KR"),
        CompanionCaptionLanguage(id: "ja", name: "Japanese", speechLocale: "ja-JP"),
        CompanionCaptionLanguage(id: "zh", name: "Chinese", speechLocale: "zh-CN"),
        CompanionCaptionLanguage(id: "es", name: "Spanish", speechLocale: "es-ES"),
        CompanionCaptionLanguage(id: "fr", name: "French", speechLocale: "fr-FR"),
        CompanionCaptionLanguage(id: "de", name: "German", speechLocale: "de-DE"),
        CompanionCaptionLanguage(id: "it", name: "Italian", speechLocale: "it-IT"),
        CompanionCaptionLanguage(id: "pt", name: "Portuguese", speechLocale: "pt-BR"),
        CompanionCaptionLanguage(id: "ru", name: "Russian", speechLocale: "ru-RU"),
        CompanionCaptionLanguage(id: "hi", name: "Hindi", speechLocale: "hi-IN"),
        CompanionCaptionLanguage(id: "ar", name: "Arabic", speechLocale: "ar-SA"),
        CompanionCaptionLanguage(id: "pl", name: "Polish", speechLocale: "pl-PL"),
        CompanionCaptionLanguage(id: "nb", name: "Norwegian", speechLocale: "nb-NO"),
        CompanionCaptionLanguage(id: "th", name: "Thai", speechLocale: "th-TH")
    ]

    static func named(_ id: String) -> CompanionCaptionLanguage {
        all.first { $0.id == id } ?? all[0]
    }
}

enum CompanionPreferenceKey {
    static let visualMode = "attache.visualMode"
    static let visualSymmetry = "attache.visualSymmetry"
    static let idleBrand = "attache.idleBrand"
    static let idleCustomText = "attache.idleCustomText"
    static let theme = "attache.theme"
    static let appearanceMode = "attache.appearanceMode"
    static let customThemeID = "attache.customThemeID"
    static let legacyKeyMigrationDone = "attache.legacyKeyMigrationDone"
    static let uiTextScale = "attache.uiTextScale"
    static let onboardingCompleted = "attache.onboardingCompleted"
    static let onboardingResumeStep = "attache.onboardingResumeStep"
    static let surfaceOpacity = "attache.surfaceOpacity"
    static let brightnessLevel = "attache.brightnessLevel"
    static let visualIntensity = "attache.visualIntensity"
    static let seekStepSeconds = "attache.seekStepSeconds"
    static let captionLineCount = "attache.captionLineCount"
    static let captionFontSize = "attache.captionFontSize"
    static let audioCacheRetentionMinutes = "attache.audioCacheRetentionMinutes"
    static let voiceInputMode = "attache.voiceInputMode"
    static let watchedSessions = "attache.watchedSessions"
    static let sessionRenames = "attache.sessionRenames"
    static let captionsEnabled = "attache.captionsEnabled"
    static let lowLatencyCaptions = "attache.lowLatencyCaptions"
    static let spokenLanguage = "attache.spokenLanguage"
    static let microphoneDeviceID = "attache.microphoneDeviceID"
    static let onDeviceOnly = "attache.onDeviceOnly"
    static let voicemailMode = "attache.voicemailMode"
    static let autoHideControls = "attache.autoHideControls"
    static let autoHideDelaySeconds = "attache.autoHideDelaySeconds"
    static let showPersonalitySwitcher = "attache.showPersonalitySwitcher"
    static let showPersonalityNameInDock = "attache.showPersonalityNameInDock"
    static let notifyScope = "attache.notifyScope"
    static let showInMenuBar = "attache.showInMenuBar"
    static let playbackSpeed = "attache.playbackSpeed"
    static let showTips = "attache.showTips"
    static let showActivityInsights = "attache.showActivityInsights"
    static let captionSyncOffsetMs = "attache.captionSyncOffsetMs"
    static let attachedCodexSessionID = "attache.attachedCodexSessionID"
    static let codexSourceEnabled = "attache.codexSourceEnabled"
    static let claudeCodeSourceEnabled = "attache.claudeCodeSourceEnabled"
    static let personalityPrompt = "attache.personalityPrompt"
    static let speechProvider = "attache.speechProvider"
    static let speechVoiceIdentifier = "attache.speechVoiceIdentifier"
    static let legacySamanthaDefaultMigrated = "attache.legacySamanthaDefaultMigrated"
    static let elevenLabsVoiceID = "attache.elevenLabsVoiceID"
    static let elevenLabsVoiceName = "attache.elevenLabsVoiceName"
    static let elevenLabsModelID = "attache.elevenLabsModelID"
    static let elevenLabsOutputFormat = "attache.elevenLabsOutputFormat"
    static let xaiVoiceID = "attache.xaiVoiceID"
    static let xaiVoiceName = "attache.xaiVoiceName"
    static let openaiVoiceID = "attache.openaiVoiceID"
    static let openaiVoiceName = "attache.openaiVoiceName"
    static let xaiBaseURL = "attache.xaiBaseURL"
    static let xaiLanguage = "attache.xaiLanguage"
    static let presentationLLMEnabled = "attache.presentationLLMEnabled"
    static let presentationLLMProvider = "attache.presentationLLMProvider"
    static let presentationLLMBaseURL = "attache.presentationLLMBaseURL"
    static let presentationLLMAPIKey = "attache.presentationLLMAPIKey"
    static let presentationLLMAPIKeySecretRef = "attache.presentationLLMAPIKeySecretRef"
    static let configuredSecretAccounts = "attache.configuredSecretAccounts"
    static let presentationLLMModel = "attache.presentationLLMModel"
    static let presentationReasoningEffort = "attache.presentationReasoningEffort"
    static let presentationServiceTier = "attache.presentationServiceTier"
    static let narrationDetail = "attache.narrationDetail"
    static let cloudConsentPresentation = "attache.cloudConsentPresentation"
    static let cloudConsentVoice = "attache.cloudConsentVoice"
    static let ollamaBaseURL = "attache.ollamaBaseURL"
    static let lmStudioBaseURL = "attache.lmStudioBaseURL"
    static let customBaseURL = "attache.customBaseURL"
}

extension CompanionTheme {
    /// Debug-build contrast floor audit (INF-150): logs any theme accent that
    /// falls below 4.5:1 against the plate it renders on. The same pairs are
    /// enforced by ThemeContrastTests; this catches drift at runtime while
    /// iterating on theme values.
    static func auditContrastFloor() {
        for theme in CompanionTheme.allCases where theme != .macOS {
            for darkScheme in [true, false] {
                let accent = theme.accentStop(darkScheme: darkScheme)
                let plate: Double = darkScheme ? 0 : 1
                let ratio = WCAGContrast.ratio(
                    red1: accent.red, green1: accent.green, blue1: accent.blue,
                    red2: plate, green2: plate, blue2: plate)
                if ratio < 4.5 {
                    AttacheLog.presentation.warning(
                        "theme \(theme.rawValue, privacy: .public) accent below contrast floor in \(darkScheme ? "dark" : "light", privacy: .public) scheme: \(String(format: "%.2f", ratio), privacy: .public):1")
                }
            }
        }
    }
}
