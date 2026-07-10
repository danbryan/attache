import XCTest
@testable import AttacheApp

final class CompanionPresentationCLIToolBridgeTests: XCTestCase {
    func testParsesAttacheToolCallObject() {
        let calls = CompanionPresentationService.parseCLIToolDirectives(in: """
        {"attache_tool_call":{"name":"stage_agent_instruction","arguments":{"instruction":"reply exactly PONG"}}}
        """)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "stage_agent_instruction")
        XCTAssertEqual(calls.first?.arguments, #"{"instruction":"reply exactly PONG"}"#)
    }

    func testParsesFencedToolCall() {
        let calls = CompanionPresentationService.parseCLIToolDirectives(in: """
        ```json
        {"attache_tool_call":{"name":"read_session_transcript","arguments":{"start_turn":3}}}
        ```
        """)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "read_session_transcript")
        XCTAssertEqual(calls.first?.arguments, #"{"start_turn":3}"#)
    }

    func testParsesOpenAIStyleFunctionCall() {
        let calls = CompanionPresentationService.parseCLIToolDirectives(in: """
        {"tool_calls":[{"function":{"name":"read_file","arguments":"{\\"path\\":\\"Package.swift\\"}"}}]}
        """)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "read_file")
        XCTAssertEqual(calls.first?.arguments, #"{"path":"Package.swift"}"#)
    }

    func testBridgePromptExplainsAppToolChannel() {
        let message = CompanionPresentationService.cliToolBridgeMessage(tools: [[
            "type": "function",
            "function": [
                "name": "stage_agent_instruction",
                "description": "Route an instruction for the attached work agent."
            ]
        ]])

        XCTAssertTrue(message.content.contains("Attaché app tools"))
        XCTAssertTrue(message.content.contains("stage_agent_instruction"))
        XCTAssertTrue(message.content.contains(#"{"attache_tool_call":{"name":"tool_name","arguments":{}}}"#))
    }

    func testAgentInstructionToolDescriptionDistinguishesQuestionFromDelegation() {
        let tools = CompanionPresentationService.conversationTools(allowAgentInstructionTool: true)
        let function = tools
            .compactMap { $0["function"] as? [String: Any] }
            .first { $0["name"] as? String == "stage_agent_instruction" }
        let description = function?["description"] as? String ?? ""

        XCTAssertTrue(description.contains("What did Codex say?"))
        XCTAssertTrue(description.contains("Ask Codex what it changed"))
        XCTAssertTrue(description.contains("MUST use this tool"))
        XCTAssertTrue(description.contains("Do not substitute local read tools"))
    }
}
