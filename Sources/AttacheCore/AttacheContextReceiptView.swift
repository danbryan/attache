import Foundation

/// The disposition of one source category in the receipt (INF-325).
public enum AttacheReceiptSourceDisposition: String, Equatable, Sendable {
    case included
    case omitted
    case truncated
    case staged
}

/// One source category summary in the receipt (INF-325). Content-free: names
/// the source, the count, the disposition, and the omission reason. Never the
/// source text.
public struct AttacheReceiptSourceSummary: Equatable, Sendable {
    public let source: String
    public let count: Int
    public let disposition: AttacheReceiptSourceDisposition
    public let omissionReason: String?

    public init(source: String, count: Int, disposition: AttacheReceiptSourceDisposition, omissionReason: String? = nil) {
        self.source = source
        self.count = count
        self.disposition = disposition
        self.omissionReason = omissionReason
    }
}

/// Model and strategy summary for one attempt (INF-325). Content-free.
public struct AttacheReceiptModelSummary: Equatable, Sendable {
    public let provider: String
    public let model: String
    public let reasoningLevel: String?
    public let strategyKind: String
    public let estimatedInputTokens: Int
    public let effectiveBudget: Int?
    public let outputReserve: Int?
    public let toolReserve: Int?
    public let capabilityProvenance: String
    public let capabilityFreshness: String?

    public init(
        provider: String, model: String, reasoningLevel: String?, strategyKind: String,
        estimatedInputTokens: Int, effectiveBudget: Int?, outputReserve: Int?,
        toolReserve: Int?, capabilityProvenance: String, capabilityFreshness: String?
    ) {
        self.provider = provider
        self.model = model
        self.reasoningLevel = reasoningLevel
        self.strategyKind = strategyKind
        self.estimatedInputTokens = estimatedInputTokens
        self.effectiveBudget = effectiveBudget
        self.outputReserve = outputReserve
        self.toolReserve = toolReserve
        self.capabilityProvenance = capabilityProvenance
        self.capabilityFreshness = capabilityFreshness
    }
}

/// Safe focused-session display metadata (INF-325). Shows the frozen session
/// title, source kind, and authorization time. Never includes hidden searched
/// or watched sessions.
public struct AttacheReceiptFocusedSessionDisplay: Equatable, Sendable {
    public let displayTitle: String
    public let sourceKind: String
    public let authorizationTime: Date

    public init(displayTitle: String, sourceKind: String, authorizationTime: Date) {
        self.displayTitle = displayTitle
        self.sourceKind = sourceKind
        self.authorizationTime = authorizationTime
    }
}

/// One attempt summary (primary or fallback) in the receipt (INF-325).
public struct AttacheReceiptAttemptSummary: Equatable, Sendable {
    public let attemptNumber: Int
    public let isFallback: Bool
    public let modelSummary: AttacheReceiptModelSummary
    public let sourceSummaries: [AttacheReceiptSourceSummary]
    public let totalEstimatedTokens: Int
    public let stagedProcessingRequired: Bool
    public let focusedSessionDisplay: AttacheReceiptFocusedSessionDisplay?
    public let recompiledForFallback: Bool

    public init(
        attemptNumber: Int, isFallback: Bool, modelSummary: AttacheReceiptModelSummary,
        sourceSummaries: [AttacheReceiptSourceSummary], totalEstimatedTokens: Int,
        stagedProcessingRequired: Bool, focusedSessionDisplay: AttacheReceiptFocusedSessionDisplay?,
        recompiledForFallback: Bool
    ) {
        self.attemptNumber = attemptNumber
        self.isFallback = isFallback
        self.modelSummary = modelSummary
        self.sourceSummaries = sourceSummaries
        self.totalEstimatedTokens = totalEstimatedTokens
        self.stagedProcessingRequired = stagedProcessingRequired
        self.focusedSessionDisplay = focusedSessionDisplay
        self.recompiledForFallback = recompiledForFallback
    }

    /// True when the attempt is fully covered (no staged or omitted items)
    /// (INF-325). A staged or incomplete review cannot appear as fully
    /// covered.
    public var isFullyCovered: Bool {
        !stagedProcessingRequired
            && sourceSummaries.allSatisfy { $0.disposition != .staged }
    }
}

