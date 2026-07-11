import XCTest
@testable import AttacheCore

final class CallPhaseTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func instruction(
        state: InstructionState,
        target: String? = "Weekly Codex Improvement Review",
        createdAt: Date? = nil,
        confirmedAt: Date? = nil,
        deliveringAt: Date? = nil,
        deliveredAt: Date? = nil,
        resultingCardID: String? = nil,
        error: String? = nil
    ) -> Instruction {
        Instruction(
            id: "instr-1",
            sessionID: "session-1",
            sourceKind: "codex",
            text: "run the tests",
            state: state,
            createdAt: createdAt ?? referenceDate,
            confirmedAt: confirmedAt,
            deliveredAt: deliveredAt,
            deliveringAt: deliveringAt,
            error: error,
            resultingCardID: resultingCardID,
            origin: .tellAgent,
            targetDisplayName: target
        )
    }

    // MARK: Every phase, signals in isolation

    func testIdleIsTheDefaultWithNoSignals() {
        XCTAssertEqual(CallPhase.derive(from: CallSignals()), .idle)
    }

    func testListeningWhenMicIsListening() {
        let signals = CallSignals(micIsListening: true, voiceInputMode: "toggle")
        XCTAssertEqual(CallPhase.derive(from: signals), .listening(mode: "toggle"))
    }

    func testListeningReportsPreparingModeWhileMicIsStartingUp() {
        let signals = CallSignals(micIsPreparing: true, voiceInputMode: "alwaysOn")
        XCTAssertEqual(CallPhase.derive(from: signals), .listening(mode: "preparing"))
    }

    func testThinkingCarriesTheWaitStartTime() {
        let signals = CallSignals(isConversing: true, conversationWaitStartedAt: referenceDate)
        XCTAssertEqual(CallPhase.derive(from: signals), .thinking(since: referenceDate))
    }

    func testThinkingFallsBackToDistantPastWithoutSamplingTheClock() {
        // isConversing true with no recorded start time should not happen in
        // practice, but the reducer must stay pure (no Date() reads), so it
        // resolves deterministically instead of guessing "now".
        let signals = CallSignals(isConversing: true, conversationWaitStartedAt: nil)
        XCTAssertEqual(CallPhase.derive(from: signals), .thinking(since: .distantPast))
    }

    func testPreparingAudioWhenPlaybackIsBusy() {
        // No `expectingReplyAudio` gate (INF-264 follow-up): synthesis for
        // any card, not just a live conversation turn's reply, shows this.
        let signals = CallSignals(playbackIsBusy: true)
        XCTAssertEqual(CallPhase.derive(from: signals), .preparingAudio)
    }

    func testPreparingAudioWhenAssistantReplyIsPendingEvenWithoutBusyPlayback() {
        let signals = CallSignals(pendingAssistantReply: "the reply text")
        XCTAssertEqual(CallPhase.derive(from: signals), .preparingAudio)
    }

    func testSpeakingWhenPlaybackIsPlaying() {
        let signals = CallSignals(playbackIsPlaying: true)
        XCTAssertEqual(CallPhase.derive(from: signals), .speaking)
    }

    func testPausedWhenPlaybackIsPaused() {
        let signals = CallSignals(playbackIsPaused: true)
        XCTAssertEqual(CallPhase.derive(from: signals), .paused)
    }

    func testSendQueuedForAConfirmedInstructionUsesConfirmedAtAsSince() {
        let confirmedAt = referenceDate.addingTimeInterval(5)
        let signals = CallSignals(pendingSend: instruction(
            state: .confirmed,
            createdAt: referenceDate,
            confirmedAt: confirmedAt
        ))
        XCTAssertEqual(
            CallPhase.derive(from: signals),
            .sendQueued(
                target: "Weekly Codex Improvement Review",
                since: confirmedAt,
                reason: "Sending to Weekly Codex Improvement Review when the session is quiet"
            )
        )
    }

    /// INF-248 (B3): a still-`.pending` instruction is waiting on the user's
    /// own confirmation, not on the session going quiet, so its reason must
    /// say so rather than reusing the confirmed/delivering wording.
    func testSendQueuedForAPendingInstructionFallsBackToCreatedAtAsSince() {
        let signals = CallSignals(pendingSend: instruction(state: .pending, createdAt: referenceDate))
        XCTAssertEqual(
            CallPhase.derive(from: signals),
            .sendQueued(
                target: "Weekly Codex Improvement Review",
                since: referenceDate,
                reason: "Waiting for you to confirm the send to Weekly Codex Improvement Review"
            )
        )
    }

    /// Once the resume is actually running, "when the session is quiet" is no
    /// longer the truth (the wait already ended); a long working turn made
    /// that read as a stuck queue (2026-07-11). `.delivering` names the real
    /// phase and counts from when the spawn started.
    func testSendQueuedForADeliveringInstruction() {
        let deliveringAt = referenceDate.addingTimeInterval(9)
        let signals = CallSignals(pendingSend: instruction(state: .delivering, createdAt: referenceDate, deliveringAt: deliveringAt))
        XCTAssertEqual(
            CallPhase.derive(from: signals),
            .sendQueued(
                target: "Weekly Codex Improvement Review",
                since: deliveringAt,
                reason: "Delivering to Weekly Codex Improvement Review, it may keep working before it answers"
            )
        )
    }

    func testDeliveringWithoutATimestampFallsBackToConfirmedAt() {
        let confirmedAt = referenceDate.addingTimeInterval(4)
        let signals = CallSignals(pendingSend: instruction(state: .delivering, createdAt: referenceDate, confirmedAt: confirmedAt))
        guard case .sendQueued(_, let since, _) = CallPhase.derive(from: signals) else {
            return XCTFail("expected sendQueued")
        }
        XCTAssertEqual(since, confirmedAt)
    }

    func testSendDeliveredForADeliveredInstruction() {
        let deliveredAt = referenceDate.addingTimeInterval(30)
        let signals = CallSignals(pendingSend: instruction(state: .delivered, deliveredAt: deliveredAt))
        XCTAssertEqual(
            CallPhase.derive(from: signals),
            .sendDelivered(target: "Weekly Codex Improvement Review", deliveredAt: deliveredAt)
        )
    }

    // A real regression this guards against directly: `state` never moves
    // off `.delivered` once a round trip actually completes (there is no
    // separate "replied" state), and `resultingCardID` is the only signal
    // that the reply already arrived and got linked
    // (`TwoWayCoordinator.linkResponseCard`). Without checking it, the
    // composer kept counting up "Waiting for X to reply… Ns" forever for an
    // instruction that had already been fully answered, possibly many turns
    // and many minutes ago, reported live as "why is this old message still
    // showing?" with a 20+ minute counter on an instruction whose reply had
    // long since been heard.
    func testDeliveredWithAResultingCardIsNotTreatedAsStillAwaitingAReply() {
        let deliveredAt = referenceDate.addingTimeInterval(-3600)
        let signals = CallSignals(
            pendingSend: instruction(state: .delivered, deliveredAt: deliveredAt, resultingCardID: "card-1")
        )
        XCTAssertEqual(CallPhase.derive(from: signals), .idle)
    }

    func testSendDeliveredFallsBackToGenericTargetWhenNameIsMissing() {
        let deliveredAt = referenceDate.addingTimeInterval(30)
        let signals = CallSignals(pendingSend: instruction(state: .delivered, target: nil, deliveredAt: deliveredAt))
        XCTAssertEqual(CallPhase.derive(from: signals), .sendDelivered(target: "the agent", deliveredAt: deliveredAt))
    }

    func testSendDeliveredFallsBackToDistantPastWhenTheInstructionHasNoDeliveredAt() {
        // Defensive-only path: `InstructionReplyEngine` always sets
        // `deliveredAt` when it moves an instruction to `.delivered`, so this
        // covers the otherwise-impossible case where it's missing anyway. It
        // must fall back to something already stale (`.distantPast`), not
        // `now`, so a phase with genuinely unknown delivery time never reads
        // as freshly delivered.
        let signals = CallSignals(pendingSend: instruction(state: .delivered, deliveredAt: nil))
        XCTAssertEqual(
            CallPhase.derive(from: signals),
            .sendDelivered(target: "Weekly Codex Improvement Review", deliveredAt: .distantPast)
        )
    }

    func testCanceledSendIsTreatedAsIdle() {
        let signals = CallSignals(pendingSend: instruction(state: .canceled))
        XCTAssertEqual(CallPhase.derive(from: signals), .idle)
    }

    func testFailedFromAConversationFailureCarriesCategoryAndMessage() {
        let signals = CallSignals(failure: .init(category: .usageOrRateLimit, message: "Grok hit its usage limit."))
        XCTAssertEqual(CallPhase.derive(from: signals), .failed(.usageOrRateLimit, message: "Grok hit its usage limit."))
    }

    func testFailedFromAFailedSendUsesOtherCategoryAndTheInstructionError() {
        let signals = CallSignals(pendingSend: instruction(state: .failed, error: "codex exited with code 1"))
        XCTAssertEqual(CallPhase.derive(from: signals), .failed(.other, message: "codex exited with code 1"))
    }

    func testFailedFromAFailedSendWithNoErrorTextUsesAGenericMessage() {
        let signals = CallSignals(pendingSend: instruction(state: .failed, error: nil))
        XCTAssertEqual(CallPhase.derive(from: signals), .failed(.other, message: "Send failed."))
    }

    func testFailedFromAFailedSendWithBlankErrorTextUsesAGenericMessage() {
        let signals = CallSignals(pendingSend: instruction(state: .failed, error: "   "))
        XCTAssertEqual(CallPhase.derive(from: signals), .failed(.other, message: "Send failed."))
    }

    // MARK: Precedence when signals overlap

    func testListeningWinsOverAConversationFailure() {
        let signals = CallSignals(
            micIsListening: true,
            voiceInputMode: "pushToTalk",
            failure: .init(category: .auth, message: "Credentials expired.")
        )
        XCTAssertEqual(CallPhase.derive(from: signals), .listening(mode: "pushToTalk"))
    }

    func testListeningWinsOverEverythingElseAtOnce() {
        let signals = CallSignals(
            isConversing: true,
            conversationWaitStartedAt: referenceDate,
            micIsListening: true,
            voiceInputMode: "toggle",
            playbackIsPlaying: true,
            playbackIsPaused: true,
            playbackIsBusy: true,
            pendingAssistantReply: "reply",
            pendingSend: instruction(state: .delivered),
            failure: .init(category: .transient, message: "timed out")
        )
        XCTAssertEqual(CallPhase.derive(from: signals), .listening(mode: "toggle"))
    }

    func testFailedWinsOverThinking() {
        let signals = CallSignals(
            isConversing: true,
            conversationWaitStartedAt: referenceDate,
            failure: .init(category: .modelUnavailable, message: "That model is gone.")
        )
        XCTAssertEqual(CallPhase.derive(from: signals), .failed(.modelUnavailable, message: "That model is gone."))
    }

    func testFailedWinsOverSpeakingAndDelivered() {
        let signals = CallSignals(
            playbackIsPlaying: true,
            pendingSend: instruction(state: .delivered),
            failure: .init(category: .transient, message: "Connection lost.")
        )
        XCTAssertEqual(CallPhase.derive(from: signals), .failed(.transient, message: "Connection lost."))
    }

    func testConversationFailureWinsOverAFailedSendWhenBothArePresent() {
        let signals = CallSignals(
            pendingSend: instruction(state: .failed, error: "codex exited with code 1"),
            failure: .init(category: .auth, message: "Credentials expired.")
        )
        XCTAssertEqual(CallPhase.derive(from: signals), .failed(.auth, message: "Credentials expired."))
    }

    func testThinkingWinsOverSpeakingAndSendState() {
        let signals = CallSignals(
            isConversing: true,
            conversationWaitStartedAt: referenceDate,
            playbackIsPlaying: true,
            pendingSend: instruction(state: .delivered)
        )
        XCTAssertEqual(CallPhase.derive(from: signals), .thinking(since: referenceDate))
    }

    func testSpeakingWinsOverSendDelivered() {
        let signals = CallSignals(
            playbackIsPlaying: true,
            pendingSend: instruction(state: .delivered)
        )
        XCTAssertEqual(CallPhase.derive(from: signals), .speaking)
    }

    func testSpeakingWinsOverSendQueued() {
        let signals = CallSignals(
            playbackIsPlaying: true,
            pendingSend: instruction(state: .confirmed)
        )
        XCTAssertEqual(CallPhase.derive(from: signals), .speaking)
    }

    func testSpeakingWinsOverPaused() {
        let signals = CallSignals(playbackIsPlaying: true, playbackIsPaused: true)
        XCTAssertEqual(CallPhase.derive(from: signals), .speaking)
    }

    func testPausedWinsOverPreparingAudio() {
        let signals = CallSignals(
            playbackIsPaused: true,
            playbackIsBusy: true
        )
        XCTAssertEqual(CallPhase.derive(from: signals), .paused)
    }

    func testPreparingAudioWinsOverSendDelivered() {
        let signals = CallSignals(
            pendingAssistantReply: "reply text",
            pendingSend: instruction(state: .delivered)
        )
        XCTAssertEqual(CallPhase.derive(from: signals), .preparingAudio)
    }

    // Real production regression: Tell Agent's reply is narrated through the
    // watched-session recap pipeline, not the live-conversation-turn one, so
    // it never sets `pendingAssistantReply` or (the now-removed)
    // `expectingReplyAudio` - only `playback.isBusy`, while its TTS
    // synthesizes. Once `.sendDelivered` (INF-264) hides itself past its
    // emphasis window, `playbackIsBusy` alone must still produce
    // `.preparingAudio` here, or the composer goes fully blank for as long as
    // that synthesis takes.
    func testPreparingAudioForATellAgentReplyWithNoConversationSignalsAtAll() {
        let deliveredAt = referenceDate.addingTimeInterval(-3600)
        let signals = CallSignals(
            playbackIsBusy: true,
            pendingSend: instruction(state: .delivered, deliveredAt: deliveredAt)
        )
        XCTAssertEqual(CallPhase.derive(from: signals), .preparingAudio)
    }

    // The other half of the same gap: the LLM call that writes a Tell Agent
    // reply's recap runs BEFORE playback.isBusy ever goes true (TTS only
    // starts once that text exists), so isComposingNarration alone - with
    // playbackIsBusy false - must also produce preparingAudio, or the
    // composer goes blank for however long that call takes.
    func testPreparingAudioWhileComposingNarrationEvenBeforePlaybackGoesBusy() {
        let deliveredAt = referenceDate.addingTimeInterval(-3600)
        let signals = CallSignals(
            isComposingNarration: true,
            pendingSend: instruction(state: .delivered, deliveredAt: deliveredAt)
        )
        XCTAssertEqual(CallPhase.derive(from: signals), .preparingAudio)
    }

    func testSendDeliveredWinsOverSendQueuedWhenSomehowBothWouldApply() {
        // Not reachable through the current single-`pendingSend` signal (only
        // one Instruction, so only one state at a time), but pin the
        // reducer's own precedence for delivered vs. the queued sub-states.
        let deliveredAt = referenceDate.addingTimeInterval(30)
        let delivered = instruction(state: .delivered, deliveredAt: deliveredAt)
        XCTAssertEqual(
            CallPhase.derive(from: CallSignals(pendingSend: delivered)),
            .sendDelivered(target: "Weekly Codex Improvement Review", deliveredAt: deliveredAt)
        )
    }

    func testSendQueuedWinsOverIdle() {
        let signals = CallSignals(pendingSend: instruction(state: .confirmed))
        XCTAssertNotEqual(CallPhase.derive(from: signals), .idle)
    }

    // MARK: fallbackAnnounced (INF-258/D5)

    func testFallbackAnnouncedFromASignal() {
        let signals = CallSignals(fallbackAnnouncement: "Grok hit its usage limit; using Ollama for now.")
        XCTAssertEqual(
            CallPhase.derive(from: signals),
            .fallbackAnnounced(message: "Grok hit its usage limit; using Ollama for now.")
        )
    }

    func testListeningWinsOverFallbackAnnounced() {
        let signals = CallSignals(
            micIsListening: true,
            voiceInputMode: "pushToTalk",
            fallbackAnnouncement: "Grok hit its usage limit; using Ollama for now."
        )
        XCTAssertEqual(CallPhase.derive(from: signals), .listening(mode: "pushToTalk"))
    }

    func testFallbackAnnouncedWinsOverThinkingSpeakingAndSendState() {
        let signals = CallSignals(
            isConversing: true,
            conversationWaitStartedAt: referenceDate,
            playbackIsPlaying: true,
            pendingSend: instruction(state: .delivered),
            fallbackAnnouncement: "Grok hit its usage limit; using Ollama for now."
        )
        XCTAssertEqual(
            CallPhase.derive(from: signals),
            .fallbackAnnounced(message: "Grok hit its usage limit; using Ollama for now.")
        )
    }

    func testConversationFailureWinsOverFallbackAnnouncedWhenSomehowBothArePresent() {
        // Not reachable in practice (AppModel never sets both at once: the
        // auto-fallback path deliberately keeps `conversationRecovery` nil),
        // but pins the reducer's own total order the same way the file's
        // other "somehow both" tests do.
        let signals = CallSignals(
            failure: .init(category: .auth, message: "Credentials expired."),
            fallbackAnnouncement: "Grok hit its usage limit; using Ollama for now."
        )
        XCTAssertEqual(CallPhase.derive(from: signals), .failed(.auth, message: "Credentials expired."))
    }
}
