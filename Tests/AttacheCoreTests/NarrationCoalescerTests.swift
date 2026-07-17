import XCTest
@testable import AttacheCore

final class NarrationCoalescerTests: XCTestCase {

    // MARK: - Fixtures

    private func claudeAssistant(_ text: String, at seconds: Int) -> String {
        """
        {"type":"assistant","timestamp":"2026-07-02T10:00:\(pad(seconds))Z","cwd":"/proj","message":{"role":"assistant","content":[{"type":"text","text":"\(text)"}]}}
        """
    }

    private func claudeToolUse(at seconds: Int) -> String {
        """
        {"type":"assistant","timestamp":"2026-07-02T10:00:\(pad(seconds))Z","cwd":"/proj","message":{"role":"assistant","content":[{"type":"tool_use","id":"t\(seconds)","name":"Bash","input":{}}]}}
        """
    }

    private func claudeToolResult(at seconds: Int) -> String {
        """
        {"type":"user","timestamp":"2026-07-02T10:00:\(pad(seconds))Z","cwd":"/proj","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t\(seconds)","content":"ok"}]}}
        """
    }

    private func claudeUser(_ text: String, at seconds: Int) -> String {
        """
        {"type":"user","timestamp":"2026-07-02T10:00:\(pad(seconds))Z","cwd":"/proj","message":{"role":"user","content":"\(text)"}}
        """
    }

    private func codexAssistant(_ text: String, phase: String?, at seconds: Int) -> String {
        let phaseField = phase.map { "\"phase\":\"\($0)\"," } ?? ""
        return """
        {"type":"response_item","timestamp":"2026-07-02T10:00:\(pad(seconds))Z","payload":{"type":"message","role":"assistant",\(phaseField)"content":[{"type":"text","text":"\(text)"}]}}
        """
    }

    private func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    private func parseClaude(_ lines: [String]) -> [ParsedTranscriptRecord] {
        TranscriptParser.parse(text: lines.joined(separator: "\n"), format: .claude, carriedCWD: nil).records
    }

    private func parseCodex(_ lines: [String]) -> [ParsedTranscriptRecord] {
        TranscriptParser.parse(text: lines.joined(separator: "\n"), format: .codex, carriedCWD: nil).records
    }

    // MARK: - Claude coalescing

