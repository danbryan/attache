import Foundation

/// A single, testable source of truth for what the live-call UI should show.
///
/// Today, phase is inferred ad hoc from `isConversing`, `playback.isPlaying` /
/// `.isPaused` / `.isBusy`, `expectingReplyAudio`, and free-text status
/// strings, and error styling is substring matching on those strings
/// (`CallHUD.swift` around lines 201-207). See
/// `docs/reviews/2026-07-10-app-review.md` section 2 for the full rationale.
///
/// `CallPhase` only describes phases. Deriving it from live app state
/// (`derive(from:)` below) and rendering it in the UI are separate concerns:
/// this ticket (INF-237) adds the type, the reducer, and wires AppModel to
/// publish it; a later ticket (A2) wires the views to render from it.
public enum CallPhase: Equatable {
    /// No call in progress, or a call with nothing to report.
    case idle
    /// The mic is actively capturing, or starting to capture, a turn.
    ///
    /// `mode` mirrors `CompanionVoiceInputMode`'s raw value ("pushToTalk",
    /// "toggle", "alwaysOn") from AttacheApp, or "preparing" while the mic is
    /// still starting up (mirrors `callMicStatusText`'s own precedence in
    /// `CallHUD.swift`, which checks `isPreparing` before branching on mode).
    /// Kept as a plain `String` rather than referencing `CompanionVoiceInputMode`
    /// directly because that enum lives in AttacheApp, and AttacheCore must not
    /// depend on AttacheApp.
    case listening(mode: String)
    /// Waiting on the personality/model's response to a conversation turn.
    /// `since` is when the wait began (`AppModel.conversationWaitStartedAt`),
    /// so the UI can show elapsed time.
    case thinking(since: Date)
    /// The model has replied and its speech is being synthesized.
    case preparingAudio
    /// The reply is actively playing back.
    case speaking
    /// Playback of the reply is paused.
    case paused
    /// A Tell Agent instruction is staged/confirmed/delivering: it has not
    /// reached the target session yet. `since` is when it was confirmed (or
    /// created, if not yet confirmed); `reason` is a free-text explanation
    /// (e.g. why delivery is waiting) when one is available, nil otherwise.
    case sendQueued(target: String, since: Date, reason: String?)
    /// The instruction was delivered to the agent; waiting on its reply.
    /// `deliveredAt` is the instruction's own persisted delivery timestamp
    /// (`Instruction.deliveredAt`), not a UI-side "when we first noticed"
    /// clock (INF-264 follow-up): this phase is re-derived from scratch every
    /// time `CallSignals.pendingSend` is recomputed, including the very first
    /// evaluation after an app launch or a session re-attach, so relying on a
    /// SwiftUI `.onChange` to capture "the moment the phase became this"
    /// breaks whenever the phase already IS this on the view's first
    /// appearance (`.onChange` never fires for a view's initial value). An
    /// old, still-unreplied delivered instruction would then show its "just
    /// delivered" emphasis forever. Carrying the real timestamp here instead
    /// makes staleness a pure function of the phase's own data.
    case sendDelivered(target: String, deliveredAt: Date)
    /// A conversation call failed, or a Tell Agent delivery failed.
    case failed(ConversationFailureCategory, message: String)
    /// The opt-in auto-fallback chain (INF-258/D5) just switched the live
    /// call to a different provider after a recoverable failure; `message`
    /// is the one-sentence announcement ("Grok hit its usage limit; using
    /// Ollama for now."). Distinct from `.failed`: this is not something the
    /// user needs to act on (no Switch model / Retry affordance applies), so
    /// it renders with neutral, non-error styling. `AppModel` clears the
    /// signal once the retry this triggers actually starts, so it is
    /// transient by construction, not something a caller needs to time out.
    case fallbackAnnounced(message: String)
}

