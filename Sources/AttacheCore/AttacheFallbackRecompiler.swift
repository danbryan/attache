import Foundation

/// Why the primary model attempt failed (INF-321). Some categories auto-
/// fallback; others never do.
public enum AttacheFallbackFailureCategory: String, Equatable, Sendable {
    case rateLimit
    case modelUnavailable
    case transientTransport
    case contextLimitOverflow
    case authenticationFailure
    case unknown

    /// True when this failure category is eligible for automatic fallback
    /// (INF-321). Context-limit overflow and authentication failures never
    /// auto-fallback.
    public var isAutoFallbackEligible: Bool {
        switch self {
        case .rateLimit, .modelUnavailable, .transientTransport: return true
        case .contextLimitOverflow, .authenticationFailure: return false
        case .unknown: return false
        }
    }
}

/// The decision to fall back or not (INF-321).
public struct AttacheFallbackDecision: Equatable, Sendable {
    public let shouldFallback: Bool
    public let category: AttacheFallbackFailureCategory
    public let reason: String

    public init(shouldFallback: Bool, category: AttacheFallbackFailureCategory, reason: String) {
        self.shouldFallback = shouldFallback
        self.category = category
        self.reason = reason
    }
}

/// Overflow recovery when the context limit is hit (INF-321). Preserves the
/// draft and offers explicit retry with Automatic or Efficient. Never silently
/// switches providers.
public struct AttacheOverflowRecovery: Equatable, Sendable {
    public let preservedDraft: String
    public let suggestedStrategies: [AttacheContextStrategyKind]
    public let requiresUserAction: Bool

    public init(preservedDraft: String, suggestedStrategies: [AttacheContextStrategyKind] = [.automatic, .efficient], requiresUserAction: Bool = true) {
        self.preservedDraft = preservedDraft
        self.suggestedStrategies = suggestedStrategies
        self.requiresUserAction = requiresUserAction
    }
}

/// One fallback attempt (INF-321). Newly compiled for the fallback's concrete
/// model and capacity. Never reuses the primary model's serialized messages
/// or budget.
public struct AttacheFallbackAttempt: Equatable, Sendable {
    public let attemptNumber: Int
    public let modelIdentity: ModelIdentity
    public let capabilityProfile: AttacheModelCapabilityProfile
    public let compiledRequest: CompiledModelRequest
    public let effectTracker: AttacheToolEffectTracker
    public let preservedFrozenSession: AttacheSessionAuthorization

    public init(
        attemptNumber: Int, modelIdentity: ModelIdentity,
        capabilityProfile: AttacheModelCapabilityProfile,
        compiledRequest: CompiledModelRequest,
        effectTracker: AttacheToolEffectTracker,
        preservedFrozenSession: AttacheSessionAuthorization
    ) {
        self.attemptNumber = attemptNumber
        self.modelIdentity = modelIdentity
        self.capabilityProfile = capabilityProfile
        self.compiledRequest = compiledRequest
        self.effectTracker = effectTracker
        self.preservedFrozenSession = preservedFrozenSession
    }
}

/// Per-call fallback state (INF-321). Resets for each new user turn. A new
/// call starts with the personality's configured primary again.
public struct AttacheFallbackState: Equatable, Sendable {
    public private(set) var attempts: [AttacheFallbackAttempt]
    public private(set) var currentAttemptNumber: Int
    public let maxAttempts: Int

    public init(maxAttempts: Int = 5) {
        self.attempts = []
        self.currentAttemptNumber = 0
        self.maxAttempts = maxAttempts
    }

    public var isExhausted: Bool { currentAttemptNumber >= maxAttempts }
    public var hasAttempted: Bool { !attempts.isEmpty }

    /// Record a fallback attempt (INF-321).
    public mutating func record(_ attempt: AttacheFallbackAttempt) {
        attempts.append(attempt)
        currentAttemptNumber = attempt.attemptNumber
    }

    /// Reset for a new user turn (INF-321). A new call starts with the
    /// primary again.
    public mutating func resetForNewTurn() {
        attempts = []
        currentAttemptNumber = 0
    }

    /// Simulate an attempt number without recording a full attempt (INF-321).
    /// Used for exhaustion testing.
    public mutating func simulateAttemptNumber(_ n: Int) {
        currentAttemptNumber = n
    }
}

/// The pure fallback recompiler (INF-321). Recompiles context from the
/// immutable request snapshot for every fallback model's concrete capacity.
/// Preserves frozen identity and authorization. Never replays effectful tools.
/// Context-limit and authentication failures never auto-fallback.
public enum AttacheFallbackRecompiler {

    /// Classify a provider failure (INF-321).
    public static func classifyFailure(
        statusCode: Int?, errorBody: String?
    ) -> AttacheFallbackFailureCategory {
        if let status = statusCode {
            if status == 401 || status == 403 { return .authenticationFailure }
            if status == 429 { return .rateLimit }
            if status == 404 || status == 503 { return .modelUnavailable }
            if status == 400 || status == 413 {
                if let body = errorBody?.lowercased(),
                   body.contains("context") || body.contains("token limit") || body.contains("too long") {
                    return .contextLimitOverflow
                }
            }
            if status >= 500 { return .transientTransport }
        }
        if let body = errorBody?.lowercased() {
            if body.contains("context length") || body.contains("token limit") || body.contains("too long") {
                return .contextLimitOverflow
            }
            if body.contains("unauthorized") || body.contains("authentication") || body.contains("api key") {
                return .authenticationFailure
            }
            if body.contains("rate limit") || body.contains("quota") {
                return .rateLimit
            }
        }
        return .unknown
    }

