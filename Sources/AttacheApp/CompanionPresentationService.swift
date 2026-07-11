import AttacheCore
import Foundation
import os

final class CompanionPresentationService {
    private let defaults: UserDefaults
    private let environment: [String: String]
    private let memoryStore: CompanionMemoryStore
    private let personaStore: CompanionPersonaStore

    init(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults
        self.environment = environment
        self.memoryStore = CompanionMemoryStore(environment: environment)
        self.personaStore = CompanionPersonaStore(environment: environment)
    }

    func prepare(
        _ event: NormalizedEvent,
        personality: Personality?,
        completion: @escaping (NormalizedEvent) -> Void
    ) {
        if environment["ATTACHE_FORCE_PLAIN_READBACK"] == "1" {
            completion(Self.eventWithPlainReadbackPresentation(
                event,
                strategy: "plain-readback-forced"
            ))
            return
        }

        let unresolvedSettings = CompanionPresentationSettings.load(
            role: .presentation,
            defaults: defaults,
            environment: environment,
            resolveSecrets: false
        )

        guard unresolvedSettings.llmEnabled else {
            completion(Self.eventWithPlainReadbackPresentation(event))
            return
        }

        guard unresolvedSettings.hasProviderConfiguration,
              SourceKind.liveAgentRawValues.contains(event.source) else {
            completion(Self.eventWithPlainReadbackPresentation(
                event,
                strategy: "plain-readback-personality-unavailable"
            ))
            return
        }

        Task {
            let settings = CompanionPresentationSettings.load(role: .presentation, defaults: defaults, environment: environment)
            guard settings.isConfigured else {
                await MainActor.run {
                    completion(Self.eventWithPlainReadbackPresentation(
                        event,
                        strategy: "plain-readback-personality-unavailable"
                    ))
                }
                return
            }

            let presentedEvent: NormalizedEvent
            do {
                let memorySnapshot = memoryStore.loadSnapshot()
                let personaSnapshot = personaStore.loadSnapshot()
                presentedEvent = try await Self.eventWithLLMPresentation(
                    event,
                    settings: settings,
                    memorySnapshot: memorySnapshot,
                    personaSnapshot: personaSnapshot,
                    personality: personality,
                    spokenLanguageName: Self.spokenLanguageName(defaults: defaults)
                )
            } catch {
                var failed = Self.eventWithPlainReadbackPresentation(
                    event,
                    strategy: "plain-readback-after-llm-error"
                )
                failed.metadata["companion_presentation_error"] = error.localizedDescription
                // Store the classified category too (INF-254), not just the raw
                // error text, so a badge can show a short label ("rate limited")
                // instead of a raw error dump. Uses the same structural
                // classifier the live call's recovery menu uses (D1); this only
                // reads the failure, it never offers a switch/retry action here
                // (that only exists where a retry loop is possible).
                let presentationError = error as? CompanionPresentationError
                let recovery = ConversationRecovery.classify(
                    errorMessage: error.localizedDescription,
                    failedPrompt: "",
                    httpStatus: presentationError?.httpStatus,
                    urlErrorCode: presentationError?.urlErrorCode ?? (error as? URLError)?.code,
                    isCLIProvider: settings.provider.isCLI
                )
                failed.metadata["companion_presentation_error_category"] = recovery.category.rawValue
                presentedEvent = failed
            }

            await MainActor.run {
                completion(presentedEvent)
            }
        }
    }

    func answerFollowUpQuestion(
        card: VoicemailCard,
        danQuestion: String,
        completion: @escaping (Result<CompanionFollowUpAnswerResult, Error>) -> Void
    ) {
        let fallback = Self.fallbackFollowUpAnswer(
            card: card,
            danQuestion: danQuestion
        )
        let unresolvedSettings = CompanionPresentationSettings.load(
            role: .conversation,
            defaults: defaults,
            environment: environment,
            resolveSecrets: false
        )

        guard unresolvedSettings.llmEnabled,
              unresolvedSettings.hasProviderConfiguration,
              SourceKind.liveAgentRawValues.contains(card.sourceKind) else {
            completion(.success(fallback))
            return
        }

        Task {
            let settings = CompanionPresentationSettings.load(role: .conversation, defaults: defaults, environment: environment)
            guard settings.isConfigured else {
                await MainActor.run {
                    completion(.success(fallback))
                }
                return
            }

            do {
                let memorySnapshot = memoryStore.loadSnapshot()
                let personaSnapshot = personaStore.loadSnapshot()
                let profilePrompt = Self.firstNonEmpty(
                    settings.profilePrompt,
                    personaSnapshot.prompt,
                    CompanionPersonality.defaultProfilePrompt
                )
                let prompt = CompanionPersonality.followUpPrompt(
                    for: card,
                    danQuestion: danQuestion,
                    profilePrompt: profilePrompt,
                    memoryContext: memorySnapshot.context,
                    spokenLanguageName: Self.spokenLanguageName(defaults: defaults)
                )
                let content = try await Self.requestChatCompletion(messages: prompt.messages, settings: settings)
                let answer = Self.sanitizeFollowUpAnswerOutput(content)
                guard !answer.isEmpty else {
                    throw CompanionPresentationError.emptyResponse
                }
                let result = CompanionFollowUpAnswerResult(
                    answerText: answer,
                    strategy: "companion-personality-llm",
                    model: settings.model,
                    rawContextCharacterCount: prompt.rawContextCharacterCount,
                    truncatedContext: prompt.truncatedRawContext,
                    errorDescription: nil
                )
                await MainActor.run {
                    completion(.success(result))
                }
            } catch {
                var failed = fallback
                failed.strategy = "deterministic-follow-up-fallback-after-llm-error"
                failed.errorDescription = error.localizedDescription
                // Structural detail alongside the text (INF-254), so a caller
                // can classify via ConversationRecovery.classify and offer a
                // Switch model / Retry affordance the same way the live call
                // already does, instead of degrading silently.
                let presentationError = error as? CompanionPresentationError
                failed.errorHTTPStatus = presentationError?.httpStatus
                failed.errorURLErrorCode = presentationError?.urlErrorCode ?? (error as? URLError)?.code
                let failedResult = failed
                await MainActor.run {
                    completion(.success(failedResult))
                }
            }
        }
    }

