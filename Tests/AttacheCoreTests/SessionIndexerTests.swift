import AttacheCore
import XCTest

final class SessionIndexerTests: XCTestCase {
    func testSessionIDExtractedFromRolloutFileName() {
        let name = "rollout-2026-06-03T15-35-20-019e8efb-b0e2-7061-b0e1-f7df4b9735e0.jsonl"
        XCTAssertEqual(CodexSessionScanner.sessionID(fromFileName: name), "019e8efb-b0e2-7061-b0e1-f7df4b9735e0")
    }

    func testSessionIDNilWhenNoUUID() {
        XCTAssertNil(CodexSessionScanner.sessionID(fromFileName: "notes.jsonl"))
    }

    func testFirstCWDReadFromSessionMeta() {
        let jsonl = """
        {"type":"turn_context","payload":{"foo":"bar"}}
        {"type":"session_meta","payload":{"id":"x","cwd":"/Users/example/code/penumbra"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"hi"}]}}
        """
        XCTAssertEqual(CodexSessionScanner.firstCWD(inJSONL: jsonl), "/Users/example/code/penumbra")
    }

    func testFirstCWDNilWhenAbsent() {
        XCTAssertNil(CodexSessionScanner.firstCWD(inJSONL: #"{"type":"response_item","payload":{}}"#))
    }

    func testClaudeCodeParsePullsCwdTitleAndContent() {
        // Claude Code: user content is a string, assistant content is a block list,
        // the title arrives on an ai-title line, and cwd is on every line.
        let jsonl = """
        {"type":"user","cwd":"/Users/example/code/penumbra","message":{"role":"user","content":"set up the validator notes"}}
        {"type":"ai-title","aiTitle":"Validator notes setup"}
        {"type":"assistant","cwd":"/Users/example/code/penumbra","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Done, notes added."}]}}
        """
        let parsed = ClaudeCodeSessionScanner.parse(jsonl: jsonl, contentCap: 8_000)
        XCTAssertEqual(parsed.project, "/Users/example/code/penumbra")
        XCTAssertEqual(parsed.title, "Validator notes setup")
        XCTAssertEqual(parsed.firstUserMessage, "set up the validator notes")
        XCTAssertTrue(parsed.content.contains("validator notes"))
        XCTAssertTrue(parsed.content.contains("done, notes added."))
        XCTAssertFalse(parsed.content.contains("hmm"), "thinking blocks are not part of the digest")
    }
}