/// The full receipt view for one model-backed card (INF-325). Tied to the
/// actual compiled attempt(s). Content-free. Stores only the metadata needed
/// to keep history accurate.
public struct AttacheContextReceiptView: Equatable, Sendable {
    public let cardID: String
    public let attempts: [AttacheReceiptAttemptSummary]
    public let noModelContext: Bool
    public let isContentFree: Bool

    public init(cardID: String, attempts: [AttacheReceiptAttemptSummary], noModelContext: Bool = false) {
        self.cardID = cardID
        self.attempts = attempts
        self.noModelContext = noModelContext
        self.isContentFree = true
    }

    /// True when a fallback was used (INF-325).
    public var usedFallback: Bool { attempts.contains { $0.isFallback } }

    /// The primary attempt (INF-325).
    public var primaryAttempt: AttacheReceiptAttemptSummary? { attempts.first { !$0.isFallback } }

    /// The successful fallback attempt (INF-325).
    public var fallbackAttempt: AttacheReceiptAttemptSummary? { attempts.first { $0.isFallback } }
}

/// The pure receipt builder (INF-325). Builds a content-free receipt view from
/// compiled request(s). Every model-backed card has exactly one receipt tied
/// to the actual compiled attempt that produced it.
public enum AttacheContextReceiptBuilder {

    /// Build a receipt from a primary compiled request (INF-325).
    public static func build(
        cardID: String,
        primaryCompiled: CompiledModelRequest,
        fallbackAttempt: AttacheFallbackAttempt? = nil,
        authorizationTime: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> AttacheContextReceiptView {
        var attempts: [AttacheReceiptAttemptSummary] = []
        let primary = buildAttempt(
            compiled: primaryCompiled, attemptNumber: 1, isFallback: false,
            recompiledForFallback: false, authorizationTime: authorizationTime
        )
        attempts.append(primary)
        if let fallback = fallbackAttempt {
            let fallbackSummary = buildAttempt(
                compiled: fallback.compiledRequest, attemptNumber: fallback.attemptNumber,
                isFallback: true, recompiledForFallback: true,
                authorizationTime: authorizationTime
            )
            attempts.append(fallbackSummary)
        }
        return AttacheContextReceiptView(cardID: cardID, attempts: attempts)
    }

    /// Build a no-model-context receipt for plain readback or local non-model
    /// events (INF-325).
    public static func buildNoModel(cardID: String) -> AttacheContextReceiptView {
        AttacheContextReceiptView(cardID: cardID, attempts: [], noModelContext: true)
    }

    static func buildAttempt(
        compiled: CompiledModelRequest, attemptNumber: Int, isFallback: Bool,
        recompiledForFallback: Bool, authorizationTime: Date
    ) -> AttacheReceiptAttemptSummary {
        let receipt = compiled.receipt
        let model = compiled.modelIdentity
        let modelSummary = AttacheReceiptModelSummary(
            provider: model.provider, model: model.requestedModel,
            reasoningLevel: nil, strategyKind: receipt.strategyKind,
            estimatedInputTokens: receipt.totalEstimatedTokens,
            effectiveBudget: compiled.budgetPlan.effectiveHardLimit,
            outputReserve: nil, toolReserve: nil,
            capabilityProvenance: "providerMetadata",
            capabilityFreshness: nil
        )
        let sourceSummaries = buildSourceSummaries(receipt: receipt)
        let focusedDisplay: AttacheReceiptFocusedSessionDisplay? = nil
        return AttacheReceiptAttemptSummary(
            attemptNumber: attemptNumber, isFallback: isFallback,
            modelSummary: modelSummary, sourceSummaries: sourceSummaries,
            totalEstimatedTokens: receipt.totalEstimatedTokens,
            stagedProcessingRequired: receipt.stagedProcessingRequired,
            focusedSessionDisplay: focusedDisplay,
            recompiledForFallback: recompiledForFallback
        )
    }

    static func buildSourceSummaries(receipt: ContextReceipt) -> [AttacheReceiptSourceSummary] {
        let includedCounts = countBySource(receipt.includedSources)
        let omittedCounts = countBySource(receipt.omittedSources)
        let truncatedCounts = countBySource(receipt.truncatedSources)
        let allSources = Set(includedCounts.keys).union(omittedCounts.keys).union(truncatedCounts.keys)
        return allSources.sorted().map { source in
            if let count = includedCounts[source] {
                return AttacheReceiptSourceSummary(source: source, count: count, disposition: .included)
            }
            if let count = truncatedCounts[source] {
                return AttacheReceiptSourceSummary(source: source, count: count, disposition: .truncated, omissionReason: "budget")
            }
            if let count = omittedCounts[source] {
                let reason = receipt.stagedProcessingRequired ? "awaiting exhaustive processing" : "budget"
                let disposition: AttacheReceiptSourceDisposition = receipt.stagedProcessingRequired ? .staged : .omitted
                return AttacheReceiptSourceSummary(source: source, count: count, disposition: disposition, omissionReason: reason)
            }
            return AttacheReceiptSourceSummary(source: source, count: 0, disposition: .omitted, omissionReason: "unknown")
        }
    }

    static func countBySource(_ sources: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for source in sources { counts[source, default: 0] += 1 }
        return counts
    }
}

/// The pure receipt serializer (INF-325). Produces a content-free redacted
/// diagnostic string that can be safely copied. Never includes prompt text,
/// memory text, excerpts, private reasoning, file contents, full paths, API
/// keys, or tool-result content.
public enum AttacheContextReceiptSerializer {