    /// Multi-turn voice conversation with the personality. Sends the full message
    /// history plus the session-reading tools, runs the tool-call loop (executing
    /// each requested tool via `executeTool`), and returns the final spoken reply.
    /// - Parameter settingsOverride: when non-nil, used verbatim instead of
    ///   loading `.conversation` role settings from defaults (INF-258/D5):
    ///   the opt-in auto-fallback chain hands this call a specific provider
    ///   already resolved by `AppModel` (`CompanionPresentationSettings.forFallback`),
    ///   for just this call, without touching any persisted per-role default.
    ///   `nil` (the default) is byte-for-byte the original behavior.
    func converse(
        messages: [CompanionChatMessage],
        allowAgentInstructionTool: Bool = false,
        settingsOverride: CompanionPresentationSettings? = nil,
        executeTool: @escaping (String, String) async -> String,
        completion: @escaping (Result<CompanionConversationReply, Error>) -> Void
    ) {
        if let settingsOverride {
            guard settingsOverride.llmEnabled, settingsOverride.hasProviderConfiguration else {
                completion(.failure(CompanionPresentationError.notConfigured))
                return
            }
            Task {
                guard settingsOverride.isConfigured else {
                    await MainActor.run { completion(.failure(CompanionPresentationError.notConfigured)) }
                    return
                }
                do {
                    let reply = try await Self.runConversation(
                        messages: messages,
                        allowAgentInstructionTool: allowAgentInstructionTool,
                        settings: settingsOverride,
                        executeTool: executeTool
                    )
                    await MainActor.run { completion(.success(reply)) }
                } catch {
                    await MainActor.run { completion(.failure(error)) }
                }
            }
            return
        }

        let unresolved = CompanionPresentationSettings.load(
            role: .conversation,
            defaults: defaults,
            environment: environment,
            resolveSecrets: false
        )
        guard unresolved.llmEnabled, unresolved.hasProviderConfiguration else {
            completion(.failure(CompanionPresentationError.notConfigured))
            return
        }

        Task {
            let settings = CompanionPresentationSettings.load(role: .conversation, defaults: defaults, environment: environment)
            guard settings.isConfigured else {
                await MainActor.run { completion(.failure(CompanionPresentationError.notConfigured)) }
                return
            }
            do {
                let reply = try await Self.runConversation(
                    messages: messages,
                    allowAgentInstructionTool: allowAgentInstructionTool,
                    settings: settings,
                    executeTool: executeTool
                )
                await MainActor.run { completion(.success(reply)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    private static func runConversation(
        messages: [CompanionChatMessage],
        allowAgentInstructionTool: Bool,
        settings: CompanionPresentationSettings,
        executeTool: @escaping (String, String) async -> String
    ) async throws -> CompanionConversationReply {
        var payloadMessages: [[String: Any]] = messages.map { ["role": $0.role, "content": $0.content] }
        let tools = conversationTools(allowAgentInstructionTool: allowAgentInstructionTool)
        let maxToolRounds = 8   // room to page/search across a long session (INF-165)
        // Sticky across rounds: if any round in this conversation attempted and
        // lost a CLI tool call (INF-243), the final reply still flags it even
        // though a later round produced the text the user actually hears.
        var toolCallLost = false

        for _ in 0..<maxToolRounds {
            let result = try await requestChat(messages: payloadMessages, tools: tools, settings: settings)
            if result.toolCallLost { toolCallLost = true }
            if result.toolCalls.isEmpty {
                let text = sanitizeFollowUpAnswerOutput(result.content)
                guard !text.isEmpty else { throw CompanionPresentationError.emptyResponse }
                return CompanionConversationReply(text: text, toolCallLost: toolCallLost)
            }
            payloadMessages.append([
                "role": "assistant",
                "content": result.content,
                "tool_calls": result.toolCalls.map { call in
                    ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.arguments]]
                }
            ])
            for call in result.toolCalls {
                AttacheLog.presentation.info(
                    "conversation tool requested name=\(call.name, privacy: .public) argument_chars=\(call.arguments.count)"
                )
                // Bound each tool call so a stalled tool can't hang the turn; the
                // model gets a structured timeout result and keeps going.
                let toolResult = await withTimeout(seconds: 10) {
                    await executeTool(call.name, call.arguments)
                } onTimeout: {
                    "The \(call.name) tool did not respond in time. Answer from what you already have and tell the user you could not check that in time."
                }
                AttacheLog.presentation.info(
                    "conversation tool completed name=\(call.name, privacy: .public) result_chars=\(toolResult.count)"
                )
                payloadMessages.append(["role": "tool", "tool_call_id": call.id, "content": toolResult])
            }
        }

        // Tool budget spent: force a final answer with no further tool calls.
        let final = try await requestChat(messages: payloadMessages, tools: nil, settings: settings)
        if final.toolCallLost { toolCallLost = true }
        let text = sanitizeFollowUpAnswerOutput(final.content)
        guard !text.isEmpty else { throw CompanionPresentationError.emptyResponse }
        return CompanionConversationReply(text: text, toolCallLost: toolCallLost)
    }

    /// One-shot raw completion for background classification (used by both
    /// the inbox recap and topic tagging; callers pass their own role so each
    /// can pick its own model, see INF-247). Returns `nil` when the role's LLM
    /// isn't configured at all (expected, not an error), so callers can bail
    /// cheaply instead of spinning. Throws (INF-254) when it IS configured
    /// but the request itself failed, so callers can classify the failure via
    /// `ConversationRecovery.classify` instead of it vanishing into a
    /// swallowed `try?`.
    func complete(system: String, user: String, role: ModelRole) async throws -> String? {
        let unresolved = CompanionPresentationSettings.load(role: role, defaults: defaults, environment: environment, resolveSecrets: false)
        guard unresolved.llmEnabled, unresolved.hasProviderConfiguration else { return nil }
        let settings = CompanionPresentationSettings.load(role: role, defaults: defaults, environment: environment)
        guard settings.isConfigured else { return nil }
        return try await Self.requestChatCompletion(
            messages: [
                CompanionChatMessage(role: "system", content: system),
                CompanionChatMessage(role: "user", content: user)
            ],
            settings: settings
        )
    }

    /// Whether the given role's LLM is configured enough to make background
    /// calls. Deliberately keychain-free: presence comes from the defaults
    /// flag, and the actual calls resolve and re-check before requesting.
    func isPresentationConfigured(for role: ModelRole) -> Bool {
        let unresolved = CompanionPresentationSettings.load(role: role, defaults: defaults, environment: environment, resolveSecrets: false)
        return unresolved.llmEnabled && unresolved.hasProviderConfiguration
    }

    static func conversationTools(allowAgentInstructionTool: Bool) -> [[String: Any]] {
        var tools: [[String: Any]] = [
            ["type": "function", "function": [
                "name": "read_session_transcript",
                "description": "Read more of the attached session than the latest update. With no arguments, returns the opening turns plus the most recent turns (middle omitted, marked). Pass start_turn to page from a specific turn number (turns are labeled TURN n/total); pair with search_session_transcript to locate an earlier turn. Do not assume anything not shown was never discussed.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "start_turn": ["type": "integer", "description": "1-indexed turn number to start paging from. Omit for the opening+recent overview."],
                        "max_chars": ["type": "integer", "description": "Max characters of transcript to return (default 12000)."]
                    ]
                ] as [String: Any]
            ]],
            ["type": "function", "function": [
                "name": "search_session_transcript",
                "description": "Search the whole attached session transcript for a term and get back matching turn numbers with snippets. Use this to find where something was discussed, then read_session_transcript with that start_turn.",
                "parameters": [
                    "type": "object",
                    "properties": ["query": ["type": "string", "description": "Text to search for in the session's turns."]],
                    "required": ["query"]
                ] as [String: Any]
            ]],
            ["type": "function", "function": [
                "name": "list_working_directory",
                "description": "List the files in the session's working directory to see what exists before reading. Do not use this to hunt for an artifact when its exact path can be found in the session transcript, and do not probe unrelated protected folders.",
                "parameters": ["type": "object", "properties": [String: Any]()] as [String: Any]
            ]],
            ["type": "function", "function": [
                "name": "read_file",
                "description": "Read a file inside the session's working directory. Use an exact path learned from session context or transcript search; never guess a Desktop, Documents, or other protected-folder path.",
                "parameters": [
                    "type": "object",
                    "properties": ["path": ["type": "string", "description": "Path relative to the working directory."]],
                    "required": ["path"]
                ] as [String: Any]
            ]],
            ["type": "function", "function": [
                "name": "rename_session",
                "description": "Set the Attaché-local name for the attached work session (does not rename it in Codex). Use when the user asks to name or rename this session, e.g. \"let's call this the tax cleanup session\".",
                "parameters": [
                    "type": "object",
                    "properties": ["name": ["type": "string", "description": "The new short, descriptive name. Empty string resets to the Codex name."]],
                    "required": ["name"]
                ] as [String: Any]
            ]]
        ]
        if allowAgentInstructionTool {
            tools.append(["type": "function", "function": [
                "name": "stage_agent_instruction",
                "description": "Route an action to the focused work agent only when the user explicitly asks that agent to act. 'What did Codex say?' stays with Attaché, but 'Ask Codex what it changed' MUST use this tool. Asking the agent to answer, explain, check, read, summarize, or report is an action even when it concerns prior work or an artifact. Do not substitute local read tools for an explicit handoff, and do not redirect a request naming a different agent. Attaché applies the user's send policy, safety filter, and frozen session target. Whenever the user names a specific agent (Codex or Claude Code), set intended_agent to that agent so Attaché can verify it against the focused session before staging; never guess or omit intended_agent when a name was given.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "instruction": ["type": "string", "description": "The concise instruction to send to the work agent after the user confirms."],
                        "intended_agent": [
                            "type": "string",
                            "enum": ["codex", "claude_code"],
                            "description": "The agent the user explicitly named to receive this instruction. Always set this when the user names a specific agent; omit only when no agent was named. Attaché uses this solely to verify it matches the focused session; it never reroutes on a mismatch, only refuses."
                        ]
                    ],
                    "required": ["instruction"]
                ] as [String: Any]
            ]])
        }
        return tools
    }

    private struct ConversationChatResult {
        var content: String
        var toolCalls: [ConversationToolCall]
        // Set when a CLI personality attempted a tool call (INF-243) that never
        // recovered into a valid directive, even after the one corrective retry.
        // The turn still degrades into a spoken answer; this only flags that a
        // tool call was attempted and lost so a caller can surface it.
        var toolCallLost: Bool = false
    }

    struct CLIToolCallDirective: Equatable {
        var name: String
        var arguments: String
    }

    private struct ConversationToolCall {
        var id: String
        var name: String
        var arguments: String
    }

    private static func requestChat(
        messages: [[String: Any]],
        tools: [[String: Any]]?,
        settings: CompanionPresentationSettings
    ) async throws -> ConversationChatResult {
        if settings.provider.isCLI, let tool = settings.provider.cliTool {
            // The CLI has no OpenAI tool-call wire protocol, and we still run its
            // native tools disabled. Attaché tools are exposed through a narrow JSON
            // bridge in the prompt and executed by the app after parsing.
            var chatMessages = messages.compactMap { message -> CompanionChatMessage? in
                guard let role = message["role"] as? String,
                      let content = message["content"] as? String else { return nil }
                return CompanionChatMessage(role: role, content: content)
            }
            if let tools, !tools.isEmpty {
                chatMessages.insert(cliToolBridgeMessage(tools: tools), at: 0)
            }
            let model = CLILanguageModel(
                tool: tool, model: settings.model,
                reasoningEffort: settings.reasoningEffort, serviceTier: settings.serviceTier
            )
            let text = try await model.complete(messages: chatMessages)
            let toolsOffered = tools?.isEmpty == false
            let resolution = await resolveCLIToolCall(text: text, toolsOffered: toolsOffered) {
                var retryMessages = chatMessages
                retryMessages.append(CompanionChatMessage(role: "assistant", content: text))
                retryMessages.append(CompanionChatMessage(role: "user", content: cliCorrectiveRetryPrompt))
                return try await model.complete(messages: retryMessages)
            }
            return ConversationChatResult(
                content: resolution.directives.isEmpty ? text : "",
                toolCalls: resolution.directives.map {
                    ConversationToolCall(id: "cli-\(UUID().uuidString)", name: $0.name, arguments: $0.arguments)
                },
                toolCallLost: resolution.toolCallLost
            )
        }
        var url = settings.baseURL
        if !url.path.hasSuffix("/chat/completions") {
            url = url.appendingPathComponent("chat/completions")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.isEmpty, NetworkSecurity.allowsBearer(url) {
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }

        var payload: [String: Any] = [
            "model": settings.model,
            "temperature": 0.6,
            "messages": messages
        ]
        if let tools, !tools.isEmpty {
            payload["tools"] = tools
        }
        if settings.provider.supportsReasoningEffort,
           let reasoningEffort = normalizedReasoningEffort(settings.reasoningEffort) {
            payload["reasoning_effort"] = reasoningEffort
        }
        if settings.provider.supportsServiceTier,
           let serviceTier = normalizedServiceTier(settings.serviceTier) {
            payload["service_tier"] = serviceTier
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError {
            throw CompanionPresentationError.transport(urlError)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CompanionPresentationError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CompanionPresentationError.httpStatus(httpResponse.statusCode, body)
        }

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = (object?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        let content = message?["content"] as? String ?? ""
        var calls: [ConversationToolCall] = []
        if let toolCalls = message?["tool_calls"] as? [[String: Any]] {
            for toolCall in toolCalls {
                guard let id = toolCall["id"] as? String,
                      let function = toolCall["function"] as? [String: Any],
                      let name = function["name"] as? String else {
                    continue
                }
                let arguments = function["arguments"] as? String ?? "{}"
                calls.append(ConversationToolCall(id: id, name: name, arguments: arguments))
            }
        }
        return ConversationChatResult(content: content, toolCalls: calls)
    }

    static func cliToolBridgeMessage(tools: [[String: Any]]) -> CompanionChatMessage {
        let descriptions = tools.compactMap { tool -> String? in
            guard let function = tool["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }
            let description = (function["description"] as? String) ?? ""
            return "- \(name): \(description)"
        }.joined(separator: "\n")
        return CompanionChatMessage(role: "system", content: """
        Attaché tool bridge:
        You have access to these Attaché app tools even though this CLI run has its own native tools disabled:
        \(descriptions)

        To call a tool, reply with exactly one JSON object and no prose:
        {"attache_tool_call":{"name":"tool_name","arguments":{}}}

        Use one tool call at a time. After Attaché returns a tool result, either call another tool with the same JSON format or answer the user normally.
        """)
    }

    static func parseCLIToolDirectives(in text: String) -> [CLIToolCallDirective] {
        for candidate in cliJSONCandidates(in: text) {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let directives = cliToolDirectives(in: object)
            if !directives.isEmpty { return directives }
        }
        return []
    }

    /// The one corrective follow-up turn sent when a CLI personality's reply
    /// shows signs of an attempted tool call that failed to parse (INF-243).
    static let cliCorrectiveRetryPrompt = "Your last reply attempted a tool call but was not a single valid JSON object. Re-emit exactly one JSON object in the documented format, with no prose."

    /// Resolves a CLI turn's tool-call directives, retrying once when the reply
    /// looks like an attempted-but-malformed tool call (INF-243). A silent
    /// non-tool answer never retries; only genuine attempted calls do.
    ///
    /// - Parameters:
    ///   - text: the model's raw reply to the original turn.
    ///   - toolsOffered: whether this turn actually offered Attaché tools; a
    ///     retry is never worth attempting otherwise.
    ///   - retry: sends one corrective follow-up turn and returns the model's
    ///     new raw reply. Invoked at most once.
    /// - Returns: the recovered directives (empty if none), and whether a tool
    ///   call was attempted but ultimately lost even after the retry.
    static func resolveCLIToolCall(
        text: String,
        toolsOffered: Bool,
        retry: () async throws -> String
    ) async -> (directives: [CLIToolCallDirective], toolCallLost: Bool) {
        let directives = parseCLIToolDirectives(in: text)
        guard directives.isEmpty else { return (directives, false) }
        guard toolsOffered, cliTextIndicatesAttemptedToolCall(text) else { return ([], false) }

        guard let retryText = try? await retry() else {
            return ([], true)
        }
        let retryDirectives = parseCLIToolDirectives(in: retryText)
        guard !retryDirectives.isEmpty else {
            return ([], true)
        }
        return (retryDirectives, false)
    }

    /// True when free text shows signs of an attempted (possibly malformed)
    /// Attaché tool-call JSON, as opposed to a plain conversational answer that
    /// never tried to call a tool at all.
    private static func cliTextIndicatesAttemptedToolCall(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("attache_tool_call") { return true }
        if fencedJSON(in: trimmed) != nil { return true }
        if let object = firstJSONObject(in: trimmed) {
            let parsesAsJSON = object.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } != nil
            if !parsesAsJSON { return true }
        }
        return false
    }

    private static func cliJSONCandidates(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [trimmed]
        if let fenced = fencedJSON(in: trimmed) {
            candidates.append(fenced)
        }
        if let object = firstJSONObject(in: trimmed) {
            candidates.append(object)
        }
        return Array(Set(candidates)).filter { !$0.isEmpty }
    }

    private static func fencedJSON(in text: String) -> String? {
        guard let start = text.range(of: "```") else { return nil }
        var body = String(text[start.upperBound...])
        if body.lowercased().hasPrefix("json") {
            body = String(body.dropFirst("json".count))
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let end = body.range(of: "```") else { return nil }
        return String(body[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaping = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func cliToolDirectives(in object: [String: Any]) -> [CLIToolCallDirective] {
        if let call = object["attache_tool_call"] as? [String: Any],
           let directive = cliToolDirective(in: call) {
            return [directive]
        }
        if let call = object["tool_call"] as? [String: Any],
           let directive = cliToolDirective(in: call) {
            return [directive]
        }
        if let calls = object["tool_calls"] as? [[String: Any]] {
            return calls.compactMap(cliToolDirective)
        }
        return []
    }

    private static func cliToolDirective(in object: [String: Any]) -> CLIToolCallDirective? {
        if let function = object["function"] as? [String: Any] {
            guard let name = function["name"] as? String else { return nil }
            return CLIToolCallDirective(name: name, arguments: argumentsString(function["arguments"]))
        }
        guard let name = object["name"] as? String else { return nil }
        return CLIToolCallDirective(name: name, arguments: argumentsString(object["arguments"]))
    }

    private static func argumentsString(_ value: Any?) -> String {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "{}" : trimmed
        }
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    static func eventWithPlainReadbackPresentation(
        _ event: NormalizedEvent,
        strategy: String = "plain-readback"
    ) -> NormalizedEvent {
        var presented = event
        if presented.metadata["companion_summary"] == nil {
            presented.metadata["companion_summary"] = EventNormalizer.summary(for: event)
        }
        presented.metadata["companion_spoken_text"] = event.text
        presented.metadata["companion_presentation_strategy"] = strategy
        return presented
    }

    private static func eventWithLLMPresentation(
        _ event: NormalizedEvent,
        settings: CompanionPresentationSettings,
        memorySnapshot: CompanionMemorySnapshot,
        personaSnapshot: CompanionPersonaSnapshot,
        personality: Personality?,
        spokenLanguageName: String? = nil
    ) async throws -> NormalizedEvent {
        let profilePrompt = firstNonEmpty(personality?.prompt, settings.profilePrompt, personaSnapshot.prompt, CompanionPersonality.defaultProfilePrompt)
        let prompt = CompanionPersonality.presentationPrompt(
            for: event,
            profilePrompt: profilePrompt,
            memoryContext: memorySnapshot.context,
            spokenLanguageName: spokenLanguageName
        )
        let content = try await requestChatCompletion(messages: prompt.messages, settings: settings)
        let response = splitCardSummary(content)

        guard !response.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CompanionPresentationError.emptyResponse
        }

        var presented = event
        if presented.metadata["companion_summary"] == nil {
            presented.metadata["companion_summary"] = EventNormalizer.summary(for: event)
        }
        if !response.summary.isEmpty {
            presented.metadata["companion_summary"] = response.summary
        }
        presented.metadata["companion_spoken_text"] = response.spokenText
        if response.needsDecision {
            presented.metadata["companion_needs_decision"] = "1"
        }
        presented.metadata["companion_presentation_strategy"] = "companion-personality-llm"
        presented.metadata["companion_llm_provider"] = settings.provider.rawValue
        presented.metadata["companion_llm_model"] = settings.model
        presented.metadata["companion_llm_base_url"] = settings.baseURL.absoluteString
        if let personality {
            presented.metadata["companion_personality_id"] = personality.id
            presented.metadata["companion_personality_name"] = personality.name
        }
        presented.metadata["companion_personality_profile"] = personality?.id ?? "default"
        presented.metadata["companion_personality_file"] = personaSnapshot.fileURL.path
        presented.metadata["companion_memory_file"] = memorySnapshot.fileURL.path
        presented.metadata["companion_memory_context_chars"] = String(memorySnapshot.context?.count ?? 0)
        presented.metadata["companion_raw_output_chars"] = String(prompt.rawOutputCharacterCount)
        presented.metadata["companion_raw_output_truncated"] = prompt.truncatedRawOutput ? "true" : "false"
        if let errorDescription = memorySnapshot.errorDescription {
            presented.metadata["companion_memory_error"] = errorDescription
        }
        if let errorDescription = personaSnapshot.errorDescription {
            presented.metadata["companion_personality_error"] = errorDescription
        }
        if let reasoningEffort = settings.reasoningEffort, !reasoningEffort.isEmpty {
            presented.metadata["companion_llm_reasoning_effort"] = reasoningEffort
        }
        return presented
    }

    private static func requestChatCompletion(
        messages: [CompanionChatMessage],
        settings: CompanionPresentationSettings
    ) async throws -> String {
        if settings.provider.isCLI, let tool = settings.provider.cliTool {
            return try await CLILanguageModel(
                tool: tool, model: settings.model,
                reasoningEffort: settings.reasoningEffort, serviceTier: settings.serviceTier
            ).complete(messages: messages)
        }
        var url = settings.baseURL
        if !url.path.hasSuffix("/chat/completions") {
            url = url.appendingPathComponent("chat/completions")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.isEmpty, NetworkSecurity.allowsBearer(url) {
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }

        var payload: [String: Any] = [
            "model": settings.model,
            "temperature": 0.6,
            "messages": messages.map { message in
                [
                    "role": message.role,
                    "content": message.content
                ]
            }
        ]
        if settings.provider.supportsReasoningEffort,
           let reasoningEffort = normalizedReasoningEffort(settings.reasoningEffort) {
            payload["reasoning_effort"] = reasoningEffort
        }
        if settings.provider.supportsServiceTier,
           let serviceTier = normalizedServiceTier(settings.serviceTier) {
            payload["service_tier"] = serviceTier
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError {
            throw CompanionPresentationError.transport(urlError)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CompanionPresentationError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CompanionPresentationError.httpStatus(httpResponse.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        return decoded.choices.first?.message.content ?? ""
    }

    private static func splitCardSummary(_ content: String) -> (summary: String, spokenText: String, needsDecision: Bool) {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ("", "", false) }

        var lines = text.components(separatedBy: .newlines)
        var summary = ""
        var bodyStart = 0
        for (index, line) in lines.enumerated() {
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { continue }
            if stripped.range(of: #"(?i)^card[_ ]?summary\s*:\s*(.+)$"#, options: .regularExpression) != nil,
               let separator = stripped.firstIndex(of: ":") {
                summary = String(stripped[stripped.index(after: separator)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                bodyStart = index + 1
            }
            break
        }

        var needsDecision = false
        lines = lines.enumerated().filter { index, line in
            guard index >= bodyStart else { return true }
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if stripped.range(of: #"(?i)^needs[_ ]?decision\s*:"#, options: .regularExpression) != nil {
                needsDecision = stripped.range(of: #"(?i)yes|true"#, options: .regularExpression) != nil
                return false
            }
            return true
        }.map(\.element)

        let spoken = lines.dropFirst(bodyStart)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let spokenText = spoken.isEmpty ? text : spoken
        if summary.isEmpty {
            summary = EventNormalizer.summary(for: NormalizedEvent(
                source: SourceKind.codex.rawValue,
                eventType: "assistant.completed",
                title: "Codex update",
                text: spokenText
            ), limit: 120)
        }
        return (CompanionPersonality.stripDashes(summary), CompanionPersonality.stripDashes(spokenText), needsDecision)
    }

    private static func fallbackFollowUpAnswer(
        card: VoicemailCard,
        danQuestion: String
    ) -> CompanionFollowUpAnswerResult {
        let trimmedQuestion = danQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = card.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let headline = summary.isEmpty ? "I can answer from the latest observed update." : summary
        let spokenContext = card.spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = spokenContext.isEmpty ? card.rawText : spokenContext
        let answer = """
        \(headline)

        Based on Attaché context I have, \(clipped(context, limit: 900))

        Your question was: \(trimmedQuestion)

        I can answer from the observed update, but I cannot send anything back into Codex from here.
        """
        return CompanionFollowUpAnswerResult(
            answerText: answer.trimmingCharacters(in: .whitespacesAndNewlines),
            strategy: "deterministic-follow-up-fallback",
            model: nil,
            rawContextCharacterCount: card.rawText.count,
            truncatedContext: false,
            errorDescription: nil
        )
    }

    private static func sanitizeFollowUpAnswerOutput(_ content: String) -> String {
        let trimmed = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```text", with: "")
            .replacingOccurrences(of: "```markdown", with: "")
            .replacingOccurrences(of: "```", with: "")

        let blockedPrefixes = [
            "CARD_SUMMARY:",
            "SPOKEN_TEXT:",
            "DRAFT:",
            "CODEX-READY DRAFT:"
        ].map { $0.uppercased() }
        let blockedFragments = [
            "sending the follow-up",
            "sending now",
            "ready when you are",
            "want me to send",
            "should i send",
            "would you like me to send",
            "i can send",
            "i'll send",
            "i will send"
        ]

        let lines = trimmed
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return true }
                let uppercased = line.uppercased()
                let lowercased = line.lowercased()
                return !blockedPrefixes.contains { uppercased.hasPrefix($0) }
                    && !blockedFragments.contains { lowercased.contains($0) }
            }

        let cleaned = lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CompanionPersonality.stripDashes(cleaned)
    }

    private static func clipped(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return String(trimmed[..<end]) + "..."
    }

    /// The user's spoken-language preference as an English language name for
    /// the prompt, or nil for English (no directive needed).
    static func spokenLanguageName(defaults: UserDefaults) -> String? {
        guard let id = defaults.string(forKey: CompanionPreferenceKey.spokenLanguage),
              id != "en" else { return nil }
        return CompanionCaptionLanguage.named(id).name
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return ""
    }

    private static func normalizedServiceTier(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        switch trimmed.lowercased() {
        case "default", "standard":
            return nil
        default:
            return trimmed
        }
    }

    /// `"default"` (use the API's own default) and `"none"` (the user
    /// explicitly turned reasoning effort off) both mean "omit the field",
    /// not "send this literal string". Sending `"none"` as a real
    /// `reasoning_effort` value caused a 400 from any model that rejects the
    /// field outright rather than accepting an off-like value. Internal
    /// (not private) so `Tests/AttacheAppTests/CompanionPresentationServiceTests.swift`
    /// can pin this directly without standing up a real HTTP round trip.
    static func normalizedReasoningEffort(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        switch trimmed.lowercased() {
        case "default", "none":
            return nil
        default:
            return trimmed
        }
    }
}

struct CompanionFollowUpAnswerResult: Equatable {
    var answerText: String
    var strategy: String
    var model: String?
    var rawContextCharacterCount: Int
    var truncatedContext: Bool
    var errorDescription: String?
    /// Structural detail behind `errorDescription` (INF-254), present only
    /// when `strategy == "deterministic-follow-up-fallback-after-llm-error"`.
    /// Lets a caller classify the failure via `ConversationRecovery.classify`
    /// instead of re-parsing the description text.
    var errorHTTPStatus: Int? = nil
    var errorURLErrorCode: URLError.Code? = nil
}

/// The final spoken reply from a live `converse` turn, plus whether a CLI
/// personality attempted a tool call that never recovered into a valid
/// directive even after the one corrective retry (INF-243). The reply itself
/// is always a usable spoken answer either way; `toolCallLost` only tells a
/// caller that a tool call was attempted and silently dropped, so it can
/// surface that instead of leaving the loss invisible.
struct CompanionConversationReply: Equatable {
    var text: String
    var toolCallLost: Bool = false
}

/// The independent LLM consumers that can each select their own
/// provider/model (INF-247). Follow-up answers ride `.conversation` (they go
/// through the same `answerFollowUpQuestion` call as live conversation), and
/// instruction phrasing is a tool argument of the converse call rather than a
/// separate request, so it rides `.conversation` too; neither gets its own
/// case.
enum ModelRole: String, CaseIterable {
    case conversation
    case presentation
    case recap
    case tagging
}

struct CompanionPresentationSettings: Equatable {
    var llmEnabled: Bool
    var provider: CompanionPresentationProvider
    var baseURL: URL
    var apiKey: String
    var apiKeySecretRef: String
    var model: String
    var reasoningEffort: String?
    var serviceTier: String?
    var profilePrompt: String
    /// True when the provider's key account is flagged in defaults, so
    /// unresolved loads can answer "is a key stored" without touching the
    /// keychain (a keychain read can block on a SecurityAgent prompt).
    var apiKeyStoredInKeychain: Bool = false

    var isConfigured: Bool {
        if provider.requiresAPIKey {
            return !apiKey.isEmpty && !model.isEmpty
        }
        return !model.isEmpty
    }

    var hasProviderConfiguration: Bool {
        if provider.requiresAPIKey {
            return (!apiKey.isEmpty || !apiKeySecretRef.isEmpty || apiKeyStoredInKeychain) && !model.isEmpty
        }
        return !model.isEmpty
    }

    /// - Parameter role: which LLM consumer this load is for (INF-247).
    ///   Every field below checks, in order: the global `ATTACHE_LLM_*` /
    ///   `COMPANION_LLM_*` environment overrides (so smoke scripts and
    ///   canaries keep affecting every role, not just one), then the
    ///   `role`-specific default key, then the existing global default key,
    ///   then the provider's built-in default. With no per-role key ever
    ///   set, every role resolves byte-for-byte the same as before per-role
    ///   selection existed.
    static func load(
        role: ModelRole,
        defaults: UserDefaults,
        environment: [String: String],
        resolveSecrets: Bool = true
    ) -> CompanionPresentationSettings {
        let llmEnabled: Bool
        if defaults.object(forKey: CompanionPreferenceKey.presentationLLMEnabled) == nil {
            llmEnabled = true
        } else {
            llmEnabled = defaults.bool(forKey: CompanionPreferenceKey.presentationLLMEnabled)
        }

        let explicitProviderText = firstNonEmpty(
            environment["ATTACHE_LLM_PROVIDER"],
            environment["COMPANION_LLM_PROVIDER"],
            defaults.string(forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .provider)),
            defaults.string(forKey: CompanionPreferenceKey.presentationLLMProvider),
            ""
        )
        let configuredBaseURLText = firstNonEmpty(
            environment["ATTACHE_LLM_BASE_URL"],
            environment["COMPANION_LLM_BASE_URL"],
            defaults.string(forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .baseURL)),
            defaults.string(forKey: CompanionPreferenceKey.presentationLLMBaseURL),
            ""
        )
        let provider = CompanionPresentationProvider.from(
            explicitValue: explicitProviderText,
            baseURLText: configuredBaseURLText
        )
        let baseURLText = firstNonEmpty(configuredBaseURLText, provider.defaultBaseURL)
        let baseURL = URL(string: baseURLText) ?? URL(string: CompanionPresentationProvider.ollama.defaultBaseURL)!
        let apiKeySecretRef = firstNonEmpty(
            environment["ATTACHE_LLM_API_KEY_SECRET_REF"],
            environment["COMPANION_LLM_API_KEY_SECRET_REF"],
            defaults.string(forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .apiKeySecretRef)),
            defaults.string(forKey: CompanionPreferenceKey.presentationLLMAPIKeySecretRef),
            ""
        )
        // The keychain is only touched when secrets are actually being
        // resolved; unresolved loads run on the launch path and must never
        // block on a SecurityAgent authorization.
        let secretAccountFlagged = ((defaults.array(forKey: CompanionPreferenceKey.configuredSecretAccounts) as? [String]) ?? [])
            .contains(provider.developmentSecretAccount)
        var apiKey = firstNonEmpty(
            environment["ATTACHE_LLM_API_KEY"],
            environment["COMPANION_LLM_API_KEY"],
            resolveSecrets ? configuredSecret(defaults: defaults, account: provider.developmentSecretAccount) : nil,
            defaults.string(forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .apiKey)),
            defaults.string(forKey: CompanionPreferenceKey.presentationLLMAPIKey),
            ""
        )
        if resolveSecrets, apiKey.isEmpty, !apiKeySecretRef.isEmpty {
            apiKey = CompanionSecretStore.readSecret(reference: apiKeySecretRef) ?? ""
        }
        let model = firstNonEmpty(
            environment["ATTACHE_LLM_MODEL"],
            environment["COMPANION_LLM_MODEL"],
            defaults.string(forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .model)),
            defaults.string(forKey: CompanionPreferenceKey.presentationLLMModel),
            provider.defaultModel
        )
        let configuredReasoningEffort = firstNonEmpty(
            environment["ATTACHE_REASONING_EFFORT"],
            environment["COMPANION_REASONING_EFFORT"],
            defaults.string(forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .reasoningEffort)),
            defaults.string(forKey: CompanionPreferenceKey.presentationReasoningEffort),
            provider.defaultReasoningEffort
        )
        let reasoningEffort = provider.supportsReasoningEffort ? configuredReasoningEffort : "none"
        let serviceTier = provider.supportsServiceTier
            ? firstNonEmpty(
                environment["ATTACHE_SERVICE_TIER"],
                defaults.string(forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .serviceTier)),
                defaults.string(forKey: CompanionPreferenceKey.presentationServiceTier),
                provider.defaultServiceTier
            )
            : nil
        let profilePrompt = firstNonEmpty(
            environment["ATTACHE_PERSONALITY_PROMPT"],
            environment["ATTACHE_PROFILE_PROMPT"],
            environment["COMPANION_PERSONALITY_PROMPT"],
            defaults.string(forKey: CompanionPreferenceKey.personalityPrompt),
            ""
        )
        return CompanionPresentationSettings(
            llmEnabled: llmEnabled,
            provider: provider,
            baseURL: baseURL,
            apiKey: apiKey,
            apiKeySecretRef: apiKeySecretRef,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            profilePrompt: profilePrompt,
            apiKeyStoredInKeychain: secretAccountFlagged
        )
    }

    /// Builds settings for `provider` directly, bypassing every per-role
    /// persisted override (INF-258/D5): the opt-in auto-fallback chain hands
    /// the live conversation call a specific provider for just the rest of
    /// this call, never a Settings change, so it must not read or write any
    /// `presentationLLM*` default. The caller (`AppModel`) already has
    /// `baseURLText` (`endpointForIntegration(provider)`) and `apiKey`
    /// (`readConfiguredSecret(account: provider.developmentSecretAccount)`)
    /// on hand from the exact same helpers Settings itself uses.
    static func forFallback(
        provider: CompanionPresentationProvider,
        baseURLText: String,
        apiKey: String,
        profilePrompt: String
    ) -> CompanionPresentationSettings {
        let baseURLText = firstNonEmpty(baseURLText, provider.defaultBaseURL)
        let baseURL = URL(string: baseURLText) ?? URL(string: CompanionPresentationProvider.ollama.defaultBaseURL)!
        return CompanionPresentationSettings(
            llmEnabled: true,
            provider: provider,
            baseURL: baseURL,
            apiKey: apiKey,
            apiKeySecretRef: "",
            model: provider.defaultModel,
            reasoningEffort: provider.supportsReasoningEffort ? provider.defaultReasoningEffort : "none",
            serviceTier: provider.supportsServiceTier ? provider.defaultServiceTier : nil,
            profilePrompt: profilePrompt,
            apiKeyStoredInKeychain: !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return ""
    }

    private static func configuredSecret(defaults: UserDefaults, account: String) -> String? {
        let accounts = defaults.array(forKey: CompanionPreferenceKey.configuredSecretAccounts) as? [String] ?? []
        guard accounts.contains(account) else { return nil }
        return CompanionSecretVault.read(account: account)
    }
}

// Not private: AppModel inspects `httpStatus` / `urlErrorCode` to classify
// conversation failures structurally (see ConversationRecovery.classify).
enum CompanionPresentationError: LocalizedError {
    case emptyResponse
    case invalidResponse
    case httpStatus(Int, String)
    case notConfigured
    case transport(URLError)

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "LLM response was empty."
        case .invalidResponse:
            return "LLM response was not HTTP."
        case .httpStatus(let status, let body):
            let clipped = String(body.prefix(300))
            return "LLM request failed with HTTP \(status): \(clipped)"
        case .notConfigured:
            return "No personality LLM is configured. Set one up in Settings → Model."
        case .transport(let urlError):
            return "LLM request failed: \(urlError.localizedDescription)"
        }
    }

    /// The HTTP status code, when the failure carries one. `nil` for
    /// transport-level failures (timeout, connection loss) and other
    /// non-HTTP errors.
    var httpStatus: Int? {
        if case .httpStatus(let status, _) = self { return status }
        return nil
    }

    /// The URLError code, when the failure is a transport-level failure
    /// (timeout, connection loss, DNS failure, etc.) rather than an HTTP
    /// response.
    var urlErrorCode: URLError.Code? {
        if case .transport(let urlError) = self { return urlError.code }
        return nil
    }
}

private struct ChatCompletionResponse: Decodable {
    var choices: [Choice]

    struct Choice: Decodable {
        var message: Message
    }

    struct Message: Decodable {
        var content: String?
    }
}
