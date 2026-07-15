import Foundation

/// The kind of tool result, tracked for budget accounting (INF-317).
public enum AttacheToolResultKind: String, Equatable, Sendable {
    case transcriptPage
    case fileRead
    case directoryList
    case searchResult
    case budgetExhausted
    case refused
}

/// What the enforcer decided about a single result (INF-317). Content-free:
/// names the kind and the counts, never the result text.
public struct AttacheToolBudgetDecision: Equatable, Sendable {
    public enum Outcome: String, Equatable, Sendable {
        case full
        case excerpt
        case refused
        case budgetExhausted
    }

    public let outcome: Outcome
    public let kind: AttacheToolResultKind
    public let originalTokens: Int
    public let includedTokens: Int
    public let omittedTokens: Int
    public let continuationHint: String?
    public let omissionMarker: String?

    public init(
        outcome: Outcome, kind: AttacheToolResultKind,
        originalTokens: Int, includedTokens: Int, omittedTokens: Int,
        continuationHint: String? = nil, omissionMarker: String? = nil
    ) {
        self.outcome = outcome
        self.kind = kind
        self.originalTokens = originalTokens
        self.includedTokens = includedTokens
        self.omittedTokens = omittedTokens
        self.continuationHint = continuationHint
        self.omissionMarker = omissionMarker
    }

    public var wasTruncated: Bool { outcome == .excerpt }
    public var wasRefused: Bool { outcome == .refused || outcome == .budgetExhausted }
}

/// Validated and clamped limits for one tool call (INF-317). The model may
/// send any arguments it wants; the enforcer resolves negative, zero,
/// enormous, nonnumeric, and missing values to safe defaults before any data
/// is read.
public struct AttacheToolCallLimits: Equatable, Sendable {
    public let maxChars: Int
    public let maxResults: Int
    public let startOffset: Int
    public let maxQueryLength: Int
    public let maxFilePathLength: Int

    public init(maxChars: Int, maxResults: Int, startOffset: Int, maxQueryLength: Int, maxFilePathLength: Int) {
        self.maxChars = maxChars
        self.maxResults = maxResults
        self.startOffset = startOffset
        self.maxQueryLength = maxQueryLength
        self.maxFilePathLength = maxFilePathLength
    }
}

/// A tool budget reserve for one model response (INF-317). Multiple tool calls
/// in one response share one reserve. The reserve is consumed as results are
/// accounted; when it is spent, further reads return a budget-exhausted
/// result.
public struct AttacheToolBudgetReserve: Equatable, Sendable {
    public let totalTokens: Int
    public private(set) var consumedTokens: Int
    public let perCallCap: Int

    public init(totalTokens: Int, perCallCap: Int) {
        self.totalTokens = max(totalTokens, 0)
        self.consumedTokens = 0
        self.perCallCap = max(perCallCap, 0)
    }

    public var remainingTokens: Int { max(totalTokens - consumedTokens, 0) }
    public var isExhausted: Bool { remainingTokens <= 0 }

    /// Consume tokens from the reserve. Returns the actual amount consumed
    /// (clamped to remaining). Mutates the reserve.
    public mutating func consume(_ tokens: Int) -> Int {
        let actual = min(max(tokens, 0), remainingTokens)
        consumedTokens += actual
        return actual
    }
}

/// Strategy-dependent budget policy for tool results (INF-317). Efficient,
/// Automatic, and Maximum coverage receive distinct dynamic allowances, not
/// one low cap. The per-call cap is a fraction of the total tool reserve so a
/// single enormous page cannot monopolize the budget.
public struct AttacheToolBudgetPolicy: Equatable, Sendable {
    public let perCallFraction: Double
    public let defaultMaxChars: Int
    public let defaultMaxResults: Int
    public let maxQueryLength: Int
    public let maxFilePathLength: Int
    public let maxCharsAbsolute: Int

