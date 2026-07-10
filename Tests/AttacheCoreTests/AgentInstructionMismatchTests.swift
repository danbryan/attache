import XCTest
@testable import AttacheCore

final class AgentInstructionMismatchTests: XCTestCase {
    func testAbsentIntendedAgentIsNotAMismatch() {
        XCTAssertNil(AgentInstructionMismatch.evaluate(
            intendedAgent: nil,
            focusedSource: .codex,
            focusedTitle: "Weekly Codex Improvement Review",
            watchedSources: [.codex]
        ))
    }

    func testEmptyIntendedAgentIsNotAMismatch() {
        XCTAssertNil(AgentInstructionMismatch.evaluate(
            intendedAgent: "   ",
            focusedSource: .codex,
            focusedTitle: "Weekly Codex Improvement Review",
            watchedSources: [.codex]
        ))
    }

    func testMatchingIntendedAgentIsNotAMismatch() {
        XCTAssertNil(AgentInstructionMismatch.evaluate(
            intendedAgent: "codex",
            focusedSource: .codex,
            focusedTitle: "Weekly Codex Improvement Review",
            watchedSources: [.codex]
        ))
    }

    func testMismatchAgainstAWatchedSessionOfTheOtherSourceIsBlockedWrongAgent() {
        let mismatch = AgentInstructionMismatch.evaluate(
            intendedAgent: "claude_code",
            focusedSource: .codex,
            focusedTitle: "Weekly Codex Improvement Review",
            watchedSources: [.codex, .claudeCode]
        )

        XCTAssertEqual(mismatch?.status, .blockedWrongAgent)
        XCTAssertEqual(
            mismatch?.message,
            "The focused session is Codex (Weekly Codex Improvement Review). No staging occurred. Ask the user to focus a Claude Code session, or to confirm sending to Codex."
        )
    }

    func testMismatchWithNoWatchedSessionOfTheNamedSourceIsBlockedNoWatchedSession() {
        let mismatch = AgentInstructionMismatch.evaluate(
            intendedAgent: "claude_code",
            focusedSource: .codex,
            focusedTitle: "Weekly Codex Improvement Review",
            watchedSources: [.codex]
        )

        XCTAssertEqual(mismatch?.status, .blockedNoWatchedSession)
        XCTAssertEqual(mismatch?.message, "No Claude Code sessions are currently being watched. No staging occurred.")
    }

    func testUnrecognizedIntendedAgentFailsClosed() {
        let mismatch = AgentInstructionMismatch.evaluate(
            intendedAgent: "gemini",
            focusedSource: .codex,
            focusedTitle: "Weekly Codex Improvement Review",
            watchedSources: [.codex]
        )

        XCTAssertEqual(mismatch?.status, .blockedUnrecognizedAgent)
        XCTAssertEqual(
            mismatch?.message,
            "Attaché didn't recognize \"gemini\" as an agent to send to. No staging occurred. The focused session is Codex (Weekly Codex Improvement Review)."
        )
    }

    /// `SourceKind` has non-agent raw values ("mcp", "generic", "simulated")
    /// that are not valid `intended_agent` values per the tool schema's
    /// enum (["codex", "claude_code"]). A hallucinated value that happens to
    /// decode to one of those must still fail closed, not be treated as some
    /// third watchable agent.
    func testNonAgentSourceKindRawValueFailsClosed() {
        let mismatch = AgentInstructionMismatch.evaluate(
            intendedAgent: "mcp",
            focusedSource: .codex,
            focusedTitle: "Weekly Codex Improvement Review",
            watchedSources: [.codex]
        )

        XCTAssertEqual(mismatch?.status, .blockedUnrecognizedAgent)
    }

    func testAllBlockedMessagesContainTheStableNoStagingMarker() {
        let wrongAgent = AgentInstructionMismatch.evaluate(
            intendedAgent: "claude_code", focusedSource: .codex, focusedTitle: "T", watchedSources: [.codex, .claudeCode]
        )
        let noWatched = AgentInstructionMismatch.evaluate(
            intendedAgent: "claude_code", focusedSource: .codex, focusedTitle: "T", watchedSources: [.codex]
        )
        let unrecognized = AgentInstructionMismatch.evaluate(
            intendedAgent: "banana", focusedSource: .codex, focusedTitle: "T", watchedSources: [.codex]
        )

        for mismatch in [wrongAgent, noWatched, unrecognized] {
            XCTAssertTrue(mismatch?.message.contains("No staging occurred.") == true)
        }
    }
}