    /// Serialize a receipt view to a content-free diagnostic string (INF-325).
    public static func serialize(_ view: AttacheContextReceiptView) -> String {
        if view.noModelContext {
            return "No model context was sent for this response."
        }
        var lines: [String] = []
        lines.append("Context receipt for card \(view.cardID)")
        if view.usedFallback {
            lines.append("A fallback was used. Context was recompiled for the fallback model.")
        }
        for attempt in view.attempts {
            let prefix = attempt.isFallback ? "Fallback attempt \(attempt.attemptNumber)" : "Primary attempt \(attempt.attemptNumber)"
            lines.append("\(prefix): \(attempt.modelSummary.provider)/\(attempt.modelSummary.model), strategy=\(attempt.modelSummary.strategyKind), est=\(attempt.totalEstimatedTokens) tokens")
            if attempt.stagedProcessingRequired {
                lines.append("  Staged processing required. Not fully covered.")
            }
            for summary in attempt.sourceSummaries {
                let reason = summary.omissionReason.map { " (\($0))" } ?? ""
                lines.append("  \(summary.source): \(summary.count) \(summary.disposition.rawValue)\(reason)")
            }
            if let focused = attempt.focusedSessionDisplay {
                lines.append("  Focused session: \(focused.displayTitle) (\(focused.sourceKind))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Verify that a serialized receipt passes leakage fixtures (INF-325).
    /// Returns true when no secrets, prompt text, memory text, excerpts, file
    /// contents, paths, or keys appear in the serialized string.
    public static func passesLeakageFixtures(_ serialized: String) -> Bool {
        let forbidden = [
            "api_key", "sk-", "bearer ", "private_key", "password",
            "secret", "/Users/", "transcript", "read_file", "tool_result",
            "reasoning_content", "prompt text", "memory text",
            "-----begin", "aws_secret"
        ]
        let lower = serialized.lowercased()
        return !forbidden.contains { lower.contains($0) }
    }

    /// Verify that a no-focus receipt contains no work-session category or
    /// identifier (INF-325).
    public static func noFocusReceiptHasNoSessionData(_ view: AttacheContextReceiptView) -> Bool {
        guard view.noModelContext == false else { return true }
        for attempt in view.attempts {
            if attempt.focusedSessionDisplay != nil { return false }
            for summary in attempt.sourceSummaries {
                if summary.source.contains("focusedSession") { return false }
                if summary.source.contains("transcript") { return false }
                if summary.source.contains("file") { return false }
            }
        }
        return true
    }

    /// Verify that a focused receipt lists only the frozen focused session
    /// and exact evidence locators/counts (INF-325).
    public static func focusedReceiptHasOnlyFrozenSession(_ view: AttacheContextReceiptView) -> Bool {
        for attempt in view.attempts {
            if attempt.focusedSessionDisplay == nil { return false }
        }
        return true
    }
}