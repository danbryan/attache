import XCTest
@testable import AttacheApp
@testable import AttacheCore

final class CallStatusPresentationTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - idle renders nothing

    func testIdleRendersNoStatus() {
        XCTAssertNil(CallStatusPresentation.status(for: .idle, now: referenceDate))
    }

    // MARK: - listening

    func testListeningWhilePreparingShowsStartingMicrophone() {
        let status = CallStatusPresentation.status(for: .listening(mode: "preparing"), now: referenceDate)
        XCTAssertEqual(status?.text, "Starting microphone…")
        XCTAssertEqual(status?.icon, .symbol("mic.fill"))
        XCTAssertFalse(status?.isError ?? true)
    }

    func testListeningInPushToTalkModeExplainsReleaseToSend() {
        let status = CallStatusPresentation.status(for: .listening(mode: "pushToTalk"), now: referenceDate)
        XCTAssertEqual(status?.text, "Release the mic to send this turn.")
    }

    func testListeningInToggleModeExplainsClickToSend() {
        let status = CallStatusPresentation.status(for: .listening(mode: "toggle"), now: referenceDate)
        XCTAssertEqual(status?.text, "Click the mic again to send this turn.")
    }

    func testListeningInAlwaysOnModeExplainsPauseToSend() {
        let status = CallStatusPresentation.status(for: .listening(mode: "alwaysOn"), now: referenceDate)
        XCTAssertEqual(status?.text, "Pause briefly to send this turn.")
    }

    // MARK: - thinking (elapsed seconds)

    func testThinkingWithNoElapsedTimeShowsBareEllipsis() {
        let status = CallStatusPresentation.status(for: .thinking(since: referenceDate), now: referenceDate)
        XCTAssertEqual(status?.text, "Thinking…")
        XCTAssertEqual(status?.icon, .spinner)
    }

    func testThinkingWithElapsedSecondsAppendsCompactLabel() {
        let status = CallStatusPresentation.status(
            for: .thinking(since: referenceDate),
            now: referenceDate.addingTimeInterval(4)
        )
        XCTAssertEqual(status?.text, "Thinking… 4s")
    }

    func testThinkingPastAMinuteUsesMinuteSecondLabel() {
        let status = CallStatusPresentation.status(
            for: .thinking(since: referenceDate),
            now: referenceDate.addingTimeInterval(64)
        )
        XCTAssertEqual(status?.text, "Thinking… 1:04")
    }

    // MARK: - preparingAudio / speaking / paused

    func testPreparingAudioUsesTheSharedWording() {
        let status = CallStatusPresentation.status(for: .preparingAudio, now: referenceDate)
        XCTAssertEqual(status?.text, CallStatusPresentation.preparingAudioText)
        XCTAssertEqual(status?.text, "Preparing audio…")
    }

    func testSpeakingShowsSpeakingEllipsis() {
        let status = CallStatusPresentation.status(for: .speaking, now: referenceDate)
        XCTAssertEqual(status?.text, "Speaking…")
    }

    func testPausedShowsPlaybackPaused() {
        let status = CallStatusPresentation.status(for: .paused, now: referenceDate)
        XCTAssertEqual(status?.text, "Playback paused")
    }

    // MARK: - sendQueued (elapsed seconds, reason override)

    func testSendQueuedWithNoReasonDescribesWaitingForQuiet() {
        let status = CallStatusPresentation.status(
            for: .sendQueued(target: "Weekly Codex Improvement Review", since: referenceDate, reason: nil),
            now: referenceDate.addingTimeInterval(12)
        )
        XCTAssertEqual(status?.text, "Sending to Weekly Codex Improvement Review when the session is quiet… 12s")
        XCTAssertEqual(status?.icon, .spinner)
        XCTAssertFalse(status?.isError ?? true)
    }

    func testSendQueuedWithNoElapsedTimeOmitsTheCounter() {
        let status = CallStatusPresentation.status(
            for: .sendQueued(target: "Weekly Codex Improvement Review", since: referenceDate, reason: nil),
            now: referenceDate
        )
        XCTAssertEqual(status?.text, "Sending to Weekly Codex Improvement Review when the session is quiet…")
    }

    func testSendQueuedWithAnExplicitReasonUsesItInsteadOfTheDefault() {
        let status = CallStatusPresentation.status(
            for: .sendQueued(target: "Weekly Codex Improvement Review", since: referenceDate, reason: "Waiting because the session is busy"),
            now: referenceDate.addingTimeInterval(5)
        )
        XCTAssertEqual(status?.text, "Waiting because the session is busy… 5s")
    }

    // MARK: - sendDelivered (fresh-delivery emphasis window)

    func testSendDeliveredShowsConfirmationText() {
        let status = CallStatusPresentation.status(for: .sendDelivered(target: "Codex"), now: referenceDate)
        XCTAssertEqual(status?.text, "Sent to Codex · watching for the reply")
        XCTAssertEqual(status?.icon, .symbol("checkmark.circle.fill"))
        XCTAssertFalse(status?.isError ?? true)
    }

    func testSendDeliveredIsFreshWithinTheEmphasisWindow() {
        let status = CallStatusPresentation.status(
            for: .sendDelivered(target: "Codex"),
            now: referenceDate.addingTimeInterval(5),
            deliveredAt: referenceDate
        )
        XCTAssertTrue(status?.isFreshDelivery ?? false)
    }

    func testSendDeliveredLosesEmphasisAfterTheWindowButKeepsItsText() {
        let status = CallStatusPresentation.status(
            for: .sendDelivered(target: "Codex"),
            now: referenceDate.addingTimeInterval(7),
            deliveredAt: referenceDate
        )
        XCTAssertFalse(status?.isFreshDelivery ?? true)
        XCTAssertEqual(status?.text, "Sent to Codex · watching for the reply")
    }

    func testSendDeliveredWithNoDeliveredAtIsNeverFresh() {
        let status = CallStatusPresentation.status(for: .sendDelivered(target: "Codex"), now: referenceDate, deliveredAt: nil)
        XCTAssertFalse(status?.isFreshDelivery ?? true)
    }

    // MARK: - failed (category drives styling, never string matching)

    func testFailedIsAlwaysStyledAsErrorRegardlessOfMessageContent() {
        let status = CallStatusPresentation.status(
            for: .failed(.other, message: "Something without any marker words"),
            now: referenceDate
        )
        XCTAssertTrue(status?.isError ?? false)
        XCTAssertEqual(status?.text, "Something without any marker words")
    }

    func testFailedMessageIsShownVerbatimWithNoPrefixRewriting() {
        // Historically `callStatusDisplayText` rewrote "codex exited"/"claude
        // exited" prefixes into friendlier text via string matching. INF-244
        // deletes that: the message is whatever CallPhase.failed carries.
        let status = CallStatusPresentation.status(
            for: .failed(.other, message: "codex exited with code 1: boom"),
            now: referenceDate
        )
        XCTAssertEqual(status?.text, "codex exited with code 1: boom")
    }

    func testFailedCategoriesEachProduceAnErrorStatus() {
        let categories: [ConversationFailureCategory] = [.usageOrRateLimit, .modelUnavailable, .transient, .auth, .other]
        for category in categories {
            let status = CallStatusPresentation.status(for: .failed(category, message: "failure"), now: referenceDate)
            XCTAssertTrue(status?.isError ?? false, "category \(category) should be styled as an error")
        }
    }

    func testFailedCategoriesUseDistinctIconsDerivedFromTheCategoryNotTheMessageText() {
        XCTAssertEqual(
            CallStatusPresentation.status(for: .failed(.auth, message: "x"), now: referenceDate)?.icon,
            .symbol("lock.fill")
        )
        XCTAssertEqual(
            CallStatusPresentation.status(for: .failed(.usageOrRateLimit, message: "x"), now: referenceDate)?.icon,
            .symbol("exclamationmark.circle.fill")
        )
        XCTAssertEqual(
            CallStatusPresentation.status(for: .failed(.modelUnavailable, message: "x"), now: referenceDate)?.icon,
            .symbol("questionmark.circle.fill")
        )
        XCTAssertEqual(
            CallStatusPresentation.status(for: .failed(.transient, message: "x"), now: referenceDate)?.icon,
            .symbol("wifi.slash")
        )
        XCTAssertEqual(
            CallStatusPresentation.status(for: .failed(.other, message: "x"), now: referenceDate)?.icon,
            .symbol("exclamationmark.triangle.fill")
        )
    }

    // MARK: - Recovery model-switch confirmation (f16 regression coverage)

    func testRecoveryConfirmationReplacesTheFailedMessageWhileStillFailed() {
        // Picking a new model from the recovery menu does not itself change
        // the phase (AppModel's callPhase stays .failed until an actual
        // retry runs), so without this override the composer would keep
        // showing the stale error instead of confirming the switch.
        let status = CallStatusPresentation.status(
            for: .failed(.usageOrRateLimit, message: "LLM request failed with HTTP 429"),
            now: referenceDate,
            recoveryConfirmation: "Switched to Ollama attache-recovery-smoke. Review the restored draft, then retry."
        )
        XCTAssertEqual(status?.text, "Switched to Ollama attache-recovery-smoke. Review the restored draft, then retry.")
        XCTAssertFalse(status?.isError ?? true)
        XCTAssertEqual(status?.icon, .symbol("checkmark.circle.fill"))
    }

    func testNoRecoveryConfirmationLeavesFailedStatusUnchanged() {
        let status = CallStatusPresentation.status(
            for: .failed(.usageOrRateLimit, message: "LLM request failed with HTTP 429"),
            now: referenceDate,
            recoveryConfirmation: nil
        )
        XCTAssertEqual(status?.text, "LLM request failed with HTTP 429")
        XCTAssertTrue(status?.isError ?? false)
    }

    func testRecoveryConfirmationHasNoEffectOnNonFailedPhases() {
        let status = CallStatusPresentation.status(
            for: .thinking(since: referenceDate),
            now: referenceDate,
            recoveryConfirmation: "Switched to Ollama x"
        )
        XCTAssertEqual(status?.text, "Thinking…")
    }

    // MARK: - fallbackAnnounced (INF-258/D5)

    func testFallbackAnnouncedShowsTheMessageWithNeutralStyling() {
        let status = CallStatusPresentation.status(
            for: .fallbackAnnounced(message: "xAI / Grok hit its usage limit; using Ollama for now."),
            now: referenceDate
        )
        XCTAssertEqual(status?.text, "xAI / Grok hit its usage limit; using Ollama for now.")
        XCTAssertFalse(status?.isError ?? true, "an auto-fallback hop is not an error the user must act on")
        XCTAssertFalse(status?.isFreshDelivery ?? true)
    }

    // MARK: - Every phase is visually distinct (success criterion)

    func testEveryNonIdlePhaseProducesADistinctStatus() {
        let phases: [CallPhase] = [
            .listening(mode: "toggle"),
            .thinking(since: referenceDate),
            .preparingAudio,
            .speaking,
            .paused,
            .sendQueued(target: "Codex", since: referenceDate, reason: nil),
            .sendDelivered(target: "Codex"),
            .failed(.other, message: "boom"),
            .fallbackAnnounced(message: "Grok hit its usage limit; using Ollama for now.")
        ]
        let rendered = phases.map { CallStatusPresentation.status(for: $0, now: referenceDate) }
        XCTAssertTrue(rendered.allSatisfy { $0 != nil })
        let texts = rendered.compactMap { $0?.text }
        XCTAssertEqual(Set(texts).count, texts.count, "expected every phase to render distinct text, got: \(texts)")
    }
}
