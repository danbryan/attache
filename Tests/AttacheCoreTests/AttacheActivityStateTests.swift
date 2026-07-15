import XCTest
@testable import AttacheCore

final class AttacheActivityStateTests: XCTestCase {
    /// A snapshot with every ambient signal lit at once, so precedence tests
    /// can peel layers off the top one at a time.
    private func everythingAtOnce() -> AttacheActivitySignals {
        AttacheActivitySignals(
            hasPinnedSessions: true,
            blockedAgent: .claude,
            erroredAgent: .codex,
            workingAgent: .codex,
            respondingAgent: .claude,
            toolAgent: .codex,
            toolKind: .shell,
            playbackIsPlaying: true,
            playbackIsPaused: false,
            speakingAgent: .codex,
            isConversing: true,
            hasConversationFailure: true,
            userTyping: true,
            unreadCount: 3,
            hasCards: true
        )
    }

    // MARK: Precedence, top down

    func testNeedsYouIsNotAPhaseAndNeverOverridesLiveActivity() {
        // A session needing the user no longer becomes the character's phase; it stays
        // lively (here, speaking wins) and the needs-you lives in the ring badge.
        let state = AttacheActivityState.derive(from: everythingAtOnce())
        XCTAssertEqual(state.phase, .speaking)
        XCTAssertEqual(state.activeAgent, .codex)
        XCTAssertNotEqual(state.phase, .blockedOnUser)
    }

    func testLoneNeedsYouLeavesTheCharacterIdleNotBlocked() {
        var signals = everythingAtOnce()
        signals.erroredAgent = nil
        signals.workingAgent = nil
        signals.respondingAgent = nil
        signals.toolAgent = nil
        signals.toolKind = nil
        signals.playbackIsPlaying = false
        signals.speakingAgent = nil
        signals.isConversing = false
        signals.hasConversationFailure = false
        // Only a needs-you session and a pinned session remain.
        let state = AttacheActivityState.derive(from: signals)
        XCTAssertEqual(state.phase, .idle, "a lone needs-you session leaves the character idle; the badge carries the reminder")
    }

    func testSpeakingBeatsEverythingExceptBlocked() {
        var signals = everythingAtOnce()
        signals.blockedAgent = nil
        let state = AttacheActivityState.derive(from: signals)
        XCTAssertEqual(state.phase, .speaking)
        XCTAssertEqual(state.activeAgent, .codex)
    }

    func testPausedPlaybackStillOwnsTheStage() {
        var signals = everythingAtOnce()
        signals.blockedAgent = nil
        signals.playbackIsPaused = true
        let state = AttacheActivityState.derive(from: signals)
        XCTAssertEqual(state.phase, .paused)
        XCTAssertEqual(state.activeAgent, .codex)
    }

    func testErrorBeatsRespondingButNotSpeech() {
        var signals = everythingAtOnce()
        signals.blockedAgent = nil
        signals.playbackIsPlaying = false
        let state = AttacheActivityState.derive(from: signals)
        XCTAssertEqual(state.phase, .error)
        XCTAssertEqual(state.activeAgent, .codex)
    }

    func testConversationFailureReadsAsErrorWithNoBubble() {
        let signals = AttacheActivitySignals(
            hasPinnedSessions: true,
            workingAgent: .codex,
            hasConversationFailure: true
        )
        let state = AttacheActivityState.derive(from: signals)
        XCTAssertEqual(state.phase, .error)
        XCTAssertEqual(state.activeAgent, .none)
    }

    func testRespondingBeatsToolRunning() {
        var signals = everythingAtOnce()
        signals.blockedAgent = nil
        signals.erroredAgent = nil
        signals.hasConversationFailure = false
        signals.playbackIsPlaying = false
        let state = AttacheActivityState.derive(from: signals)
        XCTAssertEqual(state.phase, .agentResponding)
        XCTAssertEqual(state.activeAgent, .claude)
    }

    func testToolRunningBeatsThinkingAndCarriesKind() {
        let signals = AttacheActivitySignals(
            hasPinnedSessions: true,
            workingAgent: .claude,
            toolAgent: .codex,
            toolKind: .edit,
            isConversing: true
        )
        let state = AttacheActivityState.derive(from: signals)
        XCTAssertEqual(state.phase, .toolRunning)
        XCTAssertEqual(state.activeAgent, .codex)
        XCTAssertEqual(state.toolKind, .edit)
    }

    func testThinkingFromAWorkingSession() {
        let signals = AttacheActivitySignals(hasPinnedSessions: true, workingAgent: .claude)
        let state = AttacheActivityState.derive(from: signals)
        XCTAssertEqual(state.phase, .agentThinking)
        XCTAssertEqual(state.activeAgent, .claude)
    }

    func testThinkingFromALiveConversationHasNoBubble() {
        let signals = AttacheActivitySignals(isConversing: true)
        let state = AttacheActivityState.derive(from: signals)
        XCTAssertEqual(state.phase, .agentThinking)
        XCTAssertEqual(state.activeAgent, .none)
    }

    func testIdleWhenSessionsArePinnedButQuiet() {
        let signals = AttacheActivitySignals(hasPinnedSessions: true)
        XCTAssertEqual(AttacheActivityState.derive(from: signals).phase, .idle)
    }

