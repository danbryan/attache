import AttacheCore
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
        XCTAssertTrue(description.contains("never guess or omit intended_agent"))
    }

    /// INF-246: `intended_agent` is optional (not in `required`) so its
    /// absence stages exactly as before this ticket, and its enum is scoped
    /// to the two live agent sources so an out-of-band value cannot slip in
    /// undetected by the schema itself.
    func testAgentInstructionToolSchemaAddsOptionalIntendedAgentEnum() {
        let tools = CompanionPresentationService.conversationTools(allowAgentInstructionTool: true)
        let function = tools
            .compactMap { $0["function"] as? [String: Any] }
            .first { $0["name"] as? String == "stage_agent_instruction" }
        let parameters = function?["parameters"] as? [String: Any]
        let properties = parameters?["properties"] as? [String: Any]
        let intendedAgent = properties?["intended_agent"] as? [String: Any]
        let required = parameters?["required"] as? [String]

        XCTAssertEqual(intendedAgent?["type"] as? String, "string")
        XCTAssertEqual(intendedAgent?["enum"] as? [String], ["codex", "claude_code"])
        XCTAssertEqual(required, ["instruction"])
    }

    /// Opt-in live canary for the judgment boundary a deterministic provider
    /// cannot exercise. It uses the production conversation prompt, production
    /// CLI tool bridge, and the phrasing from the July 10 routing incident.
    func testLiveCodexRoutesExplicitArtifactDelegationToAgentTool() async throws {
        guard ProcessInfo.processInfo.environment["ATTACHE_LIVE_CODEX_ROUTING_TEST"] == "1" else {
            throw XCTSkip("Set ATTACHE_LIVE_CODEX_ROUTING_TEST=1 to run the real Codex routing canary.")
        }

        let suiteName = "AttacheLiveCodexRoutingCanary-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults for the live routing canary.")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: CompanionPreferenceKey.presentationLLMEnabled)

        let model = ProcessInfo.processInfo.environment["ATTACHE_LIVE_CODEX_MODEL"] ?? "default"
        let service = CompanionPresentationService(defaults: defaults, environment: [
            "ATTACHE_LLM_PROVIDER": "codex_cli",
            "ATTACHE_LLM_MODEL": model,
            "ATTACHE_REASONING_EFFORT": "low"
        ])
        let recorder = LiveToolCallRecorder()
        let system = CompanionPersonality.conversationSystemPrompt(
            memoryContext: nil,
            sessionTitle: "Weekly Codex Improvement Review",
            sessionSourceName: "Codex",
            workingDirectory: "/tmp/attache-routing-canary",
            latestSummary: "Three improvements were completed and an HTML report was generated.",
            latestAgentReply: "The detailed results are in the HTML report.",
            canStageAgentInstruction: true
        )
        let user = "Could you just ask Codex to tell you the items from the artifact and then report it to me? Describe the three improvements from the HTML report in detail."

        let result: Result<String, Error> = await withCheckedContinuation { continuation in
            service.converse(
                messages: [
                    CompanionChatMessage(role: "system", content: system),
                    CompanionChatMessage(role: "user", content: user)
                ],
                allowAgentInstructionTool: true,
                executeTool: { name, arguments in
                    await recorder.append(name: name, arguments: arguments)
                    if name == "stage_agent_instruction" {
                        return "Attaché opened the per-message confirmation sheet. Nothing has been sent yet."
                    }
                    return "This tool is unavailable in the routing canary. Follow the user's explicit delegation request."
                },
                completion: { continuation.resume(returning: $0) }
            )
        }
        _ = try result.get()

        let calls = await recorder.calls
        XCTAssertEqual(calls.first?.name, "stage_agent_instruction", "The real personality chose \(calls.first?.name ?? "no tool") before the explicit agent handoff.")
        let arguments = calls.first?.arguments ?? ""
        XCTAssertTrue(arguments.localizedCaseInsensitiveContains("three improvements"))
        XCTAssertTrue(arguments.localizedCaseInsensitiveContains("HTML report"))
    }
}

private actor LiveToolCallRecorder {
    struct Call: Sendable {
        let name: String
        let arguments: String
    }

    private(set) var calls: [Call] = []

    func append(name: String, arguments: String) {
        calls.append(Call(name: name, arguments: arguments))
    }
}
