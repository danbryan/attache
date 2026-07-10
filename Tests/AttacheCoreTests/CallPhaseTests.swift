import XCTest
@testable import AttacheCore

final class CallPhaseTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func instruction(
        state: InstructionState,
        target: String? = "Weekly Codex Improvement Review",
        createdAt: Date? = nil,
        confirmedAt: Date? = nil,
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
            error: error,
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

    func testPreparingAudioWhenExpectingReplyAudioAndPlaybackIsBusy() {
        let signals = CallSignals(playbackIsBusy: true, expectingReplyAudio: true)
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

    func testSendQueuedForADeliveringInstruction() {
        let signals = CallSignals(pendingSend: instruction(state: .delivering, createdAt: referenceDate))
        XCTAssertEqual(
            CallPhase.derive(from: signals),
            .sendQueued(
                target: "Weekly Codex Improvement Review",
                since: referenceDate,
                reason: "Sending to Weekly Codex Improvement Review when the session is quiet"
            )
        )
    }

    func testSendDeliveredForADeliveredInstruction() {
        let signals = CallSignals(pendingSend: instruction(state: .delivered))
        XCTAssertEqual(CallPhase.derive(from: signals), .sendDelivered(target: "Weekly Codex Improvement Review"))
    }

    func testSendDeliveredFallsBackToGenericTargetWhenNameIsMissing() {
        let signals = CallSignals(pendingSend: instruction(state: .delivered, target: nil))
        XCTAssertEqual(CallPhase.derive(from: signals), .sendDelivered(target: "the agent"))
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
            expectingReplyAudio: true,
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
            playbackIsBusy: true,
            expectingReplyAudio: true
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

    func testSendDeliveredWinsOverSendQueuedWhenSomehowBothWouldApply() {
        // Not reachable through the current single-`pendingSend` signal (only
        // one Instruction, so only one state at a time), but pin the
        // reducer's own precedence for delivered vs. the queued sub-states.
        let delivered = instruction(state: .delivered)
        XCTAssertEqual(
            CallPhase.derive(from: CallSignals(pendingSend: delivered)),
            .sendDelivered(target: "Weekly Codex Improvement Review")
        )
    }

    func testSendQueuedWinsOverIdle() {
        let signals = CallSignals(pendingSend: instruction(state: .confirmed))
        XCTAssertNotEqual(CallPhase.derive(from: signals), .idle)
    }
}
