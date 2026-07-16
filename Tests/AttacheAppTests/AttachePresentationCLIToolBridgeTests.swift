import AttacheCore
import XCTest
@testable import AttacheApp

final class AttachePresentationCLIToolBridgeTests: XCTestCase {
    func testSessionToolResultsKeepTheirFocusedEvidenceClassification() {
        XCTAssertEqual(
            AttachePresentationService.toolResultSource(for: "read_session_transcript"),
            .retrievedTranscriptEvidence
        )
        XCTAssertEqual(
            AttachePresentationService.toolResultSource(for: "search_session_transcript"),
            .retrievedTranscriptEvidence
        )
        XCTAssertEqual(
            AttachePresentationService.toolResultSource(for: "read_file"),
            .retrievedFileEvidence
        )
        XCTAssertEqual(
            AttachePresentationService.toolResultSource(for: "list_working_directory"),
            .retrievedFileEvidence
        )
        XCTAssertEqual(
            AttachePresentationService.toolResultSource(for: "propose_memory"),
            .toolResults
        )
    }

    func testContextFreeConversationOffersNoSessionOrAgentTools() {
        let tools = AttachePresentationService.conversationTools(
            allowSessionContextTools: false,
            allowAgentInstructionTool: true
        )

        XCTAssertTrue(tools.isEmpty)
    }

    func testParsesAttacheToolCallObject() {
        let calls = AttachePresentationService.parseCLIToolDirectives(in: """
        {"companion_tool_call":{"name":"stage_agent_instruction","arguments":{"instruction":"reply exactly PONG"}}}
        """)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "stage_agent_instruction")
        XCTAssertEqual(calls.first?.arguments, #"{"instruction":"reply exactly PONG"}"#)
    }

    func testParsesFencedToolCall() {
        let calls = AttachePresentationService.parseCLIToolDirectives(in: """
        ```json
        {"companion_tool_call":{"name":"read_session_transcript","arguments":{"start_turn":3}}}
        ```
        """)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "read_session_transcript")
        XCTAssertEqual(calls.first?.arguments, #"{"start_turn":3}"#)
    }

    func testParsesOpenAIStyleFunctionCall() {
        let calls = AttachePresentationService.parseCLIToolDirectives(in: """
        {"tool_calls":[{"function":{"name":"read_file","arguments":"{\\"path\\":\\"Package.swift\\"}"}}]}
        """)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "read_file")
        XCTAssertEqual(calls.first?.arguments, #"{"path":"Package.swift"}"#)
    }

