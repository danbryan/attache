import AttacheCore
import Foundation
import os

private final class AttacheInferenceAccumulator: @unchecked Sendable {
    private var inferences: [AttacheInferenceMetadata] = []
    private let requestID: String

    init(requestID: String) {
        self.requestID = requestID
    }

    func record(_ inference: AttacheInferenceMetadata) {
        inferences.append(inference)
    }

    func aggregate(appending inference: AttacheInferenceMetadata? = nil) -> AttacheInferenceMetadata? {
        var values = inferences
        if let inference { values.append(inference) }
        return AttacheInferenceMetadata.aggregating(values, requestID: requestID)
    }
}

final class AttachePresentationService {
    private let defaults: UserDefaults
    private let environment: [String: String]
    private let requestBroker: AttacheProductionRequestBroker

    init(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        requestBroker: AttacheProductionRequestBroker = AttacheProductionRequestBroker()
    ) {
        self.defaults = defaults
        self.environment = environment
        self.requestBroker = requestBroker
    }

    func prepare(
        _ event: NormalizedEvent,
        snapshot: AttacheRequestSnapshot,
        completion: @escaping (AttachePreparedEventResult) -> Void
    ) {
        precondition(snapshot.role == .presentation)
        if environment["ATTACHE_FORCE_PLAIN_READBACK"] == "1" {
            completion(Self.preparedResult(
                event: Self.eventWithPlainReadbackPresentation(
                    event,
                    strategy: "plain-readback-forced"
                ),
                inference: .noModel(snapshot: snapshot)
            ))
            return
        }
        guard SourceKind.liveAgentRawValues.contains(event.source),
              let attempt = frozenAttempt(snapshot: snapshot) else {
            completion(Self.preparedResult(
                event: Self.eventWithPlainReadbackPresentation(
                    event,
                    strategy: "plain-readback-personality-unavailable"
                ),
                inference: .noModel(snapshot: snapshot)
            ))
            return
        }

        let prompt = AttachePersonality.presentationPrompt(
            for: event,
            profilePrompt: snapshot.profilePrompt,
            memoryContext: nil,
            spokenLanguageName: Self.spokenLanguageName(defaults: defaults)
        )

        Task {
            let prepared: AttachePreparedEventResult
            do {
                let response = try await requestBroker.perform(
                    snapshot: snapshot,
                    attempt: attempt,
                    messages: prompt.messages,
                    messageSources: AttacheProductionRequestBroker.prebuiltMessageSources(
                        snapshot: snapshot,
                        messages: prompt.messages
                    )
                )
                let event = try Self.eventWithLLMPresentation(
                    event,
                    prompt: prompt,
                    response: response,
                    attempt: attempt,
                    snapshot: snapshot
                )
                prepared = Self.preparedResult(event: event, inference: response.metadata)
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
                let rootError = Self.underlyingBrokerError(error)
                let presentationError = rootError as? AttachePresentationError
                let recovery = ConversationRecovery.classify(
                    errorMessage: error.localizedDescription,
                    failedPrompt: "",
                    httpStatus: presentationError?.httpStatus,
                    urlErrorCode: presentationError?.urlErrorCode ?? (rootError as? URLError)?.code,
                    isCLIProvider: attempt.provider.isCLI
                )
                failed.metadata["companion_presentation_error_category"] = recovery.category.rawValue
                prepared = Self.preparedResult(
                    event: failed,
                    inference: Self.failureInference(error, snapshot: snapshot)
                )
            }

            await MainActor.run {
                completion(prepared)
            }
        }
    }