    public init(
        perCallFraction: Double, defaultMaxChars: Int, defaultMaxResults: Int,
        maxQueryLength: Int, maxFilePathLength: Int, maxCharsAbsolute: Int
    ) {
        self.perCallFraction = perCallFraction
        self.defaultMaxChars = defaultMaxChars
        self.defaultMaxResults = defaultMaxResults
        self.maxQueryLength = maxQueryLength
        self.maxFilePathLength = maxFilePathLength
        self.maxCharsAbsolute = maxCharsAbsolute
    }

    /// Derive the policy from the strategy (INF-317). Distinct allowances.
    public static func from(strategy: AttacheContextStrategy) -> AttacheToolBudgetPolicy {
        switch strategy.kind {
        case .efficient:
            return AttacheToolBudgetPolicy(
                perCallFraction: 0.20, defaultMaxChars: 2_000,
                defaultMaxResults: 5, maxQueryLength: 200,
                maxFilePathLength: 1_024, maxCharsAbsolute: 8_000
            )
        case .automatic:
            return AttacheToolBudgetPolicy(
                perCallFraction: 0.33, defaultMaxChars: 4_000,
                defaultMaxResults: 10, maxQueryLength: 200,
                maxFilePathLength: 1_024, maxCharsAbsolute: 16_000
            )
        case .maximumCoverage:
            return AttacheToolBudgetPolicy(
                perCallFraction: 0.50, defaultMaxChars: 8_000,
                defaultMaxResults: 20, maxQueryLength: 400,
                maxFilePathLength: 1_024, maxCharsAbsolute: 32_000
            )
        case .custom:
            return AttacheToolBudgetPolicy(
                perCallFraction: 0.33, defaultMaxChars: 4_000,
                defaultMaxResults: 10, maxQueryLength: 200,
                maxFilePathLength: 1_024, maxCharsAbsolute: 16_000
            )
        }
    }

    /// Build the reserve from the tool reserve tokens in the budget plan
    /// (INF-317).
    public func reserve(toolReserveTokens: Int) -> AttacheToolBudgetReserve {
        let total = max(toolReserveTokens, 0)
        let cap = max(Int(Double(total) * perCallFraction), 1)
        return AttacheToolBudgetReserve(totalTokens: total, perCallCap: cap)
    }
}

/// The pure tool budget enforcer (INF-317). Validates and clamps model-
/// supplied arguments, accounts each result against the shared reserve, clips
/// or refuses results to fit, and signals exhaustion. No individual or
/// cumulative result exceeds the live remaining allowance.
public enum AttacheToolBudgetEnforcer {

    public static let maxCharsFloor = 256

    /// Resolve model-supplied size arguments to safe limits (INF-317).
    /// Negative, zero, enormous, nonnumeric, and missing values all resolve
    /// to safe defaults. The result is clamped to the per-call cap and the
    /// absolute ceiling.
    public static func resolveLimits(
        requestedMaxChars: Int?,
        requestedMaxResults: Int?,
        requestedStartOffset: Int?,
        requestedQueryLength: Int?,
        reserve: AttacheToolBudgetReserve,
        policy: AttacheToolBudgetPolicy
    ) -> AttacheToolCallLimits {
        let maxChars = clampMaxChars(requestedMaxChars, reserve: reserve, policy: policy)
        let maxResults = clampMaxResults(requestedMaxResults, policy: policy)
        let startOffset = clampStartOffset(requestedStartOffset)
        let maxQueryLength = policy.maxQueryLength
        let maxFilePathLength = policy.maxFilePathLength
        return AttacheToolCallLimits(
            maxChars: maxChars, maxResults: maxResults,
            startOffset: startOffset, maxQueryLength: maxQueryLength,
            maxFilePathLength: maxFilePathLength
        )
    }

    /// Clamp a model-supplied max_chars value (INF-317). nil, negative, zero,
    /// and nonnumeric (the caller passes nil for nonnumeric) all fall to the
    /// policy default. Enormous values fall to the per-call cap or the
    /// absolute ceiling, whichever is smaller.
    public static func clampMaxChars(
        _ requested: Int?, reserve: AttacheToolBudgetReserve, policy: AttacheToolBudgetPolicy
    ) -> Int {
        guard let requested, requested > 0 else {
            return min(policy.defaultMaxChars, reserve.perCallCap, reserve.remainingTokens, policy.maxCharsAbsolute)
        }
        let cap = min(reserve.perCallCap, reserve.remainingTokens, policy.maxCharsAbsolute)
        return min(max(requested, maxCharsFloor), cap)
    }