    func testSixMessagesWithToolsCoalesceToOneTurnWithFiveInterstitials() {
        // 6 assistant prose messages interleaved with tool_use / tool_result,
        // then a real user line closes the turn.
        let lines = [
            claudeUser("start", at: 0),
            claudeAssistant("Let me check the tests.", at: 1),
            claudeToolUse(at: 2),
            claudeToolResult(at: 3),
            claudeAssistant("Now the config.", at: 4),
            claudeToolUse(at: 5),
            claudeToolResult(at: 6),
            claudeAssistant("Looking at the watcher.", at: 7),
            claudeAssistant("Trying a fix.", at: 8),
            claudeAssistant("Re-running.", at: 9),
            claudeAssistant("All green. Here is the final answer.", at: 10),
            claudeUser("next question", at: 20)  // closes the turn
        ]
        let coalescer = NarrationCoalescer()
        let turns = coalescer.poll(parseClaude(lines))

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.text, "All green. Here is the final answer.")
        XCTAssertEqual(turns.first?.interstitials.count, 5)
        XCTAssertEqual(turns.first?.interstitials.first, "Let me check the tests.")
        XCTAssertEqual(turns.first?.cwd, "/proj")
    }

    func testQuietWindowFlushesBufferedTurn() {
        let coalescer = NarrationCoalescer(quietPolls: 3)
        // Poll 1: prose arrives, no boundary yet -> nothing emitted.
        var turns = coalescer.poll(parseClaude([
            claudeAssistant("First.", at: 1),
            claudeAssistant("Second and final.", at: 2)
        ]))
        XCTAssertTrue(turns.isEmpty)
        XCTAssertTrue(coalescer.hasBufferedProse)
        // Two empty polls: still buffered.
        XCTAssertTrue(coalescer.poll([]).isEmpty)
        XCTAssertTrue(coalescer.poll([]).isEmpty)
        // Third empty poll hits the quiet window and flushes.
        turns = coalescer.poll([])
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.text, "Second and final.")
        XCTAssertEqual(turns.first?.interstitials, ["First."])
        XCTAssertFalse(coalescer.hasBufferedProse)
    }

    func testToolResultIsNotATurnBoundary() {
        // A user line that only carries a tool_result must not flush.
        let records = parseClaude([
            claudeAssistant("Working.", at: 1),
            claudeToolResult(at: 2)
        ])
        let boundaries = records.filter { $0.kind == .userTurnBoundary }
        XCTAssertTrue(boundaries.isEmpty)
        let coalescer = NarrationCoalescer()
        XCTAssertTrue(coalescer.poll(records).isEmpty)  // still buffering, no boundary
    }

    func testTwoBackToBackTurnsEmitSeparately() {
        let lines = [
            claudeAssistant("Turn one answer.", at: 1),
            claudeUser("second prompt", at: 2),
            claudeAssistant("Turn two answer.", at: 3),
            claudeUser("third prompt", at: 4)
        ]
        let turns = NarrationCoalescer().poll(parseClaude(lines))
        XCTAssertEqual(turns.map(\.text), ["Turn one answer.", "Turn two answer."])
        XCTAssertEqual(turns.allSatisfy { $0.interstitials.isEmpty }, true)
    }

    // MARK: - Codex

    func testCodexFinalAnswerFlushesImmediately() {
        let turns = NarrationCoalescer().poll(parseCodex([
            codexAssistant("The answer.", phase: "final_answer", at: 5)
        ]))
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.text, "The answer.")
        XCTAssertTrue(turns.first?.interstitials.isEmpty ?? false)
    }

    func testCodexFinalAnswerCarriesEarlierPhasesAsInterstitials() {
        let turns = NarrationCoalescer().poll(parseCodex([
            codexAssistant("Thinking about it.", phase: "reasoning_summary", at: 1),
            codexAssistant("Final result.", phase: "final_answer", at: 2)
        ]))
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.text, "Final result.")
        XCTAssertEqual(turns.first?.interstitials, ["Thinking about it."])
    }

    func testCodexNilPhaseCoalescesInsteadOfPassingThrough() {
        let coalescer = NarrationCoalescer(quietPolls: 2)
        // Two nil-phase messages in one poll: buffered, not emitted immediately.
        var turns = coalescer.poll(parseCodex([
            codexAssistant("Interim one.", phase: nil, at: 1),
            codexAssistant("Interim two.", phase: nil, at: 2)
        ]))
        XCTAssertTrue(turns.isEmpty, "nil-phase Codex prose must coalesce, not pass through")
        // Quiet window flushes them as one coalesced turn.
        XCTAssertTrue(coalescer.poll([]).isEmpty)
        turns = coalescer.poll([])
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.text, "Interim two.")
        XCTAssertEqual(turns.first?.interstitials, ["Interim one."])
    }

    // MARK: - Robustness

    func testGarbageLinesAreSkipped() {
        let records = parseClaude([
            "not json at all",
            "{\"type\":\"assistant\"}",  // missing timestamp
            claudeAssistant("Real one.", at: 1)
        ])
        XCTAssertEqual(records.count, 1)
        if case let .assistantProse(text, _) = records.first?.kind {
            XCTAssertEqual(text, "Real one.")
        } else {
            XCTFail("expected one prose record")
        }
    }

    func testCWDCarriesAcrossChunks() {
        let first = TranscriptParser.parse(
            text: "{\"type\":\"session_meta\",\"timestamp\":\"2026-07-02T10:00:00Z\",\"payload\":{\"cwd\":\"/carried\"}}",
            format: .codex, carriedCWD: nil
        )
        XCTAssertEqual(first.cwd, "/carried")
        let second = TranscriptParser.parse(
            text: codexAssistant("Answer.", phase: "final_answer", at: 1),
            format: .codex, carriedCWD: first.cwd
        )
        XCTAssertEqual(second.records.first?.cwd, "/carried")
    }

    // MARK: - Sidechain (INF-368 Part B)

    private func claudeSidechainAssistant(_ text: String, at seconds: Int) -> String {
        """
        {"type":"assistant","isSidechain":true,"timestamp":"2026-07-02T10:00:\(pad(seconds))Z","cwd":"/proj","message":{"role":"assistant","content":[{"type":"text","text":"\(text)"}]}}
        """
    }

    /// A sidechain line interleaved in a PARENT transcript (the historical
    /// case this guard existed for) is never that session's main narration
    /// by default.
    func testSidechainLinesAreExcludedByDefault() {
        let records = TranscriptParser.parse(
            text: [claudeSidechainAssistant("Buried subagent chatter.", at: 1), claudeAssistant("Real answer.", at: 2)].joined(separator: "\n"),
            format: .claude, carriedCWD: nil
        ).records
        XCTAssertEqual(records.count, 1)
        if case let .assistantProse(text, _) = records.first?.kind {
            XCTAssertEqual(text, "Real answer.")
        } else {
            XCTFail("expected one prose record")
        }
    }

    /// A dedicated subagent transcript file is ENTIRELY sidechain-marked
    /// lines; `includeSidechain: true` is how a caller (the live watchers
    /// tailing `<session>/subagents/agent-*.jsonl`) opts into narrating it.
    func testIncludeSidechainSurfacesSubagentProse() {
        let records = TranscriptParser.parse(
            text: claudeSidechainAssistant("Subagent finished the investigation.", at: 1),
            format: .claude, carriedCWD: nil, includeSidechain: true
        ).records
        XCTAssertEqual(records.count, 1)
        if case let .assistantProse(text, _) = records.first?.kind {
            XCTAssertEqual(text, "Subagent finished the investigation.")
        } else {
            XCTFail("expected one prose record")
        }
    }
}