    func answerFollowUpQuestion(
        card: VoicemailCard,
        danQuestion: String,
        snapshot: AttacheRequestSnapshot,
        requestIsActive: (() async -> Bool)? = nil,
        completion: @escaping (Result<AttacheFollowUpAnswerResult, Error>) -> Void
    ) {
        precondition(snapshot.role == .followUp || snapshot.role == .liveFollowUp)
        if snapshot.role == .liveFollowUp {
            guard let focused = snapshot.focusedSession,
                  card.externalSessionID == focused.sessionID else {
                completion(.failure(AttachePresentationError.unauthorizedContext))
                return
            }
        }
        let noModel = AttacheInferenceMetadata.noModel(snapshot: snapshot)
        var fallback = Self.fallbackFollowUpAnswer(
            card: card,
            danQuestion: danQuestion,
            inference: noModel
        )
        guard SourceKind.liveAgentRawValues.contains(card.sourceKind),
              let attempt = frozenAttempt(snapshot: snapshot) else {
            completion(.success(fallback))
            return
        }
        let prompt = AttachePersonality.followUpPrompt(
            for: card,
            danQuestion: danQuestion,
            profilePrompt: snapshot.profilePrompt,
            memoryContext: nil,
            spokenLanguageName: Self.spokenLanguageName(defaults: defaults)
        )

        Task {
            do {
                let response = try await requestBroker.perform(
                    snapshot: snapshot,
                    attempt: attempt,
                    messages: prompt.messages,
                    messageSources: AttacheProductionRequestBroker.prebuiltMessageSources(
                        snapshot: snapshot,
                        messages: prompt.messages
                    ),
                    requestIsActive: requestIsActive
                )
                let answer = Self.sanitizeFollowUpAnswerOutput(response.content)
                guard !answer.isEmpty else { throw AttachePresentationError.emptyResponse }
                let result = AttacheFollowUpAnswerResult(
                    answerText: answer,
                    strategy: "attache-personality-llm",
                    model: attempt.model,
                    rawContextCharacterCount: prompt.rawContextCharacterCount,
                    truncatedContext: prompt.truncatedRawContext,
                    errorDescription: nil,
                    inference: response.metadata
                )
                await MainActor.run { completion(.success(result)) }
            } catch {
                fallback.strategy = "deterministic-follow-up-fallback-after-llm-error"
                fallback.errorDescription = error.localizedDescription
                fallback.inference = Self.failureInference(error, snapshot: snapshot)
                let rootError = Self.underlyingBrokerError(error)
                let presentationError = rootError as? AttachePresentationError
                fallback.errorHTTPStatus = presentationError?.httpStatus
                fallback.errorURLErrorCode = presentationError?.urlErrorCode ?? (rootError as? URLError)?.code
                let result = fallback
                await MainActor.run { completion(.success(result)) }
            }
        }
    }

