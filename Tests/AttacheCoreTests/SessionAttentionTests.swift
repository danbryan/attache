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

    func testLongRunningToolStaysActiveNotWaiting() {
        // A tool pending for minutes (a long build, benchmark, or ssh loop) is
        // still working, not waiting on you. Real permission waits come from
        // the Notification hook now, not from a quiet-tool guess.
        let lines = [claudeToolUse(name: "Bash", id: "t3", secondsAgo: 400)]
        XCTAssertEqual(SessionAttentionClassifier.classify(tailLines: lines, format: .claude, now: now),
                       .active)
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

    func testFinishedProseReadsQuietNotComplete() {
        // "Done" prose and a long silent think look identical in the
        // transcript, so a quiet gap must not fabricate a completion (that is
        // the Stop hook's job). Old prose simply reads quiet, never a check.
        let lines = [claudeAssistantText("All done, merged and verified.", secondsAgo: 120)]
        XCTAssertEqual(SessionAttentionClassifier.classify(tailLines: lines, format: .claude, now: now),
                       .quiet)
    }

    func testNewestRecordTimestampIsReported() {
        let lines = [claudeAssistantText("Working on it.", secondsAgo: 12)]
        let assessment = SessionAttentionClassifier.assess(tailLines: lines, format: .claude, now: now)
        let expected = now.addingTimeInterval(-12).timeIntervalSinceReferenceDate
        XCTAssertNotNil(assessment.newestRecordAt)
        XCTAssertEqual(assessment.newestRecordAt?.timeIntervalSinceReferenceDate ?? 0,
                       expected, accuracy: 0.01)
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

    func testCodexPendingFunctionCallIsActive() {
        let call = """
        {"type":"response_item","timestamp":"\(stamp(300))","payload":{"type":"function_call","name":"shell","call_id":"c1"}}
        """
        XCTAssertEqual(SessionAttentionClassifier.classify(tailLines: [call], format: .codex, now: now),
                       .active)
    }

    func testCodexAnsweredCallThenProseGoesQuiet() {
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
                       .quiet)
    }

    func testProseStaysActiveThenGoesQuiet() {
        // Within the active window a settled-looking turn still reads active
        // (it may be thinking); past it, quiet. Never a fabricated completion.
        let recent = [claudeAssistantText("All done, pushed the branch.", secondsAgo: 15)]
        XCTAssertEqual(SessionAttentionClassifier.classify(tailLines: recent, format: .claude, now: now),
                       .active)
        let aged = [claudeAssistantText("All done, pushed the branch.", secondsAgo: 45)]
        XCTAssertEqual(SessionAttentionClassifier.classify(tailLines: aged, format: .claude, now: now),
                       .quiet)
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
