import XCTest
@testable import AttacheCore

/// INF-361: Grok Build's `chat_history.jsonl` records (verified against real
/// sessions on this Mac) carry `content` and `type` but, unlike Claude/Codex,
/// no per-line `timestamp`. `TranscriptParser.parse` assigns a synthetic,
/// monotonically increasing timestamp for `.grokBuild` instead of requiring
/// one on the line; these tests prove each observed `type` value maps
/// correctly and that unknown types are skipped, never fatal.
final class TranscriptParserGrokBuildTests: XCTestCase {
    private func parse(_ lines: [[String: Any]], carriedCWD: String? = nil) -> TranscriptParser.Result {
        let text = lines.map { line -> String in
            let data = try! JSONSerialization.data(withJSONObject: line)
            return String(data: data, encoding: .utf8)!
        }.joined(separator: "\n")
        return TranscriptParser.parse(text: text, format: .grokBuild, carriedCWD: carriedCWD)
    }

    func testSystemRecordIsSkipped() {
        let result = parse([["type": "system", "content": "You are Grok Build."]])
        XCTAssertTrue(result.records.isEmpty)
    }

    func testUserRecordWithRealTextIsATurnBoundary() {
        let result = parse([
            ["type": "user", "content": [["type": "text", "text": "fix the bug"]], "synthetic_reason": NSNull()]
        ])
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records[0].kind, .userTurnBoundary)
    }

    func testAssistantRecordIsProse() {
        let result = parse([
            ["type": "assistant", "content": "Looking into it.", "model_id": "grok-4-fast", "reasoning": NSNull(), "tool_calls": NSNull()]
        ])
        XCTAssertEqual(result.records.count, 1)
        guard case let .assistantProse(text, isFinal) = result.records[0].kind else {
            return XCTFail("expected assistantProse")
        }
        XCTAssertEqual(text, "Looking into it.")
        XCTAssertFalse(isFinal)
    }

    func testEmptyAssistantContentProducesNoRecord() {
        let result = parse([
            ["type": "assistant", "content": "", "tool_calls": [["id": "call_1", "name": "Bash", "arguments": ["command": "ls"]]]]
        ])
        XCTAssertTrue(result.records.isEmpty)
    }

    func testToolResultRecordIsSkippedNotNarrated() {
        let result = parse([
            ["type": "tool_result", "content": "file1.txt\nfile2.txt", "tool_call_id": "call_1"]
        ])
        XCTAssertTrue(result.records.isEmpty)
    }

    /// Unknown types (anything the ticket's real-data sample didn't observe)
    /// are skipped, never fatal - the parser must not crash or throw.
    func testUnknownTypeIsSkippedNotFatal() {
        let result = parse([
            ["type": "some_future_record_type", "content": "whatever"],
            ["type": "assistant", "content": "still parses after the unknown line.", "tool_calls": NSNull()]
        ])
        XCTAssertEqual(result.records.count, 1)
        guard case let .assistantProse(text, _) = result.records[0].kind else {
            return XCTFail("expected assistantProse")
        }
        XCTAssertEqual(text, "still parses after the unknown line.")
    }

    /// Ordering across lines lacking a real timestamp is preserved via the
    /// synthetic monotonic clock (earlier lines get earlier timestamps).
    func testRecordOrderIsPreservedWithoutRealTimestamps() {
        let result = parse([
            ["type": "user", "content": [["type": "text", "text": "first"]]],
            ["type": "assistant", "content": "second", "tool_calls": NSNull()],
            ["type": "assistant", "content": "third", "tool_calls": NSNull()]
        ])
        XCTAssertEqual(result.records.count, 3)
        XCTAssertLessThanOrEqual(result.records[0].timestamp, result.records[1].timestamp)
        XCTAssertLessThanOrEqual(result.records[1].timestamp, result.records[2].timestamp)
    }

    /// Grok Build carries no per-line cwd (verified: no such key in any
    /// observed record type); a carried-in cwd from the scanner's
    /// percent-decoded project directory passes through untouched.
    func testCarriedCWDPassesThroughUnchanged() {
        let result = parse(
            [["type": "assistant", "content": "hi", "tool_calls": NSNull()]],
            carriedCWD: "/Users/tester/project"
        )
        XCTAssertEqual(result.cwd, "/Users/tester/project")
        XCTAssertEqual(result.records.first?.cwd, "/Users/tester/project")
    }
}
