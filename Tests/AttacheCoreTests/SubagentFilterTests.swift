import XCTest
@testable import AttacheCore

final class SubagentFilterTests: XCTestCase {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testSubagentSidechainsAreFiltered() {
        // The 9:1 pollution: <project>/<session>/subagents/agent-*.jsonl
        XCTAssertTrue(ClaudeCodeSessionScanner.isSubagentTranscript(
            url("/Users/x/.claude/projects/proj/sess/subagents/agent-abc123.jsonl")))
        XCTAssertTrue(ClaudeCodeSessionScanner.isSubagentTranscript(
            url("/Users/x/.claude/projects/proj/subagents/anything.jsonl")))
        XCTAssertTrue(ClaudeCodeSessionScanner.isSubagentTranscript(
            url("/Users/x/.claude/projects/proj/agent-xyz.jsonl")))
    }

    func testRealSessionsAreNotFiltered() {
        XCTAssertFalse(ClaudeCodeSessionScanner.isSubagentTranscript(
            url("/Users/x/.claude/projects/proj/5f854c66-0334.jsonl")))
        XCTAssertFalse(ClaudeCodeSessionScanner.isSubagentTranscript(
            url("/Users/x/.claude/projects/proj/session-123.jsonl")))
    }
}