/// A plain-value snapshot of the live-call signals AppModel already tracks,
/// taken at one instant so `CallPhase.derive(from:)` can be a pure function
/// (no AppModel dependency, no side effects, no wall-clock reads) and
/// therefore directly unit-testable.
///
/// Field names intentionally mirror the AppModel/CallHUD properties they
/// come from, so a later ticket can wire this up mechanically:
/// - `isConversing`, `conversationWaitStartedAt` <- `AppModel.isConversing`,
///   `AppModel.conversationWaitStartedAt` (private, backs
///   `conversationElapsedSeconds`).
/// - `micIsListening`, `micIsPreparing` <-
///   `MicTranscriptController.isListening` / `.isPreparing`.
/// - `voiceInputMode` <- `AppModel.voiceInputMode.rawValue`
///   (`CompanionVoiceInputMode`, an AttacheApp type).
/// - `playbackIsPlaying`, `playbackIsPaused`, `playbackIsBusy` <-
///   `SpeechPlaybackController.isPlaying` / `.isPaused` / `.isBusy`, exposed
///   on AppModel as `playback.*`.
/// - `isComposingNarration` <- `AppModel`'s in-flight narration-compose
///   tokens being non-empty: true for the LLM call
///   (`CompanionPresentationService.prepare`) that writes a watched
///   session's spoken recap, which runs BEFORE `playbackIsBusy` ever goes
///   true (that only covers the TTS synthesis after the text exists).
///   Without this, a Tell Agent reply's recap composition had no signal at
///   all once `.sendDelivered` moved past its own emphasis window.
/// - `pendingAssistantReply` <- `AppModel.pendingAssistantReply`.
/// - `pendingSend` <- the most recent `Instruction` relevant to the current
///   call (e.g. from `TwoWayCoordinator.log`), reusing the existing
///   `Instruction`/`InstructionState` types rather than duplicating them.
/// - `failure` <- `AppModel.conversationRecovery` (`ConversationRecovery` is
///   an AttacheApp type wrapping `ConversationFailureCategory` plus a
///   message; `CallSignals.Failure` carries just those two fields across the
///   module boundary).
public struct CallSignals: Equatable {
    /// The subset of `ConversationRecovery` (AttacheApp) that a call-phase
    /// decision needs: the structural category and the message to show.
    /// Not a redeclaration of `ConversationRecovery` itself, that type keeps
    /// its extra fields (`failedPrompt`, `offersModelSwitch`) in AttacheApp.
    public struct Failure: Equatable {
        public var category: ConversationFailureCategory
        public var message: String

        public init(category: ConversationFailureCategory, message: String) {
            self.category = category
            self.message = message
        }
    }

    public var isConversing: Bool
    public var conversationWaitStartedAt: Date?
    public var micIsListening: Bool
    public var micIsPreparing: Bool
    public var voiceInputMode: String
    public var playbackIsPlaying: Bool
    public var playbackIsPaused: Bool
    public var playbackIsBusy: Bool
    public var isComposingNarration: Bool
    public var pendingAssistantReply: String?
    public var pendingSend: Instruction?
    public var failure: Failure?
    /// Set for as long as an auto-fallback hop's announcement should be
    /// shown (INF-258/D5); `AppModel.conversationFallbackAnnouncement`.
    public var fallbackAnnouncement: String?

    public init(
        isConversing: Bool = false,
        conversationWaitStartedAt: Date? = nil,
        micIsListening: Bool = false,
        micIsPreparing: Bool = false,
        voiceInputMode: String = "pushToTalk",
        playbackIsPlaying: Bool = false,
        playbackIsPaused: Bool = false,
        playbackIsBusy: Bool = false,
        isComposingNarration: Bool = false,
        pendingAssistantReply: String? = nil,
        pendingSend: Instruction? = nil,
        failure: Failure? = nil,
        fallbackAnnouncement: String? = nil
    ) {
        self.isConversing = isConversing
        self.conversationWaitStartedAt = conversationWaitStartedAt
        self.micIsListening = micIsListening
        self.micIsPreparing = micIsPreparing
        self.voiceInputMode = voiceInputMode
        self.playbackIsPlaying = playbackIsPlaying
        self.playbackIsPaused = playbackIsPaused
        self.playbackIsBusy = playbackIsBusy
        self.isComposingNarration = isComposingNarration
        self.pendingAssistantReply = pendingAssistantReply
        self.pendingSend = pendingSend
        self.failure = failure
        self.fallbackAnnouncement = fallbackAnnouncement
    }
}

