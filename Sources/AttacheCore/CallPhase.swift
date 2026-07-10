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
    case sendDelivered(target: String)
    /// A conversation call failed, or a Tell Agent delivery failed.
    case failed(ConversationFailureCategory, message: String)
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
/// - `expectingReplyAudio`, `pendingAssistantReply` <-
///   `AppModel.expectingReplyAudio`, `AppModel.pendingAssistantReply`.
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
    public var expectingReplyAudio: Bool
    public var pendingAssistantReply: String?
    public var pendingSend: Instruction?
    public var failure: Failure?

    public init(
        isConversing: Bool = false,
        conversationWaitStartedAt: Date? = nil,
        micIsListening: Bool = false,
        micIsPreparing: Bool = false,
        voiceInputMode: String = "pushToTalk",
        playbackIsPlaying: Bool = false,
        playbackIsPaused: Bool = false,
        playbackIsBusy: Bool = false,
        expectingReplyAudio: Bool = false,
        pendingAssistantReply: String? = nil,
        pendingSend: Instruction? = nil,
        failure: Failure? = nil
    ) {
        self.isConversing = isConversing
        self.conversationWaitStartedAt = conversationWaitStartedAt
        self.micIsListening = micIsListening
        self.micIsPreparing = micIsPreparing
        self.voiceInputMode = voiceInputMode
        self.playbackIsPlaying = playbackIsPlaying
        self.playbackIsPaused = playbackIsPaused
        self.playbackIsBusy = playbackIsBusy
        self.expectingReplyAudio = expectingReplyAudio
        self.pendingAssistantReply = pendingAssistantReply
        self.pendingSend = pendingSend
        self.failure = failure
    }
}

extension CallPhase {
    /// Pure reducer from a signal snapshot to the phase the UI should show.
    ///
    /// Precedence (highest first), chosen so the two things a user must not
    /// miss are never covered by anything else:
    ///
    /// 1. `listening`      - the mic is live; nothing should cover it.
    /// 2. `failed`         - a conversation or send failure needs attention.
    /// 3. `thinking`
    /// 4. `speaking`
    /// 5. `paused`
    /// 6. `preparingAudio`
    /// 7. `sendDelivered`
    /// 8. `sendQueued`
    /// 9. `idle`           - fallback.
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

        if signals.isConversing {
            return .thinking(since: signals.conversationWaitStartedAt ?? .distantPast)
        }

        if signals.playbackIsPlaying {
            return .speaking
        }
        if signals.playbackIsPaused {
            return .paused
        }

        if (signals.expectingReplyAudio && signals.playbackIsBusy) || signals.pendingAssistantReply != nil {
            return .preparingAudio
        }

        if let send = signals.pendingSend {
            let target = send.targetDisplayName ?? "the agent"
            switch send.state {
            case .delivered:
                return .sendDelivered(target: target)
            case .pending:
                // Not confirmed yet: the wait is on the user, not the session.
                return .sendQueued(
                    target: target,
                    since: send.createdAt,
                    reason: "Waiting for you to confirm the send to \(target)"
                )
            case .confirmed, .delivering:
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
            case .failed, .canceled:
                break
            }
        }

        return .idle
    }
}
