import XCTest
@testable import AttacheCore

final class CompanionActivityStateTests: XCTestCase {
    /// A snapshot with every ambient signal lit at once, so precedence tests
    /// can peel layers off the top one at a time.
    private func everythingAtOnce() -> CompanionActivitySignals {
        CompanionActivitySignals(
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

    func testBlockedOnUserOverridesEverything() {
        let state = CompanionActivityState.derive(from: everythingAtOnce())
        XCTAssertEqual(state.phase, .blockedOnUser)
        XCTAssertEqual(state.activeAgent, .claude)
    }

    func testSpeakingBeatsEverythingExceptBlocked() {
        var signals = everythingAtOnce()
        signals.blockedAgent = nil
        let state = CompanionActivityState.derive(from: signals)
        XCTAssertEqual(state.phase, .speaking)
        XCTAssertEqual(state.activeAgent, .codex)
    }

    func testPausedPlaybackStillOwnsTheStage() {
        var signals = everythingAtOnce()
        signals.blockedAgent = nil
        signals.playbackIsPaused = true
        let state = CompanionActivityState.derive(from: signals)
        XCTAssertEqual(state.phase, .paused)
        XCTAssertEqual(state.activeAgent, .codex)
    }

    func testErrorBeatsRespondingButNotSpeech() {
        var signals = everythingAtOnce()
        signals.blockedAgent = nil
        signals.playbackIsPlaying = false
        let state = CompanionActivityState.derive(from: signals)
        XCTAssertEqual(state.phase, .error)
        XCTAssertEqual(state.activeAgent, .codex)
    }

    func testConversationFailureReadsAsErrorWithNoBubble() {
        let signals = CompanionActivitySignals(
            hasPinnedSessions: true,
            workingAgent: .codex,
            hasConversationFailure: true
        )
        let state = CompanionActivityState.derive(from: signals)
        XCTAssertEqual(state.phase, .error)
        XCTAssertEqual(state.activeAgent, .none)
    }

    func testRespondingBeatsToolRunning() {
        var signals = everythingAtOnce()
        signals.blockedAgent = nil
        signals.erroredAgent = nil
        signals.hasConversationFailure = false
        signals.playbackIsPlaying = false
        let state = CompanionActivityState.derive(from: signals)
        XCTAssertEqual(state.phase, .agentResponding)
        XCTAssertEqual(state.activeAgent, .claude)
    }

    func testToolRunningBeatsThinkingAndCarriesKind() {
        let signals = CompanionActivitySignals(
            hasPinnedSessions: true,
            workingAgent: .claude,
            toolAgent: .codex,
            toolKind: .edit,
            isConversing: true
        )
        let state = CompanionActivityState.derive(from: signals)
        XCTAssertEqual(state.phase, .toolRunning)
        XCTAssertEqual(state.activeAgent, .codex)
        XCTAssertEqual(state.toolKind, .edit)
    }

    func testThinkingFromAWorkingSession() {
        let signals = CompanionActivitySignals(hasPinnedSessions: true, workingAgent: .claude)
        let state = CompanionActivityState.derive(from: signals)
        XCTAssertEqual(state.phase, .agentThinking)
        XCTAssertEqual(state.activeAgent, .claude)
    }

    func testThinkingFromALiveConversationHasNoBubble() {
        let signals = CompanionActivitySignals(isConversing: true)
        let state = CompanionActivityState.derive(from: signals)
        XCTAssertEqual(state.phase, .agentThinking)
        XCTAssertEqual(state.activeAgent, .none)
    }

    func testIdleWhenSessionsArePinnedButQuiet() {
        let signals = CompanionActivitySignals(hasPinnedSessions: true)
        XCTAssertEqual(CompanionActivityState.derive(from: signals).phase, .idle)
    }

    func testSleepingWhenNothingIsPinned() {
        XCTAssertEqual(CompanionActivityState.derive(from: CompanionActivitySignals()).phase, .sleeping)
    }

    func testSpeakingWinsEvenWithNothingPinned() {
        // A general (non-session) card narrating must never render a sleeping
        // face over live speech.
        let signals = CompanionActivitySignals(playbackIsPlaying: true)
        let state = CompanionActivityState.derive(from: signals)
        XCTAssertEqual(state.phase, .speaking)
        XCTAssertEqual(state.activeAgent, .none)
    }

    // MARK: Tool kind hygiene

    func testToolKindClearedOutsideToolRunning() {
        var signals = everythingAtOnce()
        signals.blockedAgent = nil
        let speaking = CompanionActivityState.derive(from: signals)
        XCTAssertEqual(speaking.phase, .speaking)
        XCTAssertNil(speaking.toolKind)
    }

    func testToolSignalWithoutAgentStillRuns() {
        let signals = CompanionActivitySignals(hasPinnedSessions: true, toolKind: .web)
        let state = CompanionActivityState.derive(from: signals)
        XCTAssertEqual(state.phase, .toolRunning)
        XCTAssertEqual(state.activeAgent, .none)
        XCTAssertEqual(state.toolKind, .web)
    }

    // MARK: Ambient pass-through

    func testAmbientFieldsPassThrough() {
        var signals = CompanionActivitySignals(hasPinnedSessions: true)
        signals.userTyping = true
        signals.unreadCount = 4
        signals.hasCards = true
        let state = CompanionActivityState.derive(from: signals)
        XCTAssertTrue(state.userTyping)
        XCTAssertEqual(state.unreadCount, 4)
        XCTAssertTrue(state.hasCards)
    }

    func testWithAudioReplacesOnlyTheAudioFrame() {
        let state = CompanionActivityState(
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
        XCTAssertEqual(CompanionAgentIdentity(sourceKindRawValue: "codex"), .codex)
        XCTAssertEqual(CompanionAgentIdentity(sourceKindRawValue: "claude_code"), .claude)
        XCTAssertEqual(CompanionAgentIdentity(sourceKindRawValue: "generic"), .none)
        XCTAssertEqual(CompanionAgentIdentity(sourceKindRawValue: nil), .none)
    }

    // MARK: Tool kind classification

    func testClassifyEditEventHintAlwaysEdits() {
        XCTAssertEqual(CompanionToolKind.classify(phrase: "editing files", sourceHint: "editEvent"), .edit)
    }

    func testClassifyExternalToolsReadAsWeb() {
        XCTAssertEqual(CompanionToolKind.classify(phrase: "checking Linear", sourceHint: "externalTool"), .web)
        XCTAssertEqual(CompanionToolKind.classify(phrase: "searching web", sourceHint: "externalTool"), .web)
        XCTAssertEqual(CompanionToolKind.classify(phrase: "finding tools", sourceHint: "externalTool"), .other)
    }

    func testClassifyIntentPhrases() {
        XCTAssertEqual(CompanionToolKind.classify(phrase: "editing files", sourceHint: "toolIntent"), .edit)
        XCTAssertEqual(CompanionToolKind.classify(phrase: "reading files", sourceHint: "toolIntent"), .read)
        XCTAssertEqual(CompanionToolKind.classify(phrase: "searching code", sourceHint: "toolIntent"), .read)
        XCTAssertEqual(CompanionToolKind.classify(phrase: "checking git", sourceHint: "toolIntent"), .read)
        XCTAssertEqual(CompanionToolKind.classify(phrase: "running tests", sourceHint: "toolIntent"), .shell)
        XCTAssertEqual(CompanionToolKind.classify(phrase: "building app", sourceHint: "toolIntent"), .shell)
        XCTAssertEqual(CompanionToolKind.classify(phrase: "calling endpoint", sourceHint: "toolIntent"), .web)
        XCTAssertEqual(CompanionToolKind.classify(phrase: "updating plan", sourceHint: "toolIntent"), .other)
        XCTAssertEqual(CompanionToolKind.classify(phrase: "delegating work", sourceHint: "toolIntent"), .other)
    }
}