    func testSleepingWhenNothingIsPinned() {
        XCTAssertEqual(AttacheActivityState.derive(from: AttacheActivitySignals()).phase, .sleeping)
    }

    func testSpeakingWinsEvenWithNothingPinned() {
        // A general (non-session) card narrating must never render a sleeping
        // face over live speech.
        let signals = AttacheActivitySignals(playbackIsPlaying: true)
        let state = AttacheActivityState.derive(from: signals)
        XCTAssertEqual(state.phase, .speaking)
        XCTAssertEqual(state.activeAgent, .none)
    }

    // MARK: Tool kind hygiene

    func testToolKindClearedOutsideToolRunning() {
        var signals = everythingAtOnce()
        signals.blockedAgent = nil
        let speaking = AttacheActivityState.derive(from: signals)
        XCTAssertEqual(speaking.phase, .speaking)
        XCTAssertNil(speaking.toolKind)
    }

    func testToolSignalWithoutAgentStillRuns() {
        let signals = AttacheActivitySignals(hasPinnedSessions: true, toolKind: .web)
        let state = AttacheActivityState.derive(from: signals)
        XCTAssertEqual(state.phase, .toolRunning)
        XCTAssertEqual(state.activeAgent, .none)
        XCTAssertEqual(state.toolKind, .web)
    }

    // MARK: Ambient pass-through

    func testAmbientFieldsPassThrough() {
        var signals = AttacheActivitySignals(hasPinnedSessions: true)
        signals.userTyping = true
        signals.unreadCount = 4
        signals.hasCards = true
        let state = AttacheActivityState.derive(from: signals)
        XCTAssertTrue(state.userTyping)
        XCTAssertEqual(state.unreadCount, 4)
        XCTAssertTrue(state.hasCards)
    }

    func testWithAudioReplacesOnlyTheAudioFrame() {
        let state = AttacheActivityState(
            phase: .toolRunning,
            activeAgent: .codex,
            toolKind: .shell,
            userTyping: true,
            unreadCount: 2,
            hasCards: true
        )
        var frame = AnalysisFrame()
        frame.rms = 0.8
        frame.bands = [Float](repeating: 0.5, count: 56)
        var audio = VisualizerRenderState()
        audio.apply(frame)
        let next = state.with(audio: audio)
        XCTAssertEqual(next.phase, .toolRunning)
        XCTAssertEqual(next.activeAgent, .codex)
        XCTAssertEqual(next.toolKind, .shell)
        XCTAssertTrue(next.userTyping)
        XCTAssertEqual(next.unreadCount, 2)
        XCTAssertGreaterThan(next.audio.level, 0)
    }

    // MARK: Agent identity mapping

    func testAgentIdentityFromSourceKindRawValues() {
        XCTAssertEqual(AttacheAgentIdentity(sourceKindRawValue: "codex"), .codex)
        XCTAssertEqual(AttacheAgentIdentity(sourceKindRawValue: "claude_code"), .claude)
        XCTAssertEqual(AttacheAgentIdentity(sourceKindRawValue: "generic"), .none)
        XCTAssertEqual(AttacheAgentIdentity(sourceKindRawValue: nil), .none)
    }

    // MARK: Tool kind classification

    func testClassifyEditEventHintAlwaysEdits() {
        XCTAssertEqual(AttacheToolKind.classify(phrase: "editing files", sourceHint: "editEvent"), .edit)
    }

    func testClassifyExternalToolsReadAsWeb() {
        XCTAssertEqual(AttacheToolKind.classify(phrase: "checking Linear", sourceHint: "externalTool"), .web)
        XCTAssertEqual(AttacheToolKind.classify(phrase: "searching web", sourceHint: "externalTool"), .web)
        XCTAssertEqual(AttacheToolKind.classify(phrase: "finding tools", sourceHint: "externalTool"), .other)
    }

    func testClassifyIntentPhrases() {
        XCTAssertEqual(AttacheToolKind.classify(phrase: "editing files", sourceHint: "toolIntent"), .edit)
        XCTAssertEqual(AttacheToolKind.classify(phrase: "reading files", sourceHint: "toolIntent"), .read)
        XCTAssertEqual(AttacheToolKind.classify(phrase: "searching code", sourceHint: "toolIntent"), .read)
        XCTAssertEqual(AttacheToolKind.classify(phrase: "checking git", sourceHint: "toolIntent"), .read)
        XCTAssertEqual(AttacheToolKind.classify(phrase: "running tests", sourceHint: "toolIntent"), .shell)
        XCTAssertEqual(AttacheToolKind.classify(phrase: "building app", sourceHint: "toolIntent"), .shell)
        XCTAssertEqual(AttacheToolKind.classify(phrase: "calling endpoint", sourceHint: "toolIntent"), .web)
        XCTAssertEqual(AttacheToolKind.classify(phrase: "updating plan", sourceHint: "toolIntent"), .other)
        XCTAssertEqual(AttacheToolKind.classify(phrase: "delegating work", sourceHint: "toolIntent"), .other)
    }
}