    /// Clamp a model-supplied max_results value (INF-317).
    public static func clampMaxResults(_ requested: Int?, policy: AttacheToolBudgetPolicy) -> Int {
        guard let requested, requested > 0 else { return policy.defaultMaxResults }
        return min(requested, policy.defaultMaxResults * 2)
    }

    /// Clamp a model-supplied start offset (INF-317). Negative resolves to 0.
    public static func clampStartOffset(_ requested: Int?) -> Int {
        guard let requested else { return 0 }
        return max(requested, 0)
    }

    /// Account a result against the reserve (INF-317). Estimates the result,
    /// clips it to the per-call cap and remaining reserve, consumes the
    /// tokens, and returns the decision. If the reserve is exhausted, returns
    /// a budget-exhausted decision without reading the result.
    public static func accountResult(
        content: String,
        kind: AttacheToolResultKind,
        limits: AttacheToolCallLimits,
        reserve: inout AttacheToolBudgetReserve,
        estimator: TokenEstimating = AttacheFallbackTokenEstimator()
    ) -> (clampedContent: String, decision: AttacheToolBudgetDecision) {
        if reserve.isExhausted {
            return ("", AttacheToolBudgetDecision(
                outcome: .budgetExhausted, kind: .budgetExhausted,
                originalTokens: 0, includedTokens: 0, omittedTokens: 0
            ))
        }
        let originalTokens = estimator.estimate(text: content)
        let available = min(reserve.perCallCap, reserve.remainingTokens)
        // Clip the content to the character budget. A rough token-to-char
        // heuristic: the estimator already gives tokens; we clip characters
        // proportionally so the included tokens fit the available budget.
        if originalTokens <= available {
            let consumed = reserve.consume(originalTokens)
            return (content, AttacheToolBudgetDecision(
                outcome: .full, kind: kind,
                originalTokens: originalTokens, includedTokens: consumed,
                omittedTokens: 0
            ))
        }
        // Excerpt: clip the content so its estimated tokens fit the available
        // budget. Preserve the start (head) so the model sees the beginning.
        let ratio = Double(available) / Double(max(originalTokens, 1))
        let charLimit = max(Int(Double(content.count) * ratio), 1)
        let charLimitClamped = min(charLimit, limits.maxChars)
        let excerpt = String(content.prefix(charLimitClamped))
        let excerptTokens = estimator.estimate(text: excerpt)
        let consumed = reserve.consume(excerptTokens)
        let omitted = originalTokens - consumed
        let continuation = continuationHint(kind: kind, startOffset: limits.startOffset, includedChars: charLimitClamped, totalChars: content.count)
        return (excerpt, AttacheToolBudgetDecision(
            outcome: .excerpt, kind: kind,
            originalTokens: originalTokens, includedTokens: consumed,
            omittedTokens: omitted,
            continuationHint: continuation,
            omissionMarker: "[\(omitted) tokens omitted. \(continuation ?? "")]"
        ))
    }

    /// Transcript paging for a giant turn (INF-317). A million-character turn
    /// returns a bounded labeled excerpt, not the whole turn. The turn number
    /// is preserved. An omission marker and continuation hint tell the model
    /// what was left out and how to request the next range.
    public static func pageTranscriptTurn(
        turnNumber: Int,
        content: String,
        limits: AttacheToolCallLimits,
        reserve: inout AttacheToolBudgetReserve,
        estimator: TokenEstimating = AttacheFallbackTokenEstimator()
    ) -> (excerpt: String, decision: AttacheToolBudgetDecision) {
        let (clamped, decision) = accountResult(
            content: content, kind: .transcriptPage,
            limits: limits, reserve: &reserve, estimator: estimator
        )
        let labeled = "Turn \(turnNumber): \(clamped)"
        let updatedDecision: AttacheToolBudgetDecision
        if decision.outcome == .excerpt {
            updatedDecision = AttacheToolBudgetDecision(
                outcome: .excerpt, kind: .transcriptPage,
                originalTokens: decision.originalTokens,
                includedTokens: decision.includedTokens,
                omittedTokens: decision.omittedTokens,
                continuationHint: decision.continuationHint,
                omissionMarker: "Turn \(turnNumber): \(decision.omissionMarker ?? "")"
            )
        } else {
            updatedDecision = decision
        }
        return (labeled, updatedDecision)
    }

