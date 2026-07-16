import AttacheCore
import Foundation

/// Provider requests are authorized for one exact frozen endpoint. Following
/// an HTTP redirect would silently create a second destination that never went
/// through that consent check, and 307/308 can forward the full POST body.
/// Returning nil exposes the redirect response to the broker without issuing
/// the redirected request.
final class AttacheNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    static func redirectedRequest(_ request: URLRequest) -> URLRequest? {
        // Exact-endpoint consent never authorizes a second URL, even on the
        // same host. The user can configure and consent to that endpoint
        // explicitly instead.
        nil
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.redirectedRequest(request))
    }
}

/// Everything about one provider attempt that must stop changing before async
/// work starts (INF-338). The broker never consults defaults, model discovery,
/// the active personality, or live focus after this value is created.
struct AttacheFrozenModelAttempt: Equatable {
    let role: AttacheRequestRole
    let provider: AttachePresentationProvider
    let endpoint: URL
    let apiKey: String
    let modelIdentity: ModelIdentity
    let model: String
    let reasoningEffort: String?
    let serviceTier: String?
    let capability: AttacheModelCapabilityProfile
    let strategy: AttacheContextStrategy
    let toolDefinitionsJSON: Data

    var hasTools: Bool { !toolDefinitionsJSON.isEmpty }

    init(
        role: AttacheRequestRole,
        settings: AttachePresentationSettings,
        capability: AttacheModelCapabilityProfile,
        strategy: AttacheContextStrategy,
        toolDefinitionsJSON: Data = Data(),
        modelIdentity: ModelIdentity? = nil
    ) {
        self.role = role
        provider = settings.provider
        endpoint = settings.baseURL
        apiKey = settings.apiKey
        model = settings.model
        reasoningEffort = settings.reasoningEffort
        serviceTier = settings.serviceTier
        self.capability = capability
        self.strategy = strategy
        self.toolDefinitionsJSON = toolDefinitionsJSON
        self.modelIdentity = modelIdentity ?? ModelIdentity(
            provider: settings.provider.rawValue,
            normalizedEndpoint: settings.provider.isCLI ? "" : settings.baseURL.absoluteString,
            requestedModel: settings.model
        )
    }

    /// A second immutable attempt for the post-tool final-answer round. It is
    /// derived synchronously from the already frozen attempt and differs only
    /// in that no tool schemas are provider-visible.
    func withoutTools() -> AttacheFrozenModelAttempt {
        AttacheFrozenModelAttempt(
            role: role,
            settings: AttachePresentationSettings(
                llmEnabled: true,
                provider: provider,
                baseURL: endpoint,
                apiKey: apiKey,
                apiKeySecretRef: "",
                model: model,
                reasoningEffort: reasoningEffort,
                serviceTier: serviceTier,
                profilePrompt: ""
            ),
            capability: capability,
            strategy: strategy,
            modelIdentity: modelIdentity
        )
    }
}

/// Content-free metadata returned with every service result. Model-backed
/// responses carry the exact compiler receipt that reached the transport and
/// provider-reported token usage. Plain or unavailable-model paths carry a
/// truthful no-model receipt and no fabricated usage (INF-338).
struct AttacheInferenceMetadata: Equatable {
    let requestID: String
    let contextReceipt: ContextReceipt?
    let receiptView: AttacheContextReceiptView
    let usage: AttacheParsedTokenUsage
    let modelIdentity: ModelIdentity?
    /// True when any provider-visible input to this answer was restricted to
    /// this Mac. The output inherits that restriction because it may quote or
    /// paraphrase the private source even though the receipt is content-free.
    let containsLocalOnlyContext: Bool

    static func noModel(snapshot: AttacheRequestSnapshot) -> AttacheInferenceMetadata {
        AttacheInferenceMetadata(
            requestID: snapshot.requestID,
            contextReceipt: nil,
            receiptView: AttacheContextReceiptBuilder.buildNoModel(cardID: snapshot.requestID),
            usage: AttacheParsedTokenUsage(
                inputTokens: nil,
                outputTokens: nil,
                cachedTokens: nil,
                totalTokens: nil
            ),
            modelIdentity: nil,
            containsLocalOnlyContext: false
        )
    }

    static func model(
        snapshot: AttacheRequestSnapshot,
        compiled: CompiledModelRequest,
        usage: AttacheParsedTokenUsage,
        attempt: AttacheFrozenModelAttempt
    ) -> AttacheInferenceMetadata {
        AttacheInferenceMetadata(
            requestID: snapshot.requestID,
            contextReceipt: compiled.receipt,
            receiptView: AttacheContextReceiptBuilder.build(
                cardID: snapshot.requestID,
                primaryCompiled: compiled,
                authorizationTime: snapshot.capturedAt,
                reasoningLevel: attempt.reasoningEffort,
                capabilityProvenance: attempt.capability.provenance.rawValue,
                capabilityFreshness: attempt.capability.freshness,
                focusedSession: snapshot.focusedSession,
                memorySelectionReceipt: memoryReceipt(
                    snapshot: snapshot,
                    compiled: compiled,
                    attempt: attempt
                )
            ),
            usage: usage,
            modelIdentity: compiled.modelIdentity,
            containsLocalOnlyContext: Self.compiledIncludedLocalOnlyContext(
                snapshot: snapshot,
                compiled: compiled
            )
        )
    }

    /// Preserve both sides of an AppModel-managed provider fallback. Every
    /// fallback round's own compiler receipt is relabeled in order;
    /// the failed primary remains attempt 1, so persisted cards truthfully show
    /// every destination that received context.
    func recordingFallback(after primary: AttacheInferenceMetadata) -> AttacheInferenceMetadata {
        guard !receiptView.attempts.isEmpty,
              !primary.receiptView.attempts.isEmpty else { return self }
        var nextAttemptNumber = (primary.receiptView.attempts.map(\.attemptNumber).max() ?? 0) + 1
        let fallbackAttempts = receiptView.attempts.map { successfulAttempt in
            defer { nextAttemptNumber += 1 }
            return AttacheReceiptAttemptSummary(
                attemptNumber: nextAttemptNumber,
                isFallback: true,
                modelSummary: successfulAttempt.modelSummary,
                sourceSummaries: successfulAttempt.sourceSummaries,
                totalEstimatedTokens: successfulAttempt.totalEstimatedTokens,
                stagedProcessingRequired: successfulAttempt.stagedProcessingRequired,
                focusedSessionDisplay: successfulAttempt.focusedSessionDisplay,
                recompiledForFallback: true
            )
        }
        func sum(_ first: Int?, _ second: Int?) -> Int? {
            let values = [first, second].compactMap { $0 }
            return values.isEmpty ? nil : values.reduce(0, +)
        }
        return AttacheInferenceMetadata(
            requestID: requestID,
            contextReceipt: contextReceipt,
            receiptView: AttacheContextReceiptView(
                cardID: receiptView.cardID,
                attempts: primary.receiptView.attempts + fallbackAttempts
            ),
            usage: AttacheParsedTokenUsage(
                inputTokens: sum(primary.usage.inputTokens, usage.inputTokens),
                outputTokens: sum(primary.usage.outputTokens, usage.outputTokens),
                cachedTokens: sum(primary.usage.cachedTokens, usage.cachedTokens),
                totalTokens: sum(primary.usage.totalTokens, usage.totalTokens)
            ),
            modelIdentity: modelIdentity,
            containsLocalOnlyContext: containsLocalOnlyContext
        )
    }

    /// Aggregate the content-free receipts and provider usage for a response
    /// assembled from several real model calls, such as tool rounds or staged
    /// exhaustive review. Every compiled egress remains visible on the final
    /// card rather than only the last round.
    static func aggregating(
        _ inferences: [AttacheInferenceMetadata],
        requestID: String
    ) -> AttacheInferenceMetadata? {
        guard !inferences.isEmpty else { return nil }
        var nextAttempt = 1
        var attempts: [AttacheReceiptAttemptSummary] = []
        for inference in inferences {
            for attempt in inference.receiptView.attempts {
                attempts.append(AttacheReceiptAttemptSummary(
                    attemptNumber: nextAttempt,
                    isFallback: attempt.isFallback,
                    modelSummary: attempt.modelSummary,
                    sourceSummaries: attempt.sourceSummaries,
                    totalEstimatedTokens: attempt.totalEstimatedTokens,
                    stagedProcessingRequired: attempt.stagedProcessingRequired,
                    focusedSessionDisplay: attempt.focusedSessionDisplay,
                    recompiledForFallback: attempt.recompiledForFallback
                ))
                nextAttempt += 1
            }
        }
        func sum(_ values: [Int?]) -> Int? {
            let present = values.compactMap { $0 }
            return present.isEmpty ? nil : present.reduce(0, +)
        }
        let identities = Set(inferences.compactMap(\.modelIdentity))
        return AttacheInferenceMetadata(
            requestID: requestID,
            contextReceipt: nil,
            receiptView: AttacheContextReceiptView(
                cardID: requestID,
                attempts: attempts,
                noModelContext: attempts.isEmpty
                    && inferences.allSatisfy(\.receiptView.noModelContext)
            ),
            usage: AttacheParsedTokenUsage(
                inputTokens: sum(inferences.map(\.usage.inputTokens)),
                outputTokens: sum(inferences.map(\.usage.outputTokens)),
                cachedTokens: sum(inferences.map(\.usage.cachedTokens)),
                totalTokens: sum(inferences.map(\.usage.totalTokens))
            ),
            modelIdentity: identities.count == 1 ? identities.first : nil,
            containsLocalOnlyContext: inferences.contains(where: \.containsLocalOnlyContext)
        )
    }

    private static func compiledIncludedLocalOnlyContext(
        snapshot: AttacheRequestSnapshot,
        compiled: CompiledModelRequest
    ) -> Bool {
        let included = Set(compiled.receipt.includedSourceIdentifiers ?? [])
        return snapshot.contextItems.contains { item in
            guard item.egress == .localOnly else { return false }
            let identifier: String
            if item.source == .durableMemory,
               let provenance = item.provenance,
               provenance.hasPrefix("memory:") {
                identifier = provenance
            } else {
                identifier = item.source.rawValue
            }
            return included.contains(identifier)
        }
    }

    private static func memoryReceipt(
        snapshot: AttacheRequestSnapshot,
        compiled: CompiledModelRequest,
        attempt: AttacheFrozenModelAttempt
    ) -> [AttacheMemoryReceiptEntry] {
        let omitted = Set(compiled.receipt.omittedSourceIdentifiers ?? [])
        guard !omitted.isEmpty else { return snapshot.memorySelectionReceipt }
        let localOnlyIDs = Set(snapshot.contextItems.compactMap { item -> String? in
            guard item.source == .durableMemory,
                  item.egress == .localOnly,
                  let provenance = item.provenance,
                  provenance.hasPrefix("memory:") else { return nil }
            return String(provenance.dropFirst("memory:".count))
        })
        let remoteAttempt = attempt.provider
            .dataEgress(endpoint: attempt.endpoint.absoluteString)
            .isRemote
        return snapshot.memorySelectionReceipt.map { entry in
            guard entry.disposition == .included,
                  omitted.contains("memory:\(entry.memoryID)") else { return entry }
            return AttacheMemoryReceiptEntry(
                memoryID: entry.memoryID,
                disposition: .omitted,
                omissionReason: remoteAttempt && localOnlyIDs.contains(entry.memoryID)
                    ? "local-only-egress"
                    : "context-budget"
            )
        }
    }
}

struct AttacheBrokerResponse: Equatable {
    let content: String
    let toolCalls: [AttacheChatToolCall]
    /// The exact compiler output used by this round. Multi-round callers must
    /// continue from these messages rather than their pre-compile input so
    /// truncation, omission markers, and protected-context decisions persist.
    let compiledMessages: [AttacheChatMessage]
    let metadata: AttacheInferenceMetadata
    /// True only when a CLI reply looked like a malformed tool request and a
    /// separately compiled corrective round also failed to recover it.
    var toolCallLost: Bool = false
}

enum AttacheProductionBrokerError: Error, Equatable {
    case roleMismatch(snapshot: AttacheRequestRole, attempt: AttacheRequestRole)
    case modelIdentityMismatch
    case invalidToolDefinitions
    case invalidOutboundRequest
}

/// A provider attempt that compiled successfully and reached the transport
/// boundary, but failed before a usable response arrived. Keeping the actual
/// compiler receipt on the error distinguishes attempted model egress from a
/// request that never had a configured model at all.
struct AttacheBrokerAttemptFailure: LocalizedError {
    let underlying: Error
    let inference: AttacheInferenceMetadata

    var errorDescription: String? { underlying.localizedDescription }
}

/// The only production egress point for personality-model inference
/// (INF-338). Callers provide an immutable request snapshot and a synchronously
/// frozen attempt. Every round compiles through `ContextCompiler`; the private
/// transport accepts only that compiled request plus the frozen attempt.
final class AttacheProductionRequestBroker {
    private let urlSession: URLSession
    private let estimator: AttacheFallbackTokenEstimator
    private let calibrationStore: AttacheCalibrationStore?

    init(
        urlSession: URLSession = .shared,
        estimator: AttacheFallbackTokenEstimator = AttacheFallbackTokenEstimator(),
        calibrationStore: AttacheCalibrationStore? = AttacheProductionRequestBroker.defaultCalibrationStore()
    ) {
        self.urlSession = urlSession
        self.estimator = estimator
        self.calibrationStore = calibrationStore
    }

    func perform(
        snapshot: AttacheRequestSnapshot,
        attempt: AttacheFrozenModelAttempt,
        messages: [AttacheChatMessage],
        messageSources: [AttachePrebuiltMessageSource]? = nil,
        attemptDidCompile: ((AttacheInferenceMetadata) async -> Void)? = nil,
        requestIsActive: (() async -> Bool)? = nil
    ) async throws -> AttacheBrokerResponse {
        let compiled = try compile(
            snapshot: snapshot,
            attempt: attempt,
            messages: messages,
            messageSources: messageSources
        )
        let compiledInference = AttacheInferenceMetadata.model(
            snapshot: snapshot,
            compiled: compiled,
            usage: AttacheParsedTokenUsage(
                inputTokens: nil,
                outputTokens: nil,
                cachedTokens: nil,
                totalTokens: nil
            ),
            attempt: attempt
        )
        await attemptDidCompile?(compiledInference)
        let transported: TransportResult
        do {
            transported = try await transport(
                compiled: compiled,
                attempt: attempt,
                requestIsActive: requestIsActive
            )
        } catch {
            throw AttacheBrokerAttemptFailure(
                underlying: error,
                inference: compiledInference
            )
        }
        recordCalibration(
            usage: transported.usage,
            compiled: transported.compiled,
            attempt: attempt,
            receiptID: snapshot.requestID
        )
        return AttacheBrokerResponse(
            content: transported.content,
            toolCalls: transported.toolCalls,
            compiledMessages: transported.compiled.messages,
            metadata: .model(
                snapshot: snapshot,
                compiled: transported.compiled,
                usage: transported.usage,
                attempt: attempt
            )
        )
    }

    /// Internal for focused tests. Production callers should use `perform`, so
    /// compilation and transport cannot drift into separate code paths.
    func compile(
        snapshot: AttacheRequestSnapshot,
        attempt: AttacheFrozenModelAttempt,
        messages: [AttacheChatMessage],
        messageSources: [AttachePrebuiltMessageSource]? = nil
    ) throws -> CompiledModelRequest {
        guard snapshot.role == attempt.role else {
            throw AttacheProductionBrokerError.roleMismatch(
                snapshot: snapshot.role,
                attempt: attempt.role
            )
        }
        if !snapshot.session.isFocused,
           Self.toolDefinitionsRequireFocusedSession(attempt.toolDefinitionsJSON) {
            throw AttacheProductionBrokerError.invalidToolDefinitions
        }

        var prebuiltMessages = messages
        var prebuiltMessageSources = messageSources
            ?? Self.prebuiltMessageSources(snapshot: snapshot, messages: messages)
        if attempt.provider.isCLI,
           let bridge = Self.cliToolBridgeMessage(toolDefinitionsJSON: attempt.toolDefinitionsJSON) {
            if !prebuiltMessages.contains(bridge) {
                prebuiltMessages.insert(bridge, at: 0)
            }
            let descriptor = AttachePrebuiltMessageSource(message: bridge, source: .toolDefinitions)
            if !prebuiltMessageSources.contains(descriptor) {
                prebuiltMessageSources.append(descriptor)
            }
        }

        let toolDefinitions: String
        let wrapper: String
        if attempt.provider.isCLI {
            // The exact schema is embedded in the bridge message above and is
            // therefore part of the protected serialized messages. This is the
            // fixed wrapper CLILanguageModel adds around those messages.
            toolDefinitions = ""
            wrapper = "User: \n\nRespond as the assistant with your reply only."
        } else {
            toolDefinitions = String(decoding: attempt.toolDefinitionsJSON, as: UTF8.self)
            wrapper = try Self.httpPayloadTemplate(attempt: attempt)
        }

        let input = ContextCompilerInput(
            userInput: snapshot.userInput,
            modelIdentity: attempt.modelIdentity,
            role: snapshot.role,
            profilePrompt: snapshot.profilePrompt,
            memoryContext: nil,
            session: snapshot.session,
            requestIsRemote: attempt.provider
                .dataEgress(endpoint: attempt.endpoint.absoluteString)
                .isRemote,
            prebuiltMessages: prebuiltMessages,
            prebuiltMessageSources: prebuiltMessageSources,
            serializedToolDefinitions: toolDefinitions,
            serializedBridgeWrapper: wrapper
        )
        let requestEstimator = estimatorForRequest(attempt)
        let compiled = try ContextCompiler.compile(
            input: input,
            items: snapshot.contextItems,
            capability: Self.compilationCapability(
                attempt.capability,
                modelIdentity: attempt.modelIdentity,
                strategy: attempt.strategy
            ),
            strategy: attempt.strategy,
            estimator: requestEstimator
        )
        if attempt.provider.isCLI {
            return try finalizedCLIRequest(
                compiled,
                snapshot: snapshot,
                estimator: requestEstimator
            )
        }
        return compiled
    }

    /// Provider aliases and local runtime settings can change underneath a
    /// persisted capability record. After seven days, non-Custom strategies
    /// use the compiler's unknown-capacity envelope until discovery refreshes
    /// the exact endpoint and model identity. Custom remains explicit user
    /// policy and is still bounded by any lower known provider ceiling.
    static func compilationCapability(
        _ capability: AttacheModelCapabilityProfile,
        modelIdentity: ModelIdentity,
        strategy: AttacheContextStrategy,
        now: Date = Date()
    ) -> AttacheModelCapabilityProfile {
        guard strategy.kind != .custom,
              capability.isStale(olderThan: 7 * 86_400, now: now) else {
            return capability
        }
        // An Ollama digest identifies immutable model bytes at one exact
        // endpoint. Retain its last-known ceiling while offline and show the
        // stale evidence in UI. Mutable aliases and unversioned endpoints keep
        // the conservative unknown envelope until refreshed.
        if modelIdentity.provider == AttachePresentationProvider.ollama.rawValue,
           modelIdentity.fingerprint != nil {
            return capability
        }
        return .unknown
    }

    // MARK: Frozen tool definitions

    static func conversationToolDefinitions(
        allowSessionContextTools: Bool,
        allowAgentInstructionTool: Bool,
        allowMemoryProposalTool: Bool,
        allowSessionDiscoveryTool: Bool = false,
        allowExhaustiveReviewTool: Bool = false
    ) throws -> Data {
        var tools: [[String: Any]] = []
        if allowSessionDiscoveryTool {
            tools.append(sessionDiscoveryToolObject())
        }
        if allowSessionContextTools {
            tools.append(contentsOf: sessionContextToolObjects())
            if allowAgentInstructionTool {
                tools.append(agentInstructionToolObject())
            }
            if allowExhaustiveReviewTool {
                tools.append(exhaustiveReviewToolObject())
            }
        }
        if allowMemoryProposalTool {
            tools.append(memoryProposalToolObject())
        }
        guard !tools.isEmpty else { return Data() }
        guard JSONSerialization.isValidJSONObject(tools) else {
            throw AttacheProductionBrokerError.invalidToolDefinitions
        }
        return try JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func conversationToolObjects(
        allowSessionContextTools: Bool,
        allowAgentInstructionTool: Bool,
        allowMemoryProposalTool: Bool = false,
        allowSessionDiscoveryTool: Bool = false,
        allowExhaustiveReviewTool: Bool = false
    ) -> [[String: Any]] {
        let data = try? conversationToolDefinitions(
            allowSessionContextTools: allowSessionContextTools,
            allowAgentInstructionTool: allowAgentInstructionTool,
            allowMemoryProposalTool: allowMemoryProposalTool,
            allowSessionDiscoveryTool: allowSessionDiscoveryTool,
            allowExhaustiveReviewTool: allowExhaustiveReviewTool
        )
        guard let data, !data.isEmpty,
              let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return objects
    }

    static func cliToolBridgeMessage(toolDefinitionsJSON: Data) -> AttacheChatMessage? {
        guard !toolDefinitionsJSON.isEmpty else { return nil }
        let schemas = String(decoding: toolDefinitionsJSON, as: UTF8.self)
        return AttacheChatMessage(role: "system", content: """
        Attaché tool bridge:
        You have access only to the Attaché app tools in the exact JSON schemas below. The CLI's native tools are disabled.
        <attache-tool-schemas>
        \(schemas)
        </attache-tool-schemas>

        To propose a tool call, reply with exactly one JSON object and no prose:
        {"companion_tool_call":{"name":"tool_name","arguments":{}}}

        Use one tool call at a time. Attaché validates authorization and local policy. A model proposal never authorizes a memory write or an agent send.
        """)
    }

    /// Remove only the exact bridge that this frozen attempt inserted. Tool
    /// call and tool-result messages remain structured for the final forced
    /// answer, while the no-tools round no longer advertises unavailable tools.
    static func removingCLIToolBridge(
        from messages: [AttacheChatMessage],
        toolDefinitionsJSON: Data
    ) -> [AttacheChatMessage] {
        guard let bridge = cliToolBridgeMessage(toolDefinitionsJSON: toolDefinitionsJSON) else {
            return messages
        }
        return messages.filter { $0 != bridge }
    }

    /// Exact, role-aware provenance for provider-visible messages. This never
    /// searches prompt text. Each category is attached to the concrete message
    /// value that carries it, and the compiler ignores descriptors whose
    /// message is no longer present in a later round.
    static func prebuiltMessageSources(
        snapshot: AttacheRequestSnapshot,
        messages: [AttacheChatMessage]
    ) -> [AttachePrebuiltMessageSource] {
        var descriptors: [AttachePrebuiltMessageSource] = []
        var frozenDirectSources = snapshot.directChatMessageSources
        func append(
            _ message: AttacheChatMessage,
            _ source: AttacheContextItemSource,
            authorization: AttacheSessionAuthorization? = nil,
            egress: AttacheContextItemEgress = .allowedRemote
        ) {
            // Preserve one descriptor per message occurrence. Two identical
            // direct-chat turns are still two provider-visible sources and the
            // content-free receipt should count both.
            descriptors.append(AttachePrebuiltMessageSource(
                message: message,
                source: source,
                authorization: authorization ?? (source.requiresFocusedSessionAuthorization
                    ? snapshot.session
                    : .contextFree),
                egress: egress
            ))
        }
        func appendDirect(_ message: AttacheChatMessage) {
            if let index = frozenDirectSources.firstIndex(where: { $0.message == message }) {
                let frozen = frozenDirectSources.remove(at: index)
                append(message, .recentDirectChatTurns, egress: frozen.egress)
            } else {
                append(message, .recentDirectChatTurns)
            }
        }
        let lastUserIndex = messages.indices.last { messages[$0].role == "user" }

        for (index, message) in messages.enumerated() {
            switch message.role {
            case "system":
                append(message, .safetyPolicy)
                append(message, .activePersonality)
                if snapshot.role == .conversation, snapshot.isFocused {
                    append(message, .focusedSessionMetadata)
                }
            case "tool":
                append(message, .toolResults)
            case "assistant":
                if snapshot.role == .conversation {
                    appendDirect(message)
                } else if snapshot.role == .liveFollowUp {
                    append(message, .retrievedTranscriptEvidence, authorization: snapshot.session)
                } else {
                    append(message, .latestAgentReply)
                }
            case "user":
                switch snapshot.role {
                case .conversation:
                    if index == lastUserIndex {
                        append(message, .currentUserTurn)
                    } else {
                        appendDirect(message)
                    }
                case .followUp:
                    append(message, .latestAgentReply)
                    if index == lastUserIndex { append(message, .currentUserTurn) }
                case .liveFollowUp:
                    // This prompt embeds stored turns from the explicitly
                    // focused session. Label the entire indivisible message as
                    // session evidence so a context-free or stale grant fails
                    // inside ContextCompiler before transport.
                    append(message, .retrievedTranscriptEvidence, authorization: snapshot.session)
                    if index == lastUserIndex { append(message, .currentUserTurn) }
                case .presentation, .recap, .anotherTake, .topicTagging:
                    append(message, .latestAgentReply)
                case .preview:
                    append(message, .currentUserTurn)
                }
            default:
                break
            }
        }
        return descriptors
    }

    private static func toolDefinitionsRequireFocusedSession(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let tools = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return false
        }
        let focusedNames: Set<String> = [
            "read_session_transcript",
            "search_session_transcript",
            "list_working_directory",
            "read_file",
            "stage_agent_instruction",
            "request_exhaustive_review"
        ]
        return tools.contains { tool in
            guard let function = tool["function"] as? [String: Any],
                  let name = function["name"] as? String else { return false }
            return focusedNames.contains(name)
        }
    }

    private static func sessionContextToolObjects() -> [[String: Any]] {
        [
            ["type": "function", "function": [
                "name": "read_session_transcript",
                "description": "Read more of the explicitly focused session. With no arguments, returns opening and recent turns. Pass start_turn to page from a specific turn.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "start_turn": ["type": "integer", "description": "1-indexed turn number. Omit for the bounded overview."],
                        "start_char": ["type": "integer", "description": "0-indexed character offset from a continuation locator."],
                        "max_chars": ["type": "integer", "description": "Maximum characters to return."],
                        "content_hash": ["type": "string", "description": "Content hash from a prior locator. Supplying it makes a stale continuation fail closed."]
                    ]
                ] as [String: Any]
            ]],
            ["type": "function", "function": [
                "name": "search_session_transcript",
                "description": "Search the explicitly focused session and return bounded matching turn locators and snippets.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Text to search for."],
                        "max_results": ["type": "integer", "description": "Maximum bounded matches to return."]
                    ],
                    "required": ["query"]
                ] as [String: Any]
            ]],
            ["type": "function", "function": [
                "name": "list_working_directory",
                "description": "List files in the explicitly focused session's working directory.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "max_results": ["type": "integer", "description": "Maximum bounded entries to return."]
                    ]
                ] as [String: Any]
            ]],
            ["type": "function", "function": [
                "name": "read_file",
                "description": "Read a bounded text file inside the explicitly focused session's working directory.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Path within the focused working directory."],
                        "line_start": ["type": "integer", "description": "1-indexed line number from which to continue."],
                        "max_lines": ["type": "integer", "description": "Maximum bounded lines to return."],
                        "content_hash": ["type": "string", "description": "Content hash from a prior locator. Supplying it makes a stale continuation fail closed."]
                    ],
                    "required": ["path"]
                ] as [String: Any]
            ]]
        ]
    }

    private static func agentInstructionToolObject() -> [String: Any] {
        ["type": "function", "function": [
            "name": "stage_agent_instruction",
            "description": "Prepare a native confirmation for an action on the focused work agent only when the user explicitly asks that agent to act. This tool never sends by itself. 'What did Codex say?' stays with Attaché, but 'Ask Codex what it changed' MUST use this tool. Asking the agent to answer, explain, check, read, summarize, or report is an action even when it concerns prior work or an artifact. Do not substitute local read tools for an explicit handoff, and do not redirect a request naming a different agent. Whenever the user names a specific agent, set intended_agent; never guess or omit intended_agent when a name was given.",
            "parameters": [
                "type": "object",
                "properties": [
                    "instruction": ["type": "string", "description": "Concise instruction proposed for the focused agent."],
                    "intended_agent": [
                        "type": "string",
                        "enum": ["codex", "claude_code"],
                        "description": "Agent explicitly named by the user. Omit only when none was named."
                    ]
                ],
                "required": ["instruction"]
            ] as [String: Any]
        ]]
    }

    private static func sessionDiscoveryToolObject() -> [String: Any] {
        ["type": "function", "function": [
            "name": "request_session_search",
            "description": "Ask Attaché to search the local session index when the user wants to find or remember a prior work session. This action never reads or focuses a result. The model receives only a match count; the user must choose a session in Attaché's native picker before any session context becomes available.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "minLength": 1,
                        "maxLength": AttacheSessionDiscoveryCoordinator.maxQueryLength,
                        "description": "Bounded keywords or a short natural-language description supplied by the user."
                    ]
                ],
                "required": ["query"]
            ] as [String: Any]
        ]]
    }

    private static func exhaustiveReviewToolObject() -> [String: Any] {
        ["type": "function", "function": [
            "name": "request_exhaustive_review",
            "description": "Prepare a cost and data-route preview only when the user explicitly asks to review the entire focused session. This does not start model calls. The user must press Start review in Attaché.",
            "parameters": [
                "type": "object",
                "properties": [String: Any]()
            ] as [String: Any]
        ]]
    }

    private static func memoryProposalToolObject() -> [String: Any] {
        ["type": "function", "function": [
            "name": "propose_memory",
            "description": "Propose one durable user memory for this turn. Attaché's local validator and the user's memory mode decide whether it is rejected, queued, or stored, and fallback retries cannot repeat the local effect.",
            "parameters": [
                "type": "object",
                "properties": [
                    "statement": ["type": "string", "description": "One durable fact stated by the user, never a secret, guess, transient mood, or private reasoning."],
                    "type": [
                        "type": "string",
                        "enum": AttacheMemoryType.allCases.map(\.rawValue)
                    ],
                    "scope": [
                        "type": "string",
                        "enum": ["global", "personality", "topic"]
                    ],
                    "scope_value": [
                        "type": "string",
                        "minLength": 1,
                        "description": "Binding for the selected scope: use the literal global for global, the frozen personality id for personality, or a normalized topic key for topic."
                    ],
                    "sensitivity": [
                        "type": "string",
                        "enum": AttacheMemorySensitivity.allCases.map(\.rawValue)
                    ],
                    "egress": [
                        "type": "string",
                        "enum": AttacheMemoryEgress.allCases.map(\.rawValue)
                    ],
                    "requires_confirmation": [
                        "type": "boolean",
                        "description": "The model's recommendation only. Local policy remains authoritative."
                    ]
                ],
                "required": ["statement", "type", "scope", "scope_value", "sensitivity", "egress", "requires_confirmation"]
            ] as [String: Any]
        ]]
    }

    // MARK: Compiled-only transport

    private struct TransportResult {
        let content: String
        let toolCalls: [AttacheChatToolCall]
        let usage: AttacheParsedTokenUsage
        let compiled: CompiledModelRequest
    }

    private func transport(
        compiled: CompiledModelRequest,
        attempt: AttacheFrozenModelAttempt,
        requestIsActive: (() async -> Bool)?
    ) async throws -> TransportResult {
        guard compiled.modelIdentity == attempt.modelIdentity,
              compiled.receipt.modelIdentityKey == attempt.modelIdentity.capabilityKey else {
            throw AttacheProductionBrokerError.modelIdentityMismatch
        }
        guard attempt.provider.supportsSafePersonalityInference else {
            throw CLILanguageModelError.unsafeToolIsolation(attempt.provider.title)
        }
        if attempt.provider.isCLI, let tool = attempt.provider.cliTool {
            try await Self.requireActiveRequest(requestIsActive)
            let text = try await CLILanguageModel(
                tool: tool,
                model: attempt.model,
                reasoningEffort: attempt.reasoningEffort,
                serviceTier: attempt.serviceTier
            ).complete(prompt: String(decoding: compiled.serializedOutboundRequest, as: UTF8.self))
            let directives = AttachePresentationService.parseCLIToolDirectives(in: text)
            return TransportResult(
                content: directives.isEmpty ? text : "",
                toolCalls: directives.map {
                    AttacheChatToolCall(
                        id: "cli-\(UUID().uuidString)",
                        name: $0.name,
                        arguments: $0.arguments
                    )
                },
                usage: AttacheParsedTokenUsage(
                    inputTokens: nil,
                    outputTokens: nil,
                    cachedTokens: nil,
                    totalTokens: nil
                ),
                compiled: compiled
            )
        }

        var url = attempt.endpoint
        if !url.path.hasSuffix("/chat/completions") {
            url = url.appendingPathComponent("chat/completions")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !attempt.apiKey.isEmpty, NetworkSecurity.allowsBearer(url) {
            request.setValue("Bearer \(attempt.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = compiled.serializedOutboundRequest

        let data: Data
        let response: URLResponse
        do {
            try await Self.requireActiveRequest(requestIsActive)
            (data, response) = try await urlSession.data(
                for: request,
                delegate: AttacheNoRedirectDelegate()
            )
        } catch let urlError as URLError {
            throw AttachePresentationError.transport(urlError)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AttachePresentationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AttachePresentationError.httpStatus(
                http.statusCode,
                String(decoding: data, as: UTF8.self)
            )
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else {
            throw AttachePresentationError.invalidResponse
        }
        let content = message["content"] as? String ?? ""
        let calls = Self.parseHTTPToolCalls(message["tool_calls"])
        let usage = AttacheProviderUsageParser.parse(usageJSON: object["usage"] as? [String: Any])
        return TransportResult(content: content, toolCalls: calls, usage: usage, compiled: compiled)
    }

    /// The final authorization check lives at the transport boundary so a
    /// canceled request or revoked focused-session grant cannot egress merely
    /// because compilation finished earlier.
    private static func requireActiveRequest(
        _ requestIsActive: (() async -> Bool)?
    ) async throws {
        try Task.checkCancellation()
        if let requestIsActive {
            guard await requestIsActive() else { throw CancellationError() }
        }
        try Task.checkCancellation()
    }

    private static func parseHTTPToolCalls(_ value: Any?) -> [AttacheChatToolCall] {
        guard let calls = value as? [[String: Any]] else { return [] }
        return calls.compactMap { call in
            guard let id = call["id"] as? String,
                  let type = call["type"] as? String,
                  let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }
            return AttacheChatToolCall(
                id: id,
                type: type,
                name: name,
                arguments: function["arguments"] as? String ?? "{}"
            )
        }
    }

    private static func httpPayloadTemplate(attempt: AttacheFrozenModelAttempt) throws -> String {
        let messagesSentinel = "__ATTACHE_MESSAGES_SENTINEL_338__"
        let toolsSentinel = "__ATTACHE_TOOLS_SENTINEL_338__"
        var payload: [String: Any] = [
            "model": attempt.model,
            "temperature": 0.6,
            "messages": messagesSentinel
        ]
        if attempt.hasTools { payload["tools"] = toolsSentinel }
        if attempt.provider.supportsReasoningEffort,
           let effort = AttachePresentationService.reasoningEffortPayloadValue(
                attempt.reasoningEffort,
                provider: attempt.provider
           ) {
            payload["reasoning_effort"] = effort
        }
        if attempt.provider.supportsServiceTier,
           let tier = normalizedServiceTier(attempt.serviceTier) {
            payload["service_tier"] = tier
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        var template = String(decoding: data, as: UTF8.self)
        template = template.replacingOccurrences(
            of: "\"\(messagesSentinel)\"",
            with: ContextCompiler.messagesJSONPlaceholder
        )
        template = template.replacingOccurrences(
            of: "\"\(toolsSentinel)\"",
            with: ContextCompiler.toolDefinitionsPlaceholder
        )
        return template
    }

    private func finalizedCLIRequest(
        _ compiled: CompiledModelRequest,
        snapshot: AttacheRequestSnapshot,
        estimator: any TokenEstimating
    ) throws -> CompiledModelRequest {
        let prompt = CLILanguageModel.renderPrompt(messages: compiled.messages)
        let actualInputTokens = estimator.estimate(text: prompt)
        let nonInputReserves = compiled.budgetPlan.outputReserve
            + compiled.budgetPlan.toolReserve
            + compiled.budgetPlan.safetyMargin
            + compiled.budgetPlan.retrievalReserve
        if let hard = compiled.budgetPlan.effectiveHardLimit,
           actualInputTokens + nonInputReserves > hard {
            throw AttacheContextCompilerError.preEgressOverflow(
                userDraft: snapshot.userInput,
                requestedTokens: actualInputTokens + nonInputReserves,
                hardLimit: hard
            )
        }
        let prior = compiled.receipt
        let receipt = ContextReceipt(
            includedSources: prior.includedSources,
            omittedSources: prior.omittedSources,
            truncatedSources: prior.truncatedSources,
            totalEstimatedTokens: actualInputTokens,
            remainingBudget: compiled.budgetPlan.effectiveHardLimit.map {
                max(0, $0 - actualInputTokens - nonInputReserves)
            },
            modelIdentityKey: prior.modelIdentityKey,
            strategyKind: prior.strategyKind,
            stagedProcessingRequired: prior.stagedProcessingRequired,
            failureReason: prior.failureReason,
            includedSourceIdentifiers: prior.includedSourceIdentifiers,
            omittedSourceIdentifiers: prior.omittedSourceIdentifiers,
            truncatedSourceIdentifiers: prior.truncatedSourceIdentifiers
        )
        return CompiledModelRequest(
            messages: compiled.messages,
            providerMessagesJSON: compiled.providerMessagesJSON,
            serializedOutboundRequest: Data(prompt.utf8),
            budgetPlan: compiled.budgetPlan,
            modelIdentity: compiled.modelIdentity,
            receipt: receipt
        )
    }

    private static func normalizedServiceTier(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ["", "default", "standard"].contains(trimmed.lowercased()) ? nil : trimmed
    }

    // MARK: Token calibration

    /// Custom is an explicit user policy and is never modified by learned
    /// calibration. Named strategies may use a persisted correction, but the
    /// calibrated estimator itself can only raise an estimate.
    private func estimatorForRequest(
        _ attempt: AttacheFrozenModelAttempt
    ) -> any TokenEstimating {
        guard attempt.strategy.kind != .custom,
              let diagnostics = calibrationStore?.diagnostics(
                for: Self.calibrationStorageKey(attempt)
              ),
              diagnostics.isActionable else { return estimator }
        if diagnostics.correctionFactor < 1.0 {
            let compilationCapability = Self.compilationCapability(
                attempt.capability,
                modelIdentity: attempt.modelIdentity,
                strategy: attempt.strategy
            )
            guard compilationCapability.declaredInputCeiling != nil else {
                return estimator
            }
        }
        return AttacheCalibratedTokenEstimator(
            base: estimator,
            correction: AttacheCalibrationCorrection(
                factor: diagnostics.correctionFactor,
                sampleCount: diagnostics.sampleCount,
                aggregateError: diagnostics.aggregateEstimateError,
                isActionable: true
            )
        )
    }

    private func recordCalibration(
        usage: AttacheParsedTokenUsage,
        compiled: CompiledModelRequest,
        attempt: AttacheFrozenModelAttempt,
        receiptID: String
    ) {
        guard attempt.strategy.kind != .custom,
              let actualInputTokens = usage.inputTokens,
              actualInputTokens > 0 else { return }
        // Compare provider usage with the uncalibrated, versioned base.
        // Comparing it with an already corrected receipt would feed the
        // correction back into itself and make the lineage oscillate.
        let estimatedInputTokens = estimator.estimate(
            text: String(decoding: compiled.serializedOutboundRequest, as: UTF8.self)
        )
        guard estimatedInputTokens > 0 else { return }
        _ = calibrationStore?.record(AttacheProviderUsageSample(
            modelIdentityKey: attempt.modelIdentity.capabilityKey,
            estimatorVersion: AttacheTokenUsageCalibrator.estimatorVersion,
            strategyKind: attempt.strategy.kind.rawValue,
            role: attempt.role.rawValue,
            estimatedInputTokens: estimatedInputTokens,
            actualInputTokens: actualInputTokens,
            actualOutputTokens: usage.outputTokens ?? 0,
            cachedInputTokens: usage.cachedTokens ?? 0,
            timestamp: Date(),
            receiptID: receiptID
        ))
    }

    private static func calibrationStorageKey(
        _ attempt: AttacheFrozenModelAttempt
    ) -> String {
        AttacheCalibrationStore.storageKey(
            modelIdentityKey: attempt.modelIdentity.capabilityKey,
            estimatorVersion: AttacheTokenUsageCalibrator.estimatorVersion
        )
    }

    private static func defaultCalibrationStore() -> AttacheCalibrationStore? {
        let environment = ProcessInfo.processInfo.environment
        guard NSClassFromString("XCTestCase") == nil,
              environment["ATTACHE_UI_TEST"] != "1",
              environment["ATTACHE_DISABLE_TOKEN_CALIBRATION"] != "1" else {
            return nil
        }
        return AttacheCalibrationStore(
            databaseURL: AttacheAppSupport.supportDirectory()
                .appendingPathComponent("TokenCalibration.sqlite")
        )
    }
}