    func testBridgePromptExplainsAppToolChannel() {
        let message = AttachePresentationService.cliToolBridgeMessage(tools: [[
            "type": "function",
            "function": [
                "name": "stage_agent_instruction",
                "description": "Route an instruction for the attached work agent."
            ]
        ]])

        XCTAssertTrue(message.content.contains("Attaché app tools"))
        XCTAssertTrue(message.content.contains("stage_agent_instruction"))
        XCTAssertTrue(message.content.contains(#"{"companion_tool_call":{"name":"tool_name","arguments":{}}}"#))
    }

    func testAgentInstructionToolDescriptionDistinguishesQuestionFromDelegation() {
        let tools = AttachePresentationService.conversationTools(
            allowSessionContextTools: true,
            allowAgentInstructionTool: true
        )
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
        let tools = AttachePresentationService.conversationTools(
            allowSessionContextTools: true,
            allowAgentInstructionTool: true
        )
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

    // MARK: - INF-243: corrective retry on a malformed CLI tool-call attempt

    /// Prose-wrapped JSON: the model explains itself before and after the tool
    /// call, and the embedded object is missing the comma before "arguments"
    /// (a common LLM mistake) so it fails JSON parsing even though it is
    /// brace-balanced. The corrective retry should recover once it returns
    /// clean JSON.
    func testCorrectiveRetryRecoversProseWrappedMalformedToolCall() async {
        let original = #"""
        Sure, I'll do that: {"companion_tool_call":{"name":"stage_agent_instruction" "arguments":{"instruction":"send this"}}} let me know if you need anything else
        """#
        let recorder = RetryRecorder()
        let cleaned = #"{"companion_tool_call":{"name":"stage_agent_instruction","arguments":{"instruction":"send this"}}}"#

        let resolution = await AttachePresentationService.resolveCLIToolCall(
            text: original,
            toolsOffered: true
        ) {
            await recorder.record()
            return cleaned
        }

        XCTAssertEqual(resolution.directives.count, 1)
        XCTAssertEqual(resolution.directives.first?.name, "stage_agent_instruction")
        XCTAssertFalse(resolution.toolCallLost)
        let retries = await recorder.count
        XCTAssertEqual(retries, 1, "expected exactly one corrective retry turn")
    }

    /// Two JSON objects concatenated with no separator: the first (benign,
    /// no tool-call shape) is what `firstJSONObject` would extract today, so
    /// the real tool call in the second object is missed unless the whole
    /// text is recognized as an attempted call and retried.
    func testCorrectiveRetryRecoversFromConcatenatedJSONObjects() async {
        let original = #"""
        {"note":"thinking it over"}{"companion_tool_call":{"name":"stage_agent_instruction","arguments":{"instruction":"send this"}}}
        """#
        let recorder = RetryRecorder()
        let cleaned = #"{"companion_tool_call":{"name":"stage_agent_instruction","arguments":{"instruction":"send this"}}}"#

        let resolution = await AttachePresentationService.resolveCLIToolCall(
            text: original,
            toolsOffered: true
        ) {
            await recorder.record()
            return cleaned
        }

        XCTAssertEqual(resolution.directives.count, 1)
        XCTAssertEqual(resolution.directives.first?.name, "stage_agent_instruction")
        XCTAssertFalse(resolution.toolCallLost)
        let retries = await recorder.count
        XCTAssertEqual(retries, 1, "expected exactly one corrective retry turn")
    }

    /// Trailing commentary after a valid-looking JSON block that still fails
    /// to parse (the same missing-comma mistake, this time with no prose
    /// before it, only after).
    func testCorrectiveRetryRecoversFromTrailingCommentaryAfterMalformedJSON() async {
        let original = #"""
        {"companion_tool_call":{"name":"stage_agent_instruction" "arguments":{"instruction":"send this"}}} Let me know if that's not what you meant.
        """#
        let recorder = RetryRecorder()
        let cleaned = #"{"companion_tool_call":{"name":"stage_agent_instruction","arguments":{"instruction":"send this"}}}"#

        let resolution = await AttachePresentationService.resolveCLIToolCall(
            text: original,
            toolsOffered: true
        ) {
            await recorder.record()
            return cleaned
        }

        XCTAssertEqual(resolution.directives.count, 1)
        XCTAssertEqual(resolution.directives.first?.name, "stage_agent_instruction")
        XCTAssertFalse(resolution.toolCallLost)
        let retries = await recorder.count
        XCTAssertEqual(retries, 1, "expected exactly one corrective retry turn")
    }

    /// A malformed attempt that never contains the literal "companion_tool_call"
    /// substring or a fenced block, only a brace-balanced object that fails to
    /// parse as JSON (the `tool_call` spelling, missing the comma before
    /// "arguments"). This isolates the third detection signal on its own.
    func testCorrectiveRetryRecoversFromBraceBalancedButInvalidJSONWithoutKeywordSubstring() async {
        let original = #"""
        Sure: {"tool_call":{"name":"stage_agent_instruction" "arguments":{"instruction":"send this"}}} okay?
        """#
        let recorder = RetryRecorder()
        let cleaned = #"{"tool_call":{"name":"stage_agent_instruction","arguments":{"instruction":"send this"}}}"#

        XCTAssertFalse(original.contains("companion_tool_call"))

        let resolution = await AttachePresentationService.resolveCLIToolCall(
            text: original,
            toolsOffered: true
        ) {
            await recorder.record()
            return cleaned
        }

        XCTAssertEqual(resolution.directives.count, 1)
        XCTAssertEqual(resolution.directives.first?.name, "stage_agent_instruction")
        XCTAssertFalse(resolution.toolCallLost)
        let retries = await recorder.count
        XCTAssertEqual(retries, 1, "expected exactly one corrective retry turn")
    }

    /// If the corrective retry ALSO fails to parse, degrade like today (empty
    /// directives so the caller falls back to the raw text as a spoken
    /// answer) but flag `toolCallLost` so a caller can notice the loss. Only
    /// one retry is ever attempted, never a loop.
    func testCorrectiveRetryGivesUpAfterOneAttemptAndFlagsToolCallLost() async {
        let original = #"""
        Sure, I'll do that: {"companion_tool_call":{"name":"stage_agent_instruction" "arguments":{"instruction":"send this"}}}
        """#
        let recorder = RetryRecorder()
        let stillBroken = "Sorry, here's another try: still not JSON."

        let resolution = await AttachePresentationService.resolveCLIToolCall(
            text: original,
            toolsOffered: true
        ) {
            await recorder.record()
            return stillBroken
        }

        XCTAssertTrue(resolution.directives.isEmpty)
        XCTAssertTrue(resolution.toolCallLost)
        let retries = await recorder.count
        XCTAssertEqual(retries, 1, "expected exactly one corrective retry turn, never a loop")
    }

    /// A plain conversational answer with no JSON-like content anywhere must
    /// never trigger the retry codepath at all, not just produce the same
    /// final result. The retry closure would fail the test if invoked.
    func testCorrectiveRetryNeverInvokedForPlainConversationalAnswer() async {
        let plainAnswer = "Sure, everything looks good and no changes are needed. Let me know if you have other questions."

        let resolution = await AttachePresentationService.resolveCLIToolCall(
            text: plainAnswer,
            toolsOffered: true
        ) {
            XCTFail("retry should never be invoked for a plain non-tool answer")
            return ""
        }

        XCTAssertTrue(resolution.directives.isEmpty)
        XCTAssertFalse(resolution.toolCallLost)
    }

    /// Even a clearly malformed attempted tool call must not retry when no
    /// tools were actually offered on this turn (e.g. the final forced-answer
    /// call in the tool-round loop, which passes `tools: nil`).
    func testCorrectiveRetryNeverInvokedWhenToolsWereNotOffered() async {
        let malformedLookingText = #"""
        {"companion_tool_call":{"name":"stage_agent_instruction" "arguments":{"instruction":"send this"}}}
        """#

        let resolution = await AttachePresentationService.resolveCLIToolCall(
            text: malformedLookingText,
            toolsOffered: false
        ) {
            XCTFail("retry should never be invoked when tools were not offered")
            return ""
        }

        XCTAssertTrue(resolution.directives.isEmpty)
        XCTAssertFalse(resolution.toolCallLost)
    }

    /// A successful tool call on the first try must never retry.
    func testCorrectiveRetryNeverInvokedWhenFirstReplyAlreadyParses() async {
        let validCall = #"""
        {"companion_tool_call":{"name":"stage_agent_instruction","arguments":{"instruction":"send this"}}}
        """#

        let resolution = await AttachePresentationService.resolveCLIToolCall(
            text: validCall,
            toolsOffered: true
        ) {
            XCTFail("retry should never be invoked when the first reply already parses")
            return ""
        }

        XCTAssertEqual(resolution.directives.count, 1)
        XCTAssertFalse(resolution.toolCallLost)
    }

    /// Persisted legacy settings must stop before compilation, CLI launch, or
    /// tool execution. Codex CLI's read-only sandbox still permits native file
    /// reads, so it is not a safe personality inference transport.
    func testCodexPersonalityInferenceFailsClosedBeforeToolExecution() async throws {
        let suiteName = "AttacheLiveCodexRoutingCanary-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults for the live routing canary.")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AttachePreferenceKey.presentationLLMEnabled)

        let environment = [
            "ATTACHE_LLM_PROVIDER": "codex_cli",
            "ATTACHE_LLM_MODEL": "default",
            "ATTACHE_REASONING_EFFORT": "low"
        ]
        let modelSettings = AttachePresentationSettings.load(
            role: .conversation,
            defaults: defaults,
            environment: environment
        )
        let consentScope = PresentationConsentScope(
            provider: modelSettings.provider,
            endpoint: modelSettings.baseURL.absoluteString
        )
        defaults.set(
            [consentScope.storageKey],
            forKey: AttachePreferenceKey.cloudConsentPresentationProviders
        )
        let service = AttachePresentationService(defaults: defaults, environment: environment)
        let recorder = LiveToolCallRecorder()
        let user = "Untrusted prompt that must never reach Codex CLI."
        let snapshot = AttacheRequestSnapshot(
            requestID: "live-cli-routing-canary",
            role: .conversation,
            personality: Personality(
                id: "live-cli-routing-canary",
                name: "Attaché",
                prompt: AttachePersonality.defaultProfilePrompt
            ),
            profilePrompt: AttachePersonality.defaultProfilePrompt,
            userInput: user,
            session: .contextFree,
            modelSettings: modelSettings,
            contextItems: [],
            contextStrategy: .automatic
        )

        let result: Result<AttacheConversationReply, Error> = await withCheckedContinuation { continuation in
            service.converse(
                snapshot: snapshot,
                messages: [
                    AttacheChatMessage(role: "system", content: "System"),
                    AttacheChatMessage(role: "user", content: user)
                ],
                allowSessionContextTools: false,
                allowAgentInstructionTool: true,
                executeTool: { name, arguments in
                    await recorder.append(name: name, arguments: arguments)
                    return "unexpected tool execution"
                },
                completion: { continuation.resume(returning: $0) }
            )
        }
        guard case .failure(let error) = result else {
            return XCTFail("Codex personality inference unexpectedly succeeded")
        }
        guard let presentationError = error as? AttachePresentationError,
              case .notConfigured = presentationError else {
            return XCTFail("unexpected refusal error: \(error)")
        }
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty)
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

/// Counts corrective-retry invocations so a test can assert the retry
/// codepath ran exactly once, or never ran at all, not just that the final
/// result happens to match.
private actor RetryRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