extension CallPhase {
    /// Pure reducer from a signal snapshot to the phase the UI should show.
    ///
    /// Precedence (highest first), chosen so the two things a user must not
    /// miss are never covered by anything else:
    ///
    /// 1. `listening`         - the mic is live; nothing should cover it.
    /// 2. `failed`            - a conversation or send failure needs attention.
    /// 3. `fallbackAnnounced` - a fallback hop just happened (INF-258/D5);
    ///    ranked with `failed` since both are "something just happened,
    ///    worth interrupting `thinking`/`speaking` to say so" - a manual
    ///    failure and an auto-fallback announcement are mutually exclusive
    ///    in practice (the latter only exists when `failure` was cleared
    ///    instead of surfaced), so this ordering is never actually contested.
    /// 4. `thinking`
    /// 5. `speaking`
    /// 6. `paused`
    /// 7. `preparingAudio`
    /// 8. `sendDelivered`
    /// 9. `sendQueued`
    /// 10. `idle`              - fallback.
    ///
    /// Two consequences called out by the ticket follow directly from this
    /// order: `speaking` beats a lingering `sendDelivered` (4 before 7), and
    /// `failed` beats everything except an active mic (2 right after 1).
    ///
    /// A failure can come from either signal: `signals.failure` (a live
    /// conversation/personality call failed) or `signals.pendingSend` being in
    /// `.failed` state (a Tell Agent delivery failed). If both are present,
    /// the conversation failure wins, since it is the more direct signal about
    /// the call itself; a stale failed send is secondary.
    ///
    /// If `isConversing` is true but `conversationWaitStartedAt` is nil (a
    /// signal combination that should not happen in practice), this falls
    /// back to `.distantPast` rather than sampling the wall clock, to keep the
    /// function pure.
    public static func derive(from signals: CallSignals) -> CallPhase {
        if signals.micIsPreparing || signals.micIsListening {
            let mode = signals.micIsPreparing ? "preparing" : signals.voiceInputMode
            return .listening(mode: mode)
        }

        if let failure = signals.failure {
            return .failed(failure.category, message: failure.message)
        }
        if let send = signals.pendingSend, send.state == .failed {
            let trimmed = send.error?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = (trimmed?.isEmpty == false) ? trimmed! : "Send failed."
            return .failed(.other, message: message)
        }

        if let announcement = signals.fallbackAnnouncement {
            return .fallbackAnnounced(message: announcement)
        }

        if signals.isConversing {
            return .thinking(since: signals.conversationWaitStartedAt ?? .distantPast)
        }

        if signals.playbackIsPlaying {
            return .speaking
        }
        if signals.playbackIsPaused {
            return .paused
        }

        // `playbackIsBusy` alone (no `expectingReplyAudio` gate, INF-264
        // follow-up): synthesis for ANY card, including a watched session's
        // narrated reply to a Tell Agent instruction, not just a live
        // conversation turn's reply, must show "Preparing audio…" here. The
        // removed top overlay's `topStatusText` checked `playback.isBusy`
        // unconditionally for exactly this reason; gating on
        // `expectingReplyAudio` (conversation-turn-only) left the Tell Agent
        // reply's synthesis window with nothing to show once `.sendDelivered`
        // itself expired past its emphasis window, a real dead-air regression
        // caught in production.
        //
        // `isComposingNarration` covers the earlier half of that same window
        // this alone missed: the LLM call that writes the reply's recap runs
        // BEFORE `playbackIsBusy` ever goes true (TTS only starts once that
        // text exists), so without it the composer went blank again for
        // however long that call took.
        if signals.playbackIsBusy || signals.isComposingNarration || signals.pendingAssistantReply != nil {
            return .preparingAudio
        }

        if let send = signals.pendingSend {
            let target = send.targetDisplayName ?? "the agent"
            switch send.state {
            case .delivered where send.resultingCardID == nil:
                // `deliveredAt` should always be set once an instruction
                // reaches `.delivered` (`InstructionReplyEngine` sets it at
                // the same transition); `.distantPast` is a defensive
                // fallback for that otherwise-impossible case, chosen so an
                // instruction with no known delivery time reads as
                // immediately stale rather than staying "fresh" forever.
                return .sendDelivered(target: target, deliveredAt: send.deliveredAt ?? .distantPast)
            case .delivered:
                // A real regression this guards against directly: the reply
                // already arrived and got linked (`resultingCardID` set by
                // `TwoWayCoordinator.linkResponseCard`) - `state` itself never
                // moves off `.delivered` for a completed round trip (there is
                // no separate "replied" state), so without this check the
                // composer kept counting up a "Waiting for X to reply…" timer
                // forever for an instruction that had already been answered,
                // possibly many turns ago. Nothing left to show for it here;
                // fall through toward `.idle` the same as `.failed`/`.canceled`.
                break
            case .pending:
                // Not confirmed yet: the wait is on the user, not the session.
                return .sendQueued(
                    target: target,
                    since: send.createdAt,
                    reason: "Waiting for you to confirm the send to \(target)"
                )
            case .confirmed:
                // Confirmed: the only thing left to wait on is the target
                // session going idle (docs/two-way.md Idle detection), so name
                // that explicitly instead of leaving the UI to guess (INF-248/B3).
                // Wording matches AppModel.confirmStagedInstruction's off-call
                // status verbatim (before the elapsed-time suffix
                // `CallStatusPresentation` appends) so on-call and off-call
                // never drift apart for the same underlying wait.
                return .sendQueued(
                    target: target,
                    since: send.confirmedAt ?? send.createdAt,
                    reason: "Sending to \(target) when the session is quiet"
                )
            case .delivering:
                // The resume is actually running now, and a working turn can
                // legitimately take minutes. Saying "when the session is
                // quiet" here read as a stuck queue during a real 5-minute
                // delivery (2026-07-11); name the phase that is actually
                // happening, counted from when the spawn started.
                return .sendQueued(
                    target: target,
                    since: send.deliveringAt ?? send.confirmedAt ?? send.createdAt,
                    reason: "Delivering to \(target), it may keep working before it answers"
                )
            case .failed, .canceled:
                break
            }
        }

        return .idle
    }
}