    /// The budget-exhausted result (INF-317). When the cumulative reserve is
    /// spent, the enforcer returns this short structured result and the
    /// caller must force a final answer without more read tools.
    public static func budgetExhaustedResult() -> (content: String, decision: AttacheToolBudgetDecision) {
        let content = "Tool budget exhausted. No more reads are available. Answer from what you already have and disclose that the transcript budget was reached."
        return (content, AttacheToolBudgetDecision(
            outcome: .budgetExhausted, kind: .budgetExhausted,
            originalTokens: 0, includedTokens: 0, omittedTokens: 0
        ))
    }

    /// Build a continuation hint for a truncated result (INF-317). Tells the
    /// model how to request the next range without claiming exhaustive
    /// coverage.
    public static func continuationHint(
        kind: AttacheToolResultKind, startOffset: Int, includedChars: Int, totalChars: Int
    ) -> String {
        let nextStart = startOffset + includedChars
        switch kind {
        case .transcriptPage:
            return "Request turn with start=\(nextStart) to continue."
        case .fileRead:
            return "Request file with start=\(nextStart) to continue from char \(nextStart) of \(totalChars)."
        case .directoryList:
            return "Request directory with start=\(nextStart) to continue."
        case .searchResult:
            return "Refine the query or request start=\(nextStart) for more results."
        case .budgetExhausted, .refused:
            return "No more data available."
        }
    }
}

/// Tracks effectful tool calls so fallback logic can prohibit replay (INF-317).
/// A corrective retry or model fallback cannot replay an effectful tool that
/// already ran. Pure and content-free.
public struct AttacheToolEffectTracker: Equatable, Sendable {
    public private(set) var effectfulCalls: Set<String>

    public init() { self.effectfulCalls = [] }

    /// Record an effectful tool call by its call ID (INF-317).
    public mutating func recordEffect(toolName: String, callID: String) {
        effectfulCalls.insert("\(toolName):\(callID)")
    }

    /// True when any effectful call was recorded (INF-317).
    public var hasEffectfulCalls: Bool { !effectfulCalls.isEmpty }

    /// True when replaying effectful tools is prohibited (INF-317). Always
    /// true when there are effectful calls: a fallback or retry must not
    /// replay them.
    public func prohibitsReplay() -> Bool { hasEffectfulCalls }

    /// True when the given tool/call was already recorded as effectful.
    public func wasRecorded(toolName: String, callID: String) -> Bool {
        effectfulCalls.contains("\(toolName):\(callID)")
    }
}

/// The 5 MB file refusal and working-directory containment guard (INF-317).
/// Preserves the existing containment rules and keeps them at least as strict.
public enum AttacheFileContainmentGuard {
    public static let maxFileBytes = 5 * 1024 * 1024 // 5 MB

    /// True when the file path is refused: too large, escapes the working
    /// directory, or is a symlink that resolves outside (INF-317).
    public static func shouldRefuse(
        filePath: String,
        workingDirectory: String,
        fileSizeBytes: Int,
        resolvesOutsideWorkingDirectory: Bool = false
    ) -> Bool {
        if fileSizeBytes > maxFileBytes { return true }
        if resolvesOutsideWorkingDirectory { return true }
        // Containment: the file path must be inside the working directory.
        // Reject absolute paths that do not start with the working directory,
        // and reject parent-traversal that escapes it.
        if filePath.hasPrefix("/") {
            return !filePath.hasPrefix(workingDirectory)
        }
        if filePath.contains("..") {
            // Conservative: any parent traversal in a relative path is refused
            // unless the working directory is nil/empty (no containment target).
            return !workingDirectory.isEmpty
        }
        return false
    }
}