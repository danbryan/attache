import XCTest
@testable import AttacheCore

final class AgentInstructionIntentTests: XCTestCase {
    func testDetectsTellCodexToInstruction() {
        let intent = AgentInstructionIntent.detect(in: "Tell Codex to tell me the sum of 2+2.")

        XCTAssertEqual(intent?.requestedAgent, .codex)
        XCTAssertEqual(intent?.instruction, "tell me the sum of 2+2.")
    }

    func testDetectsAskCodexWithoutTo() {
        let intent = AgentInstructionIntent.detect(in: "Can you ask Codex what changed in the latest build?")

        XCTAssertEqual(intent?.requestedAgent, .codex)
        XCTAssertEqual(intent?.instruction, "what changed in the latest build?")
    }

    func testDetectsHeyCanYouSendCodexTestMessage() {
        let intent = AgentInstructionIntent.detect(in: "Hey, can you send Codex a test message and tell me its response?")

        XCTAssertEqual(intent?.requestedAgent, .codex)
        XCTAssertEqual(intent?.instruction, "Reply with a short test response.")
    }

    func testDetectsHeyCanYouSendCodexMessageToInstruction() {
        let intent = AgentInstructionIntent.detect(in: "Hey, can you send Codex a message to reply exactly ATTACHE_PONG and do not use tools?")

        XCTAssertEqual(intent?.requestedAgent, .codex)
        XCTAssertEqual(intent?.instruction, "reply exactly ATTACHE_PONG and do not use tools?")
    }

    func testDetectsClaudeCodeAndAttachedAgentPhrases() {
        let claude = AgentInstructionIntent.detect(in: "Have Claude Code run the focused test target")
        let attached = AgentInstructionIntent.detect(in: "Please tell the agent to run swift test")

        XCTAssertEqual(claude?.requestedAgent, .claudeCode)
        XCTAssertEqual(claude?.instruction, "run the focused test target")
        XCTAssertEqual(attached?.requestedAgent, .attached)
        XCTAssertEqual(attached?.instruction, "run swift test")
    }

    func testDetectsSendThisToAgent() {
        let intent = AgentInstructionIntent.detect(in: "Send this to Codex: reply exactly ATTACHE_PONG")

        XCTAssertEqual(intent?.requestedAgent, .codex)
        XCTAssertEqual(intent?.instruction, "reply exactly ATTACHE_PONG")
    }

    func testDoesNotTreatQuestionsAboutCodexAsInstructions() {
        XCTAssertNil(AgentInstructionIntent.detect(in: "What did Codex say?"))
        XCTAssertNil(AgentInstructionIntent.detect(in: "Tell me what Codex did."))
        XCTAssertNil(AgentInstructionIntent.detect(in: "Can Codex do this?"))
    }

    func testRequestedAgentMatchesOnlyTheRightSourceWhenNamed() {
        XCTAssertTrue(AgentInstructionIntent.RequestedAgent.codex.matches(sourceKind: .codex))
        XCTAssertFalse(AgentInstructionIntent.RequestedAgent.codex.matches(sourceKind: .claudeCode))
        XCTAssertTrue(AgentInstructionIntent.RequestedAgent.claudeCode.matches(sourceKind: .claudeCode))
        XCTAssertFalse(AgentInstructionIntent.RequestedAgent.claudeCode.matches(sourceKind: .codex))
        XCTAssertTrue(AgentInstructionIntent.RequestedAgent.attached.matches(sourceKind: .codex))
        XCTAssertTrue(AgentInstructionIntent.RequestedAgent.attached.matches(sourceKind: .claudeCode))
    }
}