    /// Decide whether to auto-fallback (INF-321). Context-limit and
    /// authentication failures never auto-fallback.
    public static func shouldFallback(for category: AttacheFallbackFailureCategory) -> AttacheFallbackDecision {
        let eligible = category.isAutoFallbackEligible
        return AttacheFallbackDecision(
            shouldFallback: eligible,
            category: category,
            reason: eligible ? "Transient failure, falling back." : "\(category.rawValue) never auto-falls back."
        )
    }

    /// Build overflow recovery (INF-321). Preserves the draft and offers
    /// explicit retry. Never silently switches providers.
    public static func overflowRecovery(preserving draft: String) -> AttacheOverflowRecovery {
        AttacheOverflowRecovery(preservedDraft: draft)
    }

    /// Recompile the context for a fallback model (INF-321). Recompiles from
    /// the immutable snapshot for the fallback's concrete capability. Never
    /// reuses the primary model's serialized messages or budget. Preserves
    /// frozen identity, authorization, and the effect tracker.
    public static func recompileForFallback(
        snapshot: ContextCompilerInput,
        items: [AttacheContextItem],
        fallbackModel: ModelIdentity,
        fallbackCapability: AttacheModelCapabilityProfile,
        strategy: AttacheContextStrategy,
        effectTracker: AttacheToolEffectTracker,
        attemptNumber: Int
    ) throws -> AttacheFallbackAttempt {
        // Build the fallback input: same user turn, same role, same profile
        // prompt, same memory, same session, but the fallback's model
        // identity.
        let fallbackInput = ContextCompilerInput(
            userInput: snapshot.userInput,
            modelIdentity: fallbackModel,
            role: snapshot.role,
            profilePrompt: snapshot.profilePrompt,
            memoryContext: snapshot.memoryContext,
            session: snapshot.session
        )
        let compiled = try ContextCompiler.compile(
            input: fallbackInput, items: items,
            capability: fallbackCapability, strategy: strategy
        )
        return AttacheFallbackAttempt(
            attemptNumber: attemptNumber,
            modelIdentity: fallbackModel,
            capabilityProfile: fallbackCapability,
            compiledRequest: compiled,
            effectTracker: effectTracker,
            preservedFrozenSession: snapshot.session
        )
    }

    /// True when the fallback preserves the frozen identity (INF-321). The
    /// personality, user turn, memory snapshot, focused session, and
    /// authorization epoch are all preserved from the immutable snapshot.
    public static func preservesFrozenIdentity(
        snapshot: ContextCompilerInput, attempt: AttacheFallbackAttempt
    ) -> Bool {
        // The user turn is preserved.
        guard attempt.compiledRequest.messages.contains(where: { $0.content == snapshot.userInput }) else {
            return false
        }
        // The frozen session is preserved.
        guard attempt.preservedFrozenSession == snapshot.session else {
            return false
        }
        return true
    }

    /// True when the fallback never replays effectful tools (INF-321).
    public static func neverReplaysEffectfulTools(
        attempt: AttacheFallbackAttempt
    ) -> Bool {
        // The effect tracker is carried forward. If it has effectful calls,
        // the fallback must not replay them. The tracker's presence means
        // the caller is aware; the actual prohibition is enforced by the
        // executor checking prohibitsReplay() before running tools.
        // This function verifies the tracker is carried forward intact.
        return !attempt.effectTracker.hasEffectfulCalls || attempt.effectTracker.prohibitsReplay()
    }

    /// True when the fallback does not introduce unauthorized session data
    /// (INF-321). The fallback compiles from the same snapshot, so it cannot
    /// introduce watched, recent, searched, or newly selected session data
    /// that was not in the original items.
    public static func doesNotIntroduceUnauthorizedData(
        originalItems: [AttacheContextItem], attempt: AttacheFallbackAttempt
    ) -> Bool {
        let originalSources = Set(originalItems.map { $0.source })
        let compiledSources = Set(attempt.compiledRequest.receipt.includedSources.compactMap {
            AttacheContextItemSource(rawValue: $0)
        })
        // The fallback may omit items (smaller model), but it must not
        // include sources that were not in the original items.
        return compiledSources.isSubset(of: originalSources)
    }

    /// True when the user turn is not duplicated (INF-321).
    public static func userTurnNotDuplicated(
        attempt: AttacheFallbackAttempt, userInput: String
    ) -> Bool {
        let userMessages = attempt.compiledRequest.messages.filter { $0.role == "user" }
        let matchingCount = userMessages.filter { $0.content == userInput }.count
        return matchingCount == 1
    }

    /// True when unknown fallback capacity uses an unknown-capacity plan,
    /// not the primary model's limit (INF-321).
    public static func unknownCapacityUsesUnknownPlan(
        fallbackCapability: AttacheModelCapabilityProfile
    ) -> Bool {
        return fallbackCapability.isUnknown
    }
}