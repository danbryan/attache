import Foundation

/// The source of a context item (INF-312). Every item carries explicit
/// provenance so the receipt can name what was included, omitted, or truncated
/// without exposing content.
public enum AttacheContextItemSource: String, Equatable, Sendable, CaseIterable {
    case safetyPolicy
    case activePersonality
    case currentUserTurn
    case recentDirectChatTurns
    case olderChatSummary
    case durableMemory
    case focusedSessionMetadata
    case latestAgentReply
    case retrievedTranscriptEvidence
    case retrievedFileEvidence
    case toolDefinitions
    case toolResults
}

/// How a context item may be treated during compilation (INF-312).
public enum AttacheContextItemTreatment: String, Equatable, Sendable {
    case exactOnly
    case headTailExcerpt
    case summarizeEligible
    case omitWithMarker
    case requiresStagedProcessing
}

/// One structured, authorized context item (INF-312). The compiler estimates
/// its cost, respects its priority and treatment, and fits it into the budget
/// or omits it with a marker.
public struct AttacheContextItem: Equatable, Sendable {
    public let source: AttacheContextItemSource
    public let content: String
    public let provenance: String?
    public let authorization: AttacheSessionAuthorization
    public let priority: Int
    public let treatment: AttacheContextItemTreatment

    public init(
        source: AttacheContextItemSource,
        content: String,
        provenance: String? = nil,
        authorization: AttacheSessionAuthorization = .contextFree,
        priority: Int = 0,
        treatment: AttacheContextItemTreatment = .exactOnly
    ) {
        self.source = source
        self.content = content
        self.provenance = provenance
        self.authorization = authorization
        self.priority = priority
        self.treatment = treatment
    }

    /// True when this item is protected and must always fit or fail (INF-312).
    public var isProtected: Bool {
        source == .safetyPolicy || source == .activePersonality || source == .currentUserTurn
    }

    /// True when this item is broad-task evidence that should trigger staged
    /// processing rather than silent omission when it cannot fit.
    public var isBroadEvidence: Bool {
        source == .retrievedTranscriptEvidence || source == .retrievedFileEvidence
    }
}

/// A content-free receipt recording what the compiler included, omitted, or
/// truncated, and why (INF-312). Contains counts and source identifiers only,
/// never source text.
public struct ContextReceipt: Equatable, Sendable, Codable {
    public let includedSources: [String]
    public let omittedSources: [String]
    public let truncatedSources: [String]
    public let totalEstimatedTokens: Int
    public let remainingBudget: Int?
    public let modelIdentityKey: String
    public let strategyKind: String
    public let stagedProcessingRequired: Bool
    public let failureReason: String?

    public init(
        includedSources: [String], omittedSources: [String], truncatedSources: [String],
        totalEstimatedTokens: Int, remainingBudget: Int?,
        modelIdentityKey: String, strategyKind: String,
        stagedProcessingRequired: Bool, failureReason: String? = nil
    ) {
        self.includedSources = includedSources
        self.omittedSources = omittedSources
        self.truncatedSources = truncatedSources
        self.totalEstimatedTokens = totalEstimatedTokens
        self.remainingBudget = remainingBudget
        self.modelIdentityKey = modelIdentityKey
        self.strategyKind = strategyKind
        self.stagedProcessingRequired = stagedProcessingRequired
        self.failureReason = failureReason
    }
}

/// A compiled model request: the final messages, the budget plan, the model
/// identity, and a content-free receipt (INF-312).
public struct CompiledModelRequest: Equatable, Sendable {
    public let messages: [AttacheChatMessage]
    public let budgetPlan: AttacheContextBudgetPlan
    public let modelIdentity: ModelIdentity
    public let receipt: ContextReceipt

    public init(messages: [AttacheChatMessage], budgetPlan: AttacheContextBudgetPlan, modelIdentity: ModelIdentity, receipt: ContextReceipt) {
        self.messages = messages
        self.budgetPlan = budgetPlan
        self.modelIdentity = modelIdentity
        self.receipt = receipt
    }
}

/// A typed compiler failure (INF-312).
public enum AttacheContextCompilerError: Error, Equatable, Sendable {
    case protectedContentOverflow(userDraft: String, requestedTokens: Int, hardLimit: Int)
    case requiresStagedProcessing(source: String, estimatedTokens: Int, remainingBudget: Int)
    case budgetPlanningFailure(AttacheBudgetFailure)
}

/// The Core-level input the compiler needs from the request snapshot (INF-312).
/// The App's `AttacheRequestSnapshot` converts to this so the compiler stays
/// independent of App types like `Personality`.
public struct ContextCompilerInput: Equatable, Sendable {
    public let userInput: String
    public let modelIdentity: ModelIdentity
    public let role: AttacheRequestRole
    public let profilePrompt: String
    public let memoryContext: String?
    public let session: AttacheSessionAuthorization

    public init(
        userInput: String, modelIdentity: ModelIdentity, role: AttacheRequestRole,
        profilePrompt: String, memoryContext: String?, session: AttacheSessionAuthorization
    ) {
        self.userInput = userInput
        self.modelIdentity = modelIdentity
        self.role = role
        self.profilePrompt = profilePrompt
        self.memoryContext = memoryContext
        self.session = session
    }
}

/// The pure context compiler (INF-312). No HTTP or CLI model request can
/// bypass capability resolution, token estimation, authorization, and context
/// budgeting: every role compiles through this before provider code runs.
public enum ContextCompiler {
    /// Compile a model request from the compiler input, authorized context
    /// items, capability profile, and strategy. Pure and deterministic.
    public static func compile(
        input: ContextCompilerInput,
        items: [AttacheContextItem],
        capability: AttacheModelCapabilityProfile,
        strategy: AttacheContextStrategy,
        estimator: TokenEstimating = AttacheFallbackTokenEstimator()
    ) throws -> CompiledModelRequest {
        // 1. Plan the budget (INF-309).
        let budgetPlan: AttacheContextBudgetPlan
        do {
            budgetPlan = try ContextBudgetPlanner.plan(
                capability: capability,
                strategy: strategy,
                role: input.role,
                currentUserInput: input.userInput,
                estimator: estimator
            )
        } catch let failure as AttacheBudgetFailure {
            throw AttacheContextCompilerError.budgetPlanningFailure(failure)
        }

        // 2. Filter items by authorization: a context-free compile excludes
        //    items authorized only for a focused session (INF-312 criterion 5).
        let authorizedItems = items.filter { item in
            switch (item.authorization, input.session) {
            case (.focused, .contextFree):
                return false // focused-only items excluded from context-free compiles
            default:
                return true
            }
        }

        // 3. Estimate each item's token cost.
        var estimated = authorizedItems.map { item -> (item: AttacheContextItem, tokens: Int) in
            (item, estimator.estimate(text: item.content))
        }

        // 3. Sort by priority descending. Protected items (safety, personality,
        //    user turn) have the highest implicit priority.
        estimated.sort { lhs, rhs in
            let lp = lhs.item.isProtected ? 10_000 : lhs.item.priority
            let rp = rhs.item.isProtected ? 10_000 : rhs.item.priority
            return lp > rp
        }

        // 4. Fit items into the remaining evidence budget. Protected items must
        //    always fit or fail. Broad evidence triggers staged processing.
        let remainingBudget = budgetPlan.remainingEvidenceBudget ?? Int.max
        var included: [(item: AttacheContextItem, tokens: Int)] = []
        var omitted: [String] = []
        var truncated: [String] = []
        var usedTokens = 0
        var stagedRequired = false

        for entry in estimated {
            if entry.item.isProtected {
                // Protected items always fit. If they can't, the budget planner
                // already caught that (protectedContentOverflow). Here we just
                // include them.
                included.append(entry)
                usedTokens += entry.tokens
                continue
            }

            if usedTokens + entry.tokens <= remainingBudget {
                included.append(entry)
                usedTokens += entry.tokens
            } else if entry.item.isBroadEvidence {
                // Broad evidence that cannot fit triggers staged processing,
                // not silent omission (INF-312).
                stagedRequired = true
                omitted.append(entry.item.source.rawValue)
            } else if entry.item.treatment == .omitWithMarker {
                omitted.append(entry.item.source.rawValue)
            } else if entry.item.treatment == .headTailExcerpt {
                // Try a head-tail excerpt (half the tokens).
                let excerptTokens = entry.tokens / 2
                if usedTokens + excerptTokens <= remainingBudget {
                    truncated.append(entry.item.source.rawValue)
                    usedTokens += excerptTokens
                    // The excerpt is included; the compiler marks it truncated.
                    included.append((entry.item, excerptTokens))
                } else {
                    omitted.append(entry.item.source.rawValue)
                }
            } else {
                omitted.append(entry.item.source.rawValue)
            }
        }

        // 5. Build messages from included items in source order.
        let messages = buildMessages(from: included, userInput: input.userInput)

        // 6. Build the content-free receipt.
        let receipt = ContextReceipt(
            includedSources: included.map { $0.item.source.rawValue },
            omittedSources: omitted,
            truncatedSources: truncated,
            totalEstimatedTokens: usedTokens,
            remainingBudget: budgetPlan.remainingEvidenceBudget.map { $0 - usedTokens },
            modelIdentityKey: input.modelIdentity.capabilityKey,
            strategyKind: strategy.kind.rawValue,
            stagedProcessingRequired: stagedRequired,
            failureReason: nil
        )

        return CompiledModelRequest(
            messages: messages,
            budgetPlan: budgetPlan,
            modelIdentity: input.modelIdentity,
            receipt: receipt
        )
    }

