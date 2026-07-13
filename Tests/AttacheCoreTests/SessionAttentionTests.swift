import XCTest
@testable import AttacheCore

final class SessionAttentionTests: XCTestCase {
    private let now = TranscriptParser.parseDate("2026-07-03T12:10:00.000Z")!

    private func stamp(_ secondsAgo: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: now.addingTimeInterval(-secondsAgo))
    }

    private func claudeAssistantText(_ text: String, secondsAgo: TimeInterval) -> String {
        """
        {"type":"assistant","timestamp":"\(stamp(secondsAgo))","message":{"content":[{"type":"text","text":"\(text)"}]}}
        """
    }

    private func claudeToolUse(name: String, id: String, secondsAgo: TimeInterval) -> String {
        """
        {"type":"assistant","timestamp":"\(stamp(secondsAgo))","message":{"content":[{"type":"tool_use","name":"\(name)","id":"\(id)"}]}}
        """
    }

    private func claudeToolResult(id: String, secondsAgo: TimeInterval) -> String {
        """
        {"type":"user","timestamp":"\(stamp(secondsAgo))","message":{"content":[{"type":"tool_result","tool_use_id":"\(id)"}]}}
        """
    }

    private func claudeUserMessage(secondsAgo: TimeInterval) -> String {
        """
        {"type":"user","timestamp":"\(stamp(secondsAgo))","message":{"content":"please continue"}}
        """
    }

    func testPendingAskUserQuestionIsAwaitingAnswer() {
        let lines = [
            claudeAssistantText("Let me check something.", secondsAgo: 60),
            claudeToolUse(name: "AskUserQuestion", id: "t1", secondsAgo: 45)
        ]
        XCTAssertEqual(SessionAttentionClassifier.classify(tailLines: lines, format: .claude, now: now),
                       .awaitingAnswer)
    }

    func testAnsweredAskIsNotWaiting() {
        let lines = [
            claudeToolUse(name: "AskUserQuestion", id: "t1", secondsAgo: 300),
            claudeToolResult(id: "t1", secondsAgo: 290),
            claudeAssistantText("Great, doing that now.", secondsAgo: 5)
        ]
        XCTAssertEqual(SessionAttentionClassifier.classify(tailLines: lines, format: .claude, now: now),
                       .active)
    }

    func testRunningBuildIsActiveNotWaiting() {
        // A pending Bash call one minute in: normal long tool, no alarm.
        let lines = [claudeToolUse(name: "Bash", id: "t2", secondsAgo: 60)]
        XCTAssertEqual(SessionAttentionClassifier.classify(tailLines: lines, format: .claude, now: now),
                       .active)
    }

    func testLongQuietPendingToolIsPossiblyWaiting() {
        let lines = [claudeToolUse(name: "Bash", id: "t3", secondsAgo: 400)]
        let state = SessionAttentionClassifier.classify(tailLines: lines, format: .claude, now: now)
        guard case .possiblyWaiting(let quiet) = state else {
            return XCTFail("expected possiblyWaiting, got \(state)")
        }
        XCTAssertGreaterThanOrEqual(quiet, 400)
        XCTAssertTrue(state.needsUser)
    }

    func testTrailingQuestionIsAwaitingAnswer() {
        let lines = [claudeAssistantText("Should I merge the branch or wait?", secondsAgo: 40)]
        XCTAssertEqual(SessionAttentionClassifier.classify(tailLines: lines, format: .claude, now: now),
                       .awaitingAnswer)
    }

    func testFreshProseIsStillActive() {
        // Mid-stream: a text block seconds old must not read as turn complete.
        let lines = [claudeAssistantText("Working through the tests now.", secondsAgo: 3)]
        XCTAssertEqual(SessionAttentionClassifier.classify(tailLines: lines, format: .claude, now: now),
                       .active)
    }

    func testFinishedProseIsTurnComplete() {
        let lines = [claudeAssistantText("All done, merged and verified.", secondsAgo: 120)]
        XCTAssertEqual(SessionAttentionClassifier.classify(tailLines: lines, format: .claude, now: now),
                       .turnComplete)
    }

    func testUserSpokeLastMeansAgentIsComputing() {
        let lines = [
            claudeAssistantText("Done with that.", secondsAgo: 30),
            claudeUserMessage(secondsAgo: 8)
        ]
        XCTAssertEqual(SessionAttentionClassifier.classify(tailLines: lines, format: .claude, now: now),
                       .active)
    }

    func testRecentAPIErrorSurfaces() {
        let lines = [
            """
            {"type":"system","subtype":"api_error","timestamp":"\(stamp(20))","error":"boom"}
            """
        ]
        XCTAssertEqual(SessionAttentionClassifier.classify(tailLines: lines, format: .claude, now: now),
                       .erroredRecently)
    }

    func testStaleSessionIsQuiet() {
        let lines = [claudeAssistantText("Old news.", secondsAgo: 7200)]
        XCTAssertEqual(SessionAttentionClassifier.classify(tailLines: lines, format: .claude, now: now),
                       .quiet)
    }

    func testSidechainRecordsAreIgnored() {
        let ask = """
        {"type":"assistant","isSidechain":true,"timestamp":"\(stamp(30))","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","id":"s1"}]}}
        """
        XCTAssertEqual(SessionAttentionClassifier.classify(tailLines: [ask], format: .claude, now: now),
                       .quiet)
    }

    func testCodexPendingFunctionCall() {
        let call = """
        {"type":"response_item","timestamp":"\(stamp(300))","payload":{"type":"function_call","name":"shell","call_id":"c1"}}
        """
        let state = SessionAttentionClassifier.classify(tailLines: [call], format: .codex, now: now)
        guard case .possiblyWaiting = state else {
            return XCTFail("expected possiblyWaiting, got \(state)")
        }
    }

    func testCodexAnsweredCallThenProseCompletes() {
        let lines = [
            """
            {"type":"response_item","timestamp":"\(stamp(400))","payload":{"type":"function_call","name":"shell","call_id":"c2"}}
            """,
            """
            {"type":"response_item","timestamp":"\(stamp(390))","payload":{"type":"function_call_output","call_id":"c2"}}
            """,
            """
            {"type":"response_item","timestamp":"\(stamp(60))","payload":{"type":"message","role":"assistant","content":[{"text":"Finished the sweep."}]}}
            """
        ]
        XCTAssertEqual(SessionAttentionClassifier.classify(tailLines: lines, format: .codex, now: now),
                       .turnComplete)
    }

    func testProseSettlesToTurnCompleteAfterTenSeconds() {
        let lines = [claudeAssistantText("All done, pushed the branch.", secondsAgo: 15)]
        XCTAssertEqual(SessionAttentionClassifier.classify(tailLines: lines, format: .claude, now: now),
                       .turnComplete,
                       "a settled turn must not read as working for the whole active window")
        let fresh = [claudeAssistantText("Still streaming this answer.", secondsAgo: 5)]
        XCTAssertEqual(SessionAttentionClassifier.classify(tailLines: fresh, format: .claude, now: now),
                       .active)
    }

    func testEmptyTailIsQuiet() {
        XCTAssertEqual(SessionAttentionClassifier.classify(tailLines: [], format: .claude, now: now),
                       .quiet)
    }

    // MARK: Sub-agent assessment (INF-275)

    private func subAgentLines(pending: Int, resolved: Int, secondsAgo: TimeInterval) -> [String] {
        var lines: [String] = []
        var identifier = 0
        for _ in 0..<(pending + resolved) {
            identifier += 1
            lines.append("""
            {"type":"assistant","timestamp":"\(stamp(secondsAgo))","message":{"content":[{"type":"tool_use","name":"Task","id":"task-\(identifier)"}]}}
            """)
        }
        for index in 0..<resolved {
            lines.append("""
            {"type":"user","timestamp":"\(stamp(secondsAgo - 2))","message":{"content":[{"type":"tool_result","tool_use_id":"task-\(index + 1)"}]}}
            """)
        }
        return lines
    }

    func testAssessCountsPendingSubAgentTools() {
        let lines = subAgentLines(pending: 3, resolved: 2, secondsAgo: 20)
        let assessment = SessionAttentionClassifier.assess(tailLines: lines, format: .claude, now: now)
        XCTAssertEqual(assessment.activeSubAgents, 3)
        XCTAssertEqual(assessment.state, .active)
    }

    func testAssessReportsZeroSubAgentsWhenAllResolved() {
        let lines = subAgentLines(pending: 0, resolved: 4, secondsAgo: 20)
        let assessment = SessionAttentionClassifier.assess(tailLines: lines, format: .claude, now: now)
        XCTAssertEqual(assessment.activeSubAgents, 0)
    }

    func testAssessReportsZeroSubAgentsOnceStale() {
        let lines = subAgentLines(pending: 5, resolved: 0, secondsAgo: 40 * 60)
        let assessment = SessionAttentionClassifier.assess(tailLines: lines, format: .claude, now: now)
        XCTAssertEqual(assessment.state, .quiet)
        XCTAssertEqual(assessment.activeSubAgents, 0, "a stale dangling delegation is history, not activity")
    }
}
