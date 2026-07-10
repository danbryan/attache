import AttacheCore
import Foundation

/// Pure mapping from a live call's `CallPhase` (`AttacheCore`) to what the
/// call composer's status region, and the shared "preparing audio" wording
/// the top overlay borrows, should show (INF-244).
///
/// This replaces the substring heuristics the ticket removes from
/// `CallHUD.swift` (`callStatusIsError`, and the "codex exited" / "claude
/// exited" prefix rewriting in `callStatusDisplayText`): error styling and
/// message text now come only from `CallPhase.failed`'s
/// `ConversationFailureCategory` and message, never from scanning status
/// text for marker words.
///
/// Kept free of SwiftUI so the phase -> text mapping is unit-testable
/// without a view host; see `Tests/AttacheAppTests/CallStatusPresentationTests.swift`.
enum CallStatusPresentation {
    /// Shared wording for the TTS-wait state. Both the call composer and the
    /// top overlay must say this, never "Preparing voice…" or any other
    /// phrasing for the same state.
    static let preparingAudioText = "Preparing audio…"

    /// How long a fresh `.sendDelivered` keeps its "just happened" emphasis
    /// (checkmark, brighter styling) before quietly reverting to a neutral
    /// look. The status text itself is never erased, only the emphasis.
    static let deliveredEmphasisWindow: TimeInterval = 6

    enum Icon: Equatable {
        case spinner
        case symbol(String)
    }

    struct Status: Equatable {
        let text: String
        let icon: Icon
        let isError: Bool
        /// True only for a `.sendDelivered` still inside
        /// `deliveredEmphasisWindow` of the moment it was first observed.
        let isFreshDelivery: Bool
    }

    /// `now` (and `deliveredAt`) are supplied by the caller, never sampled
    /// here, so this stays a pure function of its arguments. `deliveredAt` is
    /// when the phase was first observed as `.sendDelivered` (the caller's
    /// job to track, since `CallPhase` itself carries no timestamp for that
    /// case); pass `nil` if unknown or not applicable.
    ///
    /// Returns `nil` for `.idle`: no status region renders.
    static func status(for phase: CallPhase, now: Date, deliveredAt: Date? = nil) -> Status? {
        switch phase {
        case .idle:
            return nil

        case .listening(let mode):
            return Status(text: listeningText(mode: mode), icon: .symbol("mic.fill"), isError: false, isFreshDelivery: false)

        case .thinking(let since):
            return Status(
                text: withElapsed("Thinking", since: since, now: now),
                icon: .spinner,
                isError: false,
                isFreshDelivery: false
            )

        case .preparingAudio:
            return Status(text: preparingAudioText, icon: .symbol("waveform"), isError: false, isFreshDelivery: false)

        case .speaking:
            return Status(text: "Speaking…", icon: .symbol("speaker.wave.2.fill"), isError: false, isFreshDelivery: false)

        case .paused:
            return Status(text: "Playback paused", icon: .symbol("pause.circle.fill"), isError: false, isFreshDelivery: false)

        case .sendQueued(let target, let since, let reason):
            let base = reason ?? "Sending to \(target) when the session is quiet"
            return Status(text: withElapsed(base, since: since, now: now), icon: .spinner, isError: false, isFreshDelivery: false)

        case .sendDelivered(let target):
            let isFresh = deliveredAt.map { now.timeIntervalSince($0) < deliveredEmphasisWindow } ?? false
            return Status(
                text: "Sent to \(target) · watching for the reply",
                icon: .symbol("checkmark.circle.fill"),
                isError: false,
                isFreshDelivery: isFresh
            )

        case .failed(let category, let message):
            return Status(text: message, icon: .symbol(icon(for: category)), isError: true, isFreshDelivery: false)
        }
    }

    private static func listeningText(mode: String) -> String {
        switch mode {
        case "preparing": return "Starting microphone…"
        case "pushToTalk": return "Release the mic to send this turn."
        case "toggle": return "Click the mic again to send this turn."
        case "alwaysOn": return "Pause briefly to send this turn."
        default: return "Listening…"
        }
    }

    private static func icon(for category: ConversationFailureCategory) -> String {
        switch category {
        case .auth: return "lock.fill"
        case .usageOrRateLimit: return "exclamationmark.circle.fill"
        case .modelUnavailable: return "questionmark.circle.fill"
        case .transient: return "wifi.slash"
        case .other: return "exclamationmark.triangle.fill"
        }
    }

    /// "Thinking" -> "Thinking…"; with a positive elapsed time, "Thinking… 4s"
    /// (or "Thinking… 1:04" past a minute). Never samples the clock; `now` is
    /// the caller's snapshot (a `TimelineView` tick in practice).
    private static func withElapsed(_ prefix: String, since: Date, now: Date) -> String {
        guard let label = elapsedLabel(since: since, now: now) else { return "\(prefix)…" }
        return "\(prefix)… \(label)"
    }

    private static func elapsedLabel(since: Date, now: Date) -> String? {
        let seconds = max(0, Int(now.timeIntervalSince(since).rounded()))
        guard seconds > 0 else { return nil }
        if seconds < 60 { return "\(seconds)s" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