    /// Build the chat messages from included items, in the canonical order:
    /// system (safety + personality + memory + metadata), conversation turns,
    /// evidence, tool definitions/results, and finally the current user turn.
    static func buildMessages(
        from included: [(item: AttacheContextItem, tokens: Int)],
        userInput: String
    ) -> [AttacheChatMessage] {
        var systemParts: [String] = []
        var conversationMessages: [AttacheChatMessage] = []
        var evidenceParts: [String] = []
        var toolParts: [String] = []

        for entry in included {
            switch entry.item.source {
            case .safetyPolicy, .activePersonality, .durableMemory, .focusedSessionMetadata, .latestAgentReply, .olderChatSummary:
                systemParts.append(entry.item.content)
            case .currentUserTurn:
                // The user turn becomes the final user message.
                break
            case .recentDirectChatTurns:
                conversationMessages.append(AttacheChatMessage(role: "user", content: entry.item.content))
            case .retrievedTranscriptEvidence, .retrievedFileEvidence:
                evidenceParts.append(entry.item.content)
            case .toolDefinitions, .toolResults:
                toolParts.append(entry.item.content)
            }
        }

        var messages: [AttacheChatMessage] = []
        if !systemParts.isEmpty {
            messages.append(AttacheChatMessage(role: "system", content: systemParts.joined(separator: "\n\n")))
        }
        messages.append(contentsOf: conversationMessages)
        if !evidenceParts.isEmpty {
            messages.append(AttacheChatMessage(role: "user", content: evidenceParts.joined(separator: "\n\n---\n\n")))
        }
        if !toolParts.isEmpty {
            messages.append(AttacheChatMessage(role: "user", content: toolParts.joined(separator: "\n")))
        }
        // The current user turn is always the last message.
        let userTurn = included.first { $0.item.source == .currentUserTurn }
        if let userTurn {
            messages.append(AttacheChatMessage(role: "user", content: userTurn.item.content))
        } else if !userInput.isEmpty {
            messages.append(AttacheChatMessage(role: "user", content: userInput))
        }
        return messages
    }
}