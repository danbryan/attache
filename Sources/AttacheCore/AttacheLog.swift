import Foundation
import os

/// Structured logging for Attaché. One subsystem, a category per subsystem area,
/// so a friend's install can be diagnosed with:
///
///   log stream --predicate 'subsystem == "com.bryanlabs.attache"' --level info
///
/// Never log secrets, transcript content, or full prompts here. Log lengths and
/// identifiers instead (INF-158).
public enum AttacheLog {
    public static let subsystem = "com.bryanlabs.attache"
    public static let store = Logger(subsystem: subsystem, category: "store")
    public static let watcher = Logger(subsystem: subsystem, category: "watcher")
    public static let presentation = Logger(subsystem: subsystem, category: "presentation")
    public static let speech = Logger(subsystem: subsystem, category: "speech")
    public static let server = Logger(subsystem: subsystem, category: "server")
    public static let secrets = Logger(subsystem: subsystem, category: "secrets")
    public static let twoWay = Logger(subsystem: subsystem, category: "two-way")

    /// Signpost intervals around UI actions that have been reported as slow
    /// (opening Settings, switching panes, expanding Advanced, opening a
    /// palette, applying a personality switch), so they can be attributed in
    /// Instruments' Points of Interest / os_signpost track (INF-349).
    /// Measurement only: emitting a signpost never changes behavior.
    public static let uiLatency = OSSignposter(subsystem: subsystem, category: "ui-latency")
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
    /// Background topic-tagging failures observed this launch. Tagging stays
    /// silent to the user by design (it is low-stakes and high-volume), but a
    /// silent failure is still worth counting somewhere a bug report can see
    /// it (INF-254) rather than vanishing unobserved.
    public var taggingFailureCount: Int
    /// Opt-in auto-fallback hops this launch (INF-258/D5): every time the
    /// live conversation call transparently switched to the next configured
    /// and consented provider in the chain after a usage-limit,
    /// model-unavailable, or transient failure. Same "silent to the user by
    /// design, but still worth counting" rationale as `taggingFailureCount`
    /// (spec item 6: log every hop, category + provider pair, to
    /// diagnostics), though the category/provider pairs themselves stay in
    /// `AttacheLog`, not here - this is only the aggregate count.
    public var conversationFallbackCount: Int
    public var logLines: [String]

    public init(
        appVersion: String,
        enabledSources: [String],
        presentationProviderKind: String,
        voiceProviderKind: String,
        cardCount: Int,
        instructionCount: Int,
        taggingFailureCount: Int = 0,
        conversationFallbackCount: Int = 0,
        logLines: [String] = []
    ) {
        self.appVersion = appVersion
        self.enabledSources = enabledSources
        self.presentationProviderKind = presentationProviderKind
        self.voiceProviderKind = voiceProviderKind
        self.cardCount = cardCount
        self.instructionCount = instructionCount
        self.taggingFailureCount = taggingFailureCount
        self.conversationFallbackCount = conversationFallbackCount
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
            "instructions: \(instructionCount)",
            "tagging_failures: \(taggingFailureCount)",
            "conversation_fallbacks: \(conversationFallbackCount)"
        ]
        if !logLines.isEmpty {
            lines.append("recent_log:")
            lines.append(contentsOf: logLines.suffix(50).map { "  \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}