    /// Multi-round personality conversation. Every provider-bound round,
    /// including corrective CLI rounds and the final no-tools round, goes back
    /// through the production broker and `ContextCompiler`.
    @discardableResult
    func converse(
        snapshot: AttacheRequestSnapshot,
        messages: [AttacheChatMessage],
        allowSessionContextTools: Bool,
        allowAgentInstructionTool: Bool = false,
        allowMemoryProposalTool: Bool = false,
        allowSessionDiscoveryTool: Bool = false,
        allowExhaustiveReviewTool: Bool = false,
        settingsOverride: AttachePresentationSettings? = nil,
        requestIsActive: @escaping () async -> Bool = { true },
        attemptDidCompile: ((AttacheInferenceMetadata) async -> Void)? = nil,
        executeTool: @escaping (String, String) async -> String,
        completion: @escaping (Result<AttacheConversationReply, Error>) -> Void
    ) -> Task<Void, Never> {
        precondition(snapshot.role == .conversation)
        if allowSessionContextTools && !snapshot.session.isFocused {
            completion(.failure(AttachePresentationError.invalidResponse))
            return Task {}
        }

        let definitions: Data
        do {
            definitions = try AttacheProductionRequestBroker.conversationToolDefinitions(
                allowSessionContextTools: allowSessionContextTools,
                allowAgentInstructionTool: allowAgentInstructionTool,
                allowMemoryProposalTool: allowMemoryProposalTool,
                allowSessionDiscoveryTool: allowSessionDiscoveryTool,
                allowExhaustiveReviewTool: allowExhaustiveReviewTool
            )
        } catch {
            completion(.failure(error))
            return Task {}
        }
        guard let attempt = frozenAttempt(
            snapshot: snapshot,
            settingsOverride: settingsOverride,
            toolDefinitionsJSON: definitions
        ) else {
            completion(.failure(AttachePresentationError.notConfigured))
            return Task {}
        }
        let finalAttempt = attempt.withoutTools()
        let offeredToolNames = Self.toolNames(in: definitions)

        return Task {
            do {
                let reply = try await runConversation(
                    snapshot: snapshot,
                    messages: messages,
                    attempt: attempt,
                    finalAttempt: finalAttempt,
                    offeredToolNames: offeredToolNames,
                    requestIsActive: requestIsActive,
                    attemptDidCompile: attemptDidCompile,
                    executeTool: executeTool
                )
                await MainActor.run { completion(.success(reply)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    private func runConversation(
        snapshot: AttacheRequestSnapshot,
        messages: [AttacheChatMessage],
        attempt: AttacheFrozenModelAttempt,
        finalAttempt: AttacheFrozenModelAttempt,
        offeredToolNames: Set<String>,
        requestIsActive: @escaping () async -> Bool,
        attemptDidCompile: ((AttacheInferenceMetadata) async -> Void)?,
        executeTool: @escaping (String, String) async -> String
    ) async throws -> AttacheConversationReply {
        var payloadMessages = messages
        var payloadSources = AttacheProductionRequestBroker.prebuiltMessageSources(
            snapshot: snapshot,
            messages: messages
        )
        var toolCallLost = false
        let inferenceAccumulator = AttacheInferenceAccumulator(
            requestID: snapshot.requestID
        )

        for _ in 0..<8 {
            try await Self.requireActiveConversation(requestIsActive)
            var response = try await performConversationRound(
                snapshot: snapshot,
                attempt: attempt,
                messages: payloadMessages,
                messageSources: payloadSources,
                accumulator: inferenceAccumulator,
                attemptDidCompile: attemptDidCompile,
                requestIsActive: requestIsActive
            )
            try await Self.requireActiveConversation(requestIsActive)

            if attempt.provider.isCLI,
               !offeredToolNames.isEmpty,
               response.toolCalls.isEmpty,
               Self.cliTextIndicatesAttemptedToolCall(response.content) {
                var correctiveMessages = response.compiledMessages
                let attemptedToolText = AttacheChatMessage(role: "assistant", content: response.content)
                let correctiveInstruction = AttacheChatMessage(role: "user", content: Self.cliCorrectiveRetryPrompt)
                correctiveMessages.append(attemptedToolText)
                correctiveMessages.append(correctiveInstruction)
                var correctiveSources = payloadSources
                correctiveSources.append(AttachePrebuiltMessageSource(
                    message: attemptedToolText,
                    source: .recentDirectChatTurns
                ))
                correctiveSources.append(AttachePrebuiltMessageSource(
                    message: correctiveInstruction,
                    source: .safetyPolicy
                ))
                try await Self.requireActiveConversation(requestIsActive)
                response = try await performConversationRound(
                    snapshot: snapshot,
                    attempt: attempt,
                    messages: correctiveMessages,
                    messageSources: correctiveSources,
                    accumulator: inferenceAccumulator,
                    attemptDidCompile: attemptDidCompile,
                    requestIsActive: requestIsActive
                )
                try await Self.requireActiveConversation(requestIsActive)
                payloadSources = correctiveSources
                if response.toolCalls.isEmpty { toolCallLost = true }
            }

            guard response.toolCalls.allSatisfy({ offeredToolNames.contains($0.name) }) else {
                throw Self.conversationFailure(
                    AttachePresentationError.invalidResponse,
                    accumulator: inferenceAccumulator
                )
            }
            if response.toolCalls.isEmpty {
                let text = Self.sanitizeFollowUpAnswerOutput(response.content)
                guard !text.isEmpty else {
                    throw Self.conversationFailure(
                        AttachePresentationError.emptyResponse,
                        accumulator: inferenceAccumulator
                    )
                }
                return AttacheConversationReply(
                    text: text,
                    toolCallLost: toolCallLost,
                    inference: inferenceAccumulator.aggregate() ?? response.metadata
                )
            }

            payloadMessages = response.compiledMessages
            let assistantToolCall = AttacheChatMessage(
                role: "assistant",
                content: response.content,
                toolCalls: response.toolCalls
            )
            payloadMessages.append(assistantToolCall)
            payloadSources.append(AttachePrebuiltMessageSource(
                message: assistantToolCall,
                source: .recentDirectChatTurns
            ))
            for call in response.toolCalls {
                AttacheLog.presentation.info(
                    "conversation tool requested name=\(call.name, privacy: .public) argument_chars=\(call.arguments.count)"
                )
                try await Self.requireActiveConversation(requestIsActive)
                let result = await withTimeout(seconds: 10) {
                    await executeTool(call.name, call.arguments)
                } onTimeout: {
                    "The \(call.name) tool did not respond in time. Answer from what you already have and tell the user you could not check that in time."
                }
                try await Self.requireActiveConversation(requestIsActive)
                let toolResult = AttacheChatMessage(
                    role: "tool",
                    content: result,
                    toolCallID: call.id
                )
                payloadMessages.append(toolResult)
                let resultSource = Self.toolResultSource(for: call.name)
                payloadSources.append(AttachePrebuiltMessageSource(
                    message: toolResult,
                    source: resultSource,
                    authorization: resultSource.requiresFocusedSessionAuthorization
                        ? snapshot.session
                        : .contextFree
                ))
            }
        }

        let finalMessages = attempt.provider.isCLI
            ? AttacheProductionRequestBroker.removingCLIToolBridge(
                from: payloadMessages,
                toolDefinitionsJSON: attempt.toolDefinitionsJSON
            )
            : payloadMessages
        try await Self.requireActiveConversation(requestIsActive)
        let response = try await performConversationRound(
            snapshot: snapshot,
            attempt: finalAttempt,
            messages: finalMessages,
            messageSources: payloadSources,
            accumulator: inferenceAccumulator,
            attemptDidCompile: attemptDidCompile,
            requestIsActive: requestIsActive
        )
        try await Self.requireActiveConversation(requestIsActive)
        guard response.toolCalls.isEmpty else {
            throw Self.conversationFailure(
                AttachePresentationError.invalidResponse,
                accumulator: inferenceAccumulator
            )
        }
        let text = Self.sanitizeFollowUpAnswerOutput(response.content)
        guard !text.isEmpty else {
            throw Self.conversationFailure(
                AttachePresentationError.emptyResponse,
                accumulator: inferenceAccumulator
            )
        }
        return AttacheConversationReply(
            text: text,
            toolCallLost: toolCallLost,
            inference: inferenceAccumulator.aggregate() ?? response.metadata
        )
    }

    /// Bind provider-visible tool output to the authority of the tool that
    /// produced it. Session transcript and project-file evidence may never be
    /// relabeled as a generic context-free tool result in a later round.
    static func toolResultSource(for toolName: String) -> AttacheContextItemSource {
        switch toolName {
        case "read_session_transcript", "search_session_transcript":
            return .retrievedTranscriptEvidence
        case "list_working_directory", "read_file":
            return .retrievedFileEvidence
        default:
            return .toolResults
        }
    }

    private func performConversationRound(
        snapshot: AttacheRequestSnapshot,
        attempt: AttacheFrozenModelAttempt,
        messages: [AttacheChatMessage],
        messageSources: [AttachePrebuiltMessageSource],
        accumulator: AttacheInferenceAccumulator,
        attemptDidCompile: ((AttacheInferenceMetadata) async -> Void)?,
        requestIsActive: @escaping () async -> Bool
    ) async throws -> AttacheBrokerResponse {
        do {
            let response = try await requestBroker.perform(
                snapshot: snapshot,
                attempt: attempt,
                messages: messages,
                messageSources: messageSources,
                attemptDidCompile: { compiled in
                    guard let aggregate = accumulator.aggregate(appending: compiled) else { return }
                    await attemptDidCompile?(aggregate)
                },
                requestIsActive: requestIsActive
            )
            accumulator.record(response.metadata)
            return response
        } catch let failure as AttacheBrokerAttemptFailure {
            throw AttacheBrokerAttemptFailure(
                underlying: failure.underlying,
                inference: accumulator.aggregate(appending: failure.inference)
                    ?? failure.inference
            )
        } catch {
            throw Self.conversationFailure(error, accumulator: accumulator)
        }
    }

    private static func conversationFailure(
        _ error: Error,
        accumulator: AttacheInferenceAccumulator
    ) -> Error {
        guard let inference = accumulator.aggregate() else { return error }
        return AttacheBrokerAttemptFailure(underlying: error, inference: inference)
    }

    private static func requireActiveConversation(
        _ requestIsActive: () async -> Bool
    ) async throws {
        try Task.checkCancellation()
        guard await requestIsActive() else { throw CancellationError() }
        try Task.checkCancellation()
    }

    /// One-shot completion for recap, topic tagging, preview, or another
    /// explicitly frozen role. A missing model is a truthful no-model result,
    /// not a fabricated model receipt.
    func complete(
        snapshot: AttacheRequestSnapshot,
        system: String,
        user: String,
        settingsOverride: AttachePresentationSettings? = nil,
        systemSources: [AttacheContextItemSource]? = nil,
        userSources: [AttacheContextItemSource]? = nil,
        requestIsActive: (() async -> Bool)? = nil
    ) async throws -> AttacheCompletionResult {
        guard let attempt = frozenAttempt(snapshot: snapshot, settingsOverride: settingsOverride) else {
            return AttacheCompletionResult(text: nil, inference: .noModel(snapshot: snapshot))
        }
        let systemMessage = AttacheChatMessage(role: "system", content: system)
        let userMessage = AttacheChatMessage(role: "user", content: user)
        let messages = [systemMessage, userMessage]
        let messageSources: [AttachePrebuiltMessageSource]
        if systemSources != nil || userSources != nil {
            messageSources = (systemSources ?? []).map {
                AttachePrebuiltMessageSource(message: systemMessage, source: $0)
            } + (userSources ?? []).map {
                AttachePrebuiltMessageSource(message: userMessage, source: $0)
            }
        } else {
            messageSources = AttacheProductionRequestBroker.prebuiltMessageSources(
                snapshot: snapshot,
                messages: messages
            )
        }
        let response = try await requestBroker.perform(
            snapshot: snapshot,
            attempt: attempt,
            messages: messages,
            messageSources: messageSources,
            requestIsActive: requestIsActive
        )
        return AttacheCompletionResult(text: response.content, inference: response.metadata)
    }

    /// Whether the given role's LLM is configured enough to make background
    /// calls. Deliberately keychain-free: presence comes from the defaults
    /// flag, and the actual calls resolve and re-check before requesting.
    func isPresentationConfigured(for role: ModelRole) -> Bool {
        let unresolved = AttachePresentationSettings.load(role: role, defaults: defaults, environment: environment, resolveSecrets: false)
        return unresolved.llmEnabled && unresolved.hasProviderConfiguration
    }

    /// Resolve secrets, endpoint, model, reasoning, capability, and strategy
    /// synchronously. No `Task` is created until this immutable value exists.
    private func frozenAttempt(
        snapshot: AttacheRequestSnapshot,
        settingsOverride: AttachePresentationSettings? = nil,
        toolDefinitionsJSON: Data = Data()
    ) -> AttacheFrozenModelAttempt? {
        let settings: AttachePresentationSettings
        if let settingsOverride {
            guard settingsOverride.llmEnabled,
                  settingsOverride.hasProviderConfiguration,
                  settingsOverride.isConfigured else { return nil }
            settings = settingsOverride
        } else {
            guard let frozen = snapshot.modelSettings,
                  frozen.llmEnabled,
                  frozen.hasProviderConfiguration,
                  frozen.isConfigured else { return nil }
            settings = frozen
        }
        guard settings.provider.supportsSafePersonalityInference else {
            // Persisted/exported Codex CLI personalities remain decodable, but
            // cannot reach compilation or transport until the CLI can disable
            // its native file-reading tools.
            return nil
        }
        let consentScope = PresentationConsentScope(
            provider: settings.provider,
            endpoint: settings.baseURL.absoluteString
        )
        if consentScope.egress.isRemoteService {
            let consented = Set(
                defaults.array(forKey: AttachePreferenceKey.cloudConsentPresentationProviders)
                    as? [String] ?? []
            )
            guard consented.contains(consentScope.storageKey) else {
                // Fail closed before capability lookup, compiler work, CLI
                // launch, transport creation, or any other egress-capable step.
                return nil
            }
        }
        let evidence = AttachePresentationModelService.capabilityEvidence(
            provider: settings.provider,
            baseURLText: settings.baseURL.absoluteString,
            modelID: settings.model
        )
        return AttacheFrozenModelAttempt(
            role: snapshot.role,
            settings: settings,
            capability: evidence.profile,
            strategy: snapshot.contextStrategy,
            toolDefinitionsJSON: toolDefinitionsJSON,
            modelIdentity: evidence.identity
        )
    }

    private static func underlyingBrokerError(_ error: Error) -> Error {
        (error as? AttacheBrokerAttemptFailure)?.underlying ?? error
    }

    private static func failureInference(
        _ error: Error,
        snapshot: AttacheRequestSnapshot
    ) -> AttacheInferenceMetadata {
        (error as? AttacheBrokerAttemptFailure)?.inference ?? .noModel(snapshot: snapshot)
    }

    private static func modelRole(for role: AttacheRequestRole) -> ModelRole {
        switch role {
        case .recap:
            return .recap
        case .topicTagging:
            return .tagging
        case .conversation, .followUp, .liveFollowUp:
            return .conversation
        case .presentation, .anotherTake, .preview:
            return .presentation
        }
    }

    private static func toolNames(in definitions: Data) -> Set<String> {
        guard !definitions.isEmpty,
              let tools = try? JSONSerialization.jsonObject(with: definitions) as? [[String: Any]] else {
            return []
        }
        return Set(tools.compactMap { tool in
            (tool["function"] as? [String: Any])?["name"] as? String
        })
    }

    static func conversationTools(
        allowSessionContextTools: Bool,
        allowAgentInstructionTool: Bool,
        allowMemoryProposalTool: Bool = false,
        allowSessionDiscoveryTool: Bool = false,
        allowExhaustiveReviewTool: Bool = false
    ) -> [[String: Any]] {
        AttacheProductionRequestBroker.conversationToolObjects(
            allowSessionContextTools: allowSessionContextTools,
            allowAgentInstructionTool: allowAgentInstructionTool,
            allowMemoryProposalTool: allowMemoryProposalTool,
            allowSessionDiscoveryTool: allowSessionDiscoveryTool,
            allowExhaustiveReviewTool: allowExhaustiveReviewTool
        )
    }

    struct CLIToolCallDirective: Equatable {
        var name: String
        var arguments: String
    }

    static func cliToolBridgeMessage(tools: [[String: Any]]) -> AttacheChatMessage {
        let data = (try? JSONSerialization.data(
            withJSONObject: tools,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("[]".utf8)
        return AttacheProductionRequestBroker.cliToolBridgeMessage(toolDefinitionsJSON: data)
            ?? AttacheChatMessage(role: "system", content: "Attaché tool bridge: no tools are available.")
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
        if trimmed.contains("companion_tool_call") { return true }
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
        if let call = object["companion_tool_call"] as? [String: Any],
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

    private static func preparedResult(
        event: NormalizedEvent,
        inference: AttacheInferenceMetadata
    ) -> AttachePreparedEventResult {
        var persisted = event
        if let receipt = inference.receiptView.encodedMetadataValue() {
            persisted.metadata[AttacheContextReceiptView.metadataKey] = receipt
        }
        return AttachePreparedEventResult(event: persisted, inference: inference)
    }

    private static func eventWithLLMPresentation(
        _ event: NormalizedEvent,
        prompt: AttachePresentationPrompt,
        response brokerResponse: AttacheBrokerResponse,
        attempt: AttacheFrozenModelAttempt,
        snapshot: AttacheRequestSnapshot
    ) throws -> NormalizedEvent {
        let response = splitCardSummary(brokerResponse.content)

        guard !response.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AttachePresentationError.emptyResponse
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
        // Metadata keys remain backward compatible, but new strategy values use
        // the current product vocabulary.
        presented.metadata["companion_presentation_strategy"] = "attache-personality-llm"
        presented.metadata["companion_llm_provider"] = attempt.provider.rawValue
        presented.metadata["companion_llm_model"] = attempt.model
        presented.metadata["companion_llm_base_url"] = attempt.endpoint.absoluteString
        presented.metadata["companion_personality_id"] = snapshot.personality.id
        presented.metadata["companion_personality_name"] = snapshot.personality.name
        presented.metadata["companion_personality_profile"] = snapshot.personality.id
        presented.metadata["companion_memory_context_chars"] = String(
            snapshot.contextItems
                .filter { $0.source == .durableMemory }
                .reduce(0) { $0 + $1.content.count }
        )
        presented.metadata["companion_raw_output_chars"] = String(prompt.rawOutputCharacterCount)
        presented.metadata["companion_raw_output_truncated"] = prompt.truncatedRawOutput ? "true" : "false"
        if let receipt = brokerResponse.metadata.receiptView.encodedMetadataValue() {
            presented.metadata[AttacheContextReceiptView.metadataKey] = receipt
        }
        if let reasoningEffort = attempt.reasoningEffort, !reasoningEffort.isEmpty {
            presented.metadata["companion_llm_reasoning_effort"] = reasoningEffort
        }
        return presented
    }

    /// Produce an "another take" of an existing card in a target personality's
    /// voice (INF-299): a brief nod to the personality that narrated it, then the
    /// target's own spin. Runs T5's pure prompt through the same model path as
    /// the normal presentation, and hands back a presented event the caller files
    /// as a new card linked to the original. Completes with nil when no
    /// presentation model is configured or the model call fails.
    func prepareAnotherTake(
        original: VoicemailCard,
        sourceText: String? = nil,
        targetPersonality: Personality,
        priorPersonalityName: String,
        authorization: AnotherTakeRequestAuthorization,
        snapshot: AttacheRequestSnapshot,
        completion: @escaping (AttachePreparedEventResult?) -> Void
    ) {
        precondition(snapshot.role == .anotherTake)
        // Another Take is explicit, card-scoped authorization. A watched or
        // merely recent card must never reach the model through personality
        // selection alone (INF-336).
        guard authorization.authorizes(original),
              snapshot.personality.id == targetPersonality.id,
              let attempt = frozenAttempt(snapshot: snapshot) else {
            completion(nil)
            return
        }
        let prompt = AttachePersonality.anotherTakePrompt(
            sourceText: sourceText ?? original.rawText,
            priorTake: original.spokenText,
            priorPersonalityName: priorPersonalityName,
            targetProfilePrompt: snapshot.profilePrompt,
            memoryContext: nil,
            spokenLanguageName: Self.spokenLanguageName(defaults: defaults)
        )

        Task {
            do {
                let response = try await requestBroker.perform(
                    snapshot: snapshot,
                    attempt: attempt,
                    messages: prompt.messages,
                    messageSources: AttacheProductionRequestBroker.prebuiltMessageSources(
                        snapshot: snapshot,
                        messages: prompt.messages
                    )
                )
                let parsed = Self.splitCardSummary(response.content)
                guard !parsed.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AttachePresentationError.emptyResponse
                }
                var presented = Self.anotherTakeEvent(
                    from: original,
                    targetPersonality: targetPersonality,
                    summary: parsed.summary,
                    spoken: parsed.spokenText,
                    needsDecision: parsed.needsDecision
                )
                if let receipt = response.metadata.receiptView.encodedMetadataValue() {
                    presented.metadata[AttacheContextReceiptView.metadataKey] = receipt
                }
                let result = Self.preparedResult(event: presented, inference: response.metadata)
                await MainActor.run { completion(result) }
            } catch {
                await MainActor.run { completion(nil) }
            }
        }
    }

    /// Build the presented event for an "another take": it carries the target
    /// personality's summary and spoken text, records the target as the producing
    /// personality, and links back to the original card via `attache_take_of`.
    /// Pure, so the linkage is unit-testable without a model.
    static func anotherTakeEvent(
        from original: VoicemailCard,
        targetPersonality: Personality,
        summary: String,
        spoken: String,
        needsDecision: Bool
    ) -> NormalizedEvent {
        var metadata: [String: String] = [:]
        metadata["companion_summary"] = summary
        metadata["companion_spoken_text"] = spoken
        if needsDecision { metadata["companion_needs_decision"] = "1" }
        metadata["companion_presentation_strategy"] = "another-take"
        metadata["companion_personality_id"] = targetPersonality.id
        metadata["companion_personality_name"] = targetPersonality.name
        metadata["companion_take_of"] = original.id
        for key in [
            "companion_conversation_id",
            "companion_conversation_user_turn",
            "companion_conversation_context_v1"
        ] {
            if let value = original.metadataObject[key] as? String {
                metadata[key] = value
            }
        }
        return NormalizedEvent(
            source: original.sourceKind,
            eventType: "assistant.completed",
            externalSessionID: original.externalSessionID,
            projectPath: original.projectPath,
            title: original.sessionTitle ?? original.summary,
            text: original.rawText,
            metadata: metadata
        )
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
        return (AttachePersonality.stripDashes(summary), AttachePersonality.stripDashes(spokenText), needsDecision)
    }

    private static func fallbackFollowUpAnswer(
        card: VoicemailCard,
        danQuestion: String,
        inference: AttacheInferenceMetadata
    ) -> AttacheFollowUpAnswerResult {
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
        return AttacheFollowUpAnswerResult(
            answerText: answer.trimmingCharacters(in: .whitespacesAndNewlines),
            strategy: "deterministic-follow-up-fallback",
            model: nil,
            rawContextCharacterCount: card.rawText.count,
            truncatedContext: false,
            errorDescription: nil,
            inference: inference
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
        return AttachePersonality.stripDashes(cleaned)
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
        guard let id = defaults.string(forKey: AttachePreferenceKey.spokenLanguage),
              id != "en" else { return nil }
        return AttacheCaptionLanguage.named(id).name
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
    /// (not private) so `Tests/AttacheAppTests/AttachePresentationServiceTests.swift`
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

    /// `none` is a real model-level choice for xAI, Ollama, and supported
    /// OpenAI-compatible reasoning models. Other providers historically used
    /// `none` as Attaché's internal "omit this field" sentinel.
    static func reasoningEffortPayloadValue(
        _ value: String?,
        provider: AttachePresentationProvider
    ) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if trimmed == "none" {
            switch provider {
            case .xai, .ollama, .custom:
                return "none"
            case .groq, .claudeCLI, .codexCLI:
                return nil
            }
        }
        return normalizedReasoningEffort(value)
    }
}

struct AttachePreparedEventResult: Equatable {
    var event: NormalizedEvent
    var inference: AttacheInferenceMetadata
}

struct AttacheCompletionResult: Equatable {
    var text: String?
    var inference: AttacheInferenceMetadata
}

struct AttacheFollowUpAnswerResult: Equatable {
    var answerText: String
    var strategy: String
    var model: String?
    var rawContextCharacterCount: Int
    var truncatedContext: Bool
    var errorDescription: String?
    var inference: AttacheInferenceMetadata
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
struct AttacheConversationReply: Equatable {
    var text: String
    var toolCallLost: Bool = false
    var inference: AttacheInferenceMetadata
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

struct AttachePresentationSettings: Equatable {
    var llmEnabled: Bool
    var provider: AttachePresentationProvider
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
    ) -> AttachePresentationSettings {
        // Personality presentation is now the only product mode. Keep reading
        // the legacy key nowhere: a stored `false` from an older release must
        // not quietly bring back the retired verbatim-readback preference.
        let llmEnabled = true

        let explicitProviderText = firstNonEmpty(
            environment["ATTACHE_LLM_PROVIDER"],
            environment["COMPANION_LLM_PROVIDER"],
            defaults.string(forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .provider)),
            defaults.string(forKey: AttachePreferenceKey.presentationLLMProvider),
            ""
        )
        let configuredBaseURLText = firstNonEmpty(
            environment["ATTACHE_LLM_BASE_URL"],
            environment["COMPANION_LLM_BASE_URL"],
            defaults.string(forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .baseURL)),
            defaults.string(forKey: AttachePreferenceKey.presentationLLMBaseURL),
            ""
        )
        let legacyLMStudio = AttachePresentationProvider.isLegacyLMStudio(
            explicitValue: explicitProviderText,
            baseURLText: configuredBaseURLText
        )
        let provider = AttachePresentationProvider.from(
            explicitValue: explicitProviderText,
            baseURLText: configuredBaseURLText
        )
        let baseURLText = legacyLMStudio
            ? AttachePresentationProvider.ollama.defaultBaseURL
            : firstNonEmpty(configuredBaseURLText, provider.defaultBaseURL)
        let baseURL = URL(string: baseURLText) ?? URL(string: AttachePresentationProvider.ollama.defaultBaseURL)!
        let apiKeySecretRef = firstNonEmpty(
            environment["ATTACHE_LLM_API_KEY_SECRET_REF"],
            environment["COMPANION_LLM_API_KEY_SECRET_REF"],
            defaults.string(forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .apiKeySecretRef)),
            defaults.string(forKey: AttachePreferenceKey.presentationLLMAPIKeySecretRef),
            ""
        )
        // The keychain is only touched when secrets are actually being
        // resolved; unresolved loads run on the launch path and must never
        // block on a SecurityAgent authorization.
        let secretAccountFlagged = ((defaults.array(forKey: AttachePreferenceKey.configuredSecretAccounts) as? [String]) ?? [])
            .contains(provider.developmentSecretAccount)
        var apiKey = firstNonEmpty(
            environment["ATTACHE_LLM_API_KEY"],
            environment["COMPANION_LLM_API_KEY"],
            resolveSecrets ? configuredSecret(defaults: defaults, account: provider.developmentSecretAccount) : nil,
            defaults.string(forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .apiKey)),
            defaults.string(forKey: AttachePreferenceKey.presentationLLMAPIKey),
            ""
        )
        if resolveSecrets, apiKey.isEmpty, !apiKeySecretRef.isEmpty {
            apiKey = AttacheSecretStore.readSecret(reference: apiKeySecretRef) ?? ""
        }
        let model = legacyLMStudio
            ? AttachePresentationProvider.ollama.defaultModel
            : firstNonEmpty(
                environment["ATTACHE_LLM_MODEL"],
                environment["COMPANION_LLM_MODEL"],
                defaults.string(forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .model)),
                defaults.string(forKey: AttachePreferenceKey.presentationLLMModel),
                provider.defaultModel
            )
        let configuredReasoningEffort = firstNonEmpty(
            environment["ATTACHE_REASONING_EFFORT"],
            environment["COMPANION_REASONING_EFFORT"],
            defaults.string(forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .reasoningEffort)),
            defaults.string(forKey: AttachePreferenceKey.presentationReasoningEffort),
            provider.defaultReasoningEffort
        )
        let reasoningEffort = provider.supportsReasoningEffort ? configuredReasoningEffort : "none"
        let serviceTier = provider.supportsServiceTier
            ? firstNonEmpty(
                environment["ATTACHE_SERVICE_TIER"],
                defaults.string(forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .serviceTier)),
                defaults.string(forKey: AttachePreferenceKey.presentationServiceTier),
                provider.defaultServiceTier
            )
            : nil
        let profilePrompt = firstNonEmpty(
            environment["ATTACHE_PERSONALITY_PROMPT"],
            environment["ATTACHE_PROFILE_PROMPT"],
            environment["COMPANION_PERSONALITY_PROMPT"],
            defaults.string(forKey: AttachePreferenceKey.personalityPrompt),
            ""
        )
        return AttachePresentationSettings(
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
        provider: AttachePresentationProvider,
        baseURLText: String,
        apiKey: String,
        profilePrompt: String
    ) -> AttachePresentationSettings {
        let baseURLText = firstNonEmpty(baseURLText, provider.defaultBaseURL)
        let baseURL = URL(string: baseURLText) ?? URL(string: AttachePresentationProvider.ollama.defaultBaseURL)!
        return AttachePresentationSettings(
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
        let accounts = defaults.array(forKey: AttachePreferenceKey.configuredSecretAccounts) as? [String] ?? []
        guard accounts.contains(account) else { return nil }
        return AttacheSecretVault.read(account: account)
    }
}

// Not private: AppModel inspects `httpStatus` / `urlErrorCode` to classify
// conversation failures structurally (see ConversationRecovery.classify).
enum AttachePresentationError: LocalizedError {
    case emptyResponse
    case invalidResponse
    case unauthorizedContext
    case httpStatus(Int, String)
    case notConfigured
    case transport(URLError)

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "LLM response was empty."
        case .invalidResponse:
            return "LLM response was not HTTP."
        case .unauthorizedContext:
            return "The focused session authorization changed. Focus the session and try again."
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

    /// Unmodified provider response body for structural safety classification.
    /// It is never logged or persisted; callers use it only to distinguish
    /// context-window and authentication failures from retryable transport
    /// failures (INF-337).
    var responseBody: String? {
        if case .httpStatus(_, let body) = self { return body }
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
