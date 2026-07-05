import Foundation
import os

/// Structured logging for Attaché. One subsystem, a category per subsystem area,
/// so a friend's install can be diagnosed with:
///
///   log stream --predicate 'subsystem == "com.bryanlabs.attache"' --level info
///
/// Never log secrets, transcript content, or full prompts here — log lengths and
/// identifiers instead (INF-158).
public enum AttacheLog {
    public static let subsystem = "com.bryanlabs.attache"
    public static let store = Logger(subsystem: subsystem, category: "store")
    public static let watcher = Logger(subsystem: subsystem, category: "watcher")
    public static let presentation = Logger(subsystem: subsystem, category: "presentation")
    public static let speech = Logger(subsystem: subsystem, category: "speech")
    public static let server = Logger(subsystem: subsystem, category: "server")
    public static let secrets = Logger(subsystem: subsystem, category: "secrets")
}

/// A privacy-safe diagnostic snapshot for a bug report: app version, enabled
/// sources, provider kinds, and DB counts. Contains no key material or content by
/// construction; callers pass only identifiers and counts. The `logLines` are
/// appended by the app from OSLogStore at call time.
public struct DiagnosticSnapshot {
    public var appVersion: String
    public var enabledSources: [String]
    public var presentationProviderKind: String
    public var voiceProviderKind: String
    public var cardCount: Int
    public var instructionCount: Int
    public var logLines: [String]

    public init(
        appVersion: String,
        enabledSources: [String],
        presentationProviderKind: String,
        voiceProviderKind: String,
        cardCount: Int,
        instructionCount: Int,
        logLines: [String] = []
    ) {
        self.appVersion = appVersion
        self.enabledSources = enabledSources
        self.presentationProviderKind = presentationProviderKind
        self.voiceProviderKind = voiceProviderKind
        self.cardCount = cardCount
        self.instructionCount = instructionCount
        self.logLines = logLines
    }

    /// The pasteable text. Only kinds/counts/identifiers, never keys or content.
    public func rendered() -> String {
        var lines = [
            "Attaché diagnostic snapshot",
            "app_version: \(appVersion)",
            "enabled_sources: \(enabledSources.isEmpty ? "none" : enabledSources.joined(separator: ", "))",
            "presentation_provider: \(presentationProviderKind)",
            "voice_provider: \(voiceProviderKind)",
            "cards: \(cardCount)",
            "instructions: \(instructionCount)"
        ]
        if !logLines.isEmpty {
            lines.append("recent_log:")
            lines.append(contentsOf: logLines.suffix(50).map { "  \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}
