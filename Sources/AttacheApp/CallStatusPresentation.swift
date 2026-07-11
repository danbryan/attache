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
    /// (checkmark, brighter styling) before the row disappears entirely
    /// (INF-264): it's a "just happened" nudge, not an ongoing status, so
    /// once this window passes with no reply yet, `status(for:...)` returns
    /// nil rather than leaving it lingering in the theme's accent color.
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
        /// `deliveredEmphasisWindow` of its own `deliveredAt`. Since
        /// `status(for:...)` returns nil once that window passes (INF-264),
        /// any non-nil `.sendDelivered` status has this set.
        let isFreshDelivery: Bool
    }

    /// `now` is supplied by the caller, never sampled here, so this stays a
    /// pure function of its arguments. `.sendDelivered`'s own `deliveredAt`
    /// (the instruction's real, persisted delivery timestamp, INF-264) is
    /// what freshness is measured against, not a timestamp reconstructed from
    /// UI view lifecycle events: a `.onChange`-based "first observed" clock
    /// breaks the instant the phase already IS `.sendDelivered` when a view
    /// first appears (e.g. app launch, session re-attach), since `.onChange`
    /// never fires for a view's initial value.
    ///
    /// `recoveryConfirmation`, when non-nil, is shown in place of a
    /// `.failed` phase's message: picking a new model/provider from the
    /// recovery menu does not itself change the phase (the underlying
    /// failure is still the last thing that happened until an actual retry
    /// runs), so without this the composer would keep showing the stale
    /// error instead of confirming the switch. The caller clears it the
    /// moment a new attempt starts.
    ///
    /// Returns `nil` for `.idle`: no status region renders.
    static func status(for phase: CallPhase, now: Date, recoveryConfirmation: String? = nil) -> Status? {
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

        case .sendDelivered(let target, let deliveredAt):
            // INF-264: the confirmation is a "just happened" nudge, not an
            // ongoing status - once the emphasis window passes with no reply
            // yet, the row disappears entirely rather than lingering in the
            // theme's accent color. Measured against the phase's own
            // `deliveredAt`, so an instruction that was already old the
            // moment this phase was first derived (e.g. a stale delivered
            // instruction still attached at app launch) is correctly hidden
            // immediately rather than reading as fresh forever.
            if now.timeIntervalSince(deliveredAt) >= deliveredEmphasisWindow {
                return nil
            }
            return Status(
                text: "Sent to \(target) · watching for the reply",
                icon: .symbol("checkmark.circle.fill"),
                isError: false,
                isFreshDelivery: true
            )

        case .failed(let category, let message):
            if let confirmation = recoveryConfirmation {
                return Status(text: confirmation, icon: .symbol("checkmark.circle.fill"), isError: false, isFreshDelivery: false)
            }
            return Status(text: message, icon: .symbol(icon(for: category)), isError: true, isFreshDelivery: false)

        case .fallbackAnnounced(let message):
            // Neutral styling (INF-258/D5): unlike `.failed`, this is not
            // something the user needs to act on, so no error color and no
            // Switch model / Retry affordance (that stays gated on
            // `conversationRecovery`, which the auto-fallback path never sets).
            return Status(text: message, icon: .symbol("arrow.triangle.2.circlepath"), isError: false, isFreshDelivery: false)
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
