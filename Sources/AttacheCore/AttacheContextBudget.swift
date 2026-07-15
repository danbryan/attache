import Foundation

// MARK: - Token estimating

/// Estimates token counts for a model family (INF-309). Implementations exist
/// where a reliable local tokenizer is available; otherwise the conservative
/// Unicode-aware fallback is used. Algorithms are versioned so later calibration
/// does not silently reinterpret old diagnostics.
public protocol TokenEstimating: Sendable {
    var family: String { get }
    var version: Int { get }
    func estimate(text: String) -> Int
}

/// A conservative, Unicode-aware fallback estimator (INF-309). It deliberately
/// overestimates so a budget never silently under-reserves: CJK, kana, hangul,
/// and emoji count as roughly one token each (they are typically one to two in
/// real BPE), while Latin and punctuation count at about four characters per
/// token, rounded up. A small per-call framing overhead is added by the caller.
public struct AttacheFallbackTokenEstimator: TokenEstimating {
    public let family = "unicode-fallback"
    public let version = 1

    public init() {}

    public func estimate(text: String) -> Int {
        var dense = 0
        var sparse = 0
        for scalar in text.unicodeScalars {
            if Self.isDense(scalar) {
                dense += 1
            } else {
                sparse += 1
            }
        }
        let denseTokens = dense
        let sparseTokens = (sparse + 3) / 4
        return denseTokens + sparseTokens
    }

    /// True for code points that are typically one to two BPE tokens, so the
    /// fallback counts them as one each (a conservative lower bound on token
    /// count that still beats treating them as four-characters-per-token).
    static func isDense(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        // CJK Unified Ideographs, extensions A/B, kana, hangul, emoji, and
        // combining marks are dense in token space.
        if v >= 0x3040 && v <= 0x30FF { return true }   // Hiragana + Katakana
        if v >= 0x3400 && v <= 0x9FFF { return true }   // CJK Unified + Ext A
        if v >= 0xAC00 && v <= 0xD7AF { return true }   // Hangul syllables
        if v >= 0xF900 && v <= 0xFAFF { return true }   // CJK compat ideographs
        if v >= 0x20000 && v <= 0x2FFFF { return true } // CJK extensions B-F
        if v >= 0x1F000 && v <= 0x1FAFF { return true } // emoji + symbols
        if v >= 0x2600 && v <= 0x27BF { return true }   // misc symbols + dingbats
        if v >= 0x0300 && v <= 0x036F { return true }   // combining diacriticals
        return false
    }
}

// MARK: - Budget plan

/// A resolved context budget for one request (INF-309). Pure, serializable, and
/// deterministic so receipts and tests agree. `effectiveHardLimit` is nil when
/// capacity is unknown, in which case `remainingEvidenceBudget` is a labeled
/// progressive envelope rather than a fake hard fact.
public struct AttacheContextBudgetPlan: Equatable, Sendable, Codable {
    public let effectiveHardLimit: Int?
    public let outputReserve: Int
    public let toolReserve: Int
    public let safetyMargin: Int
    public let retrievalReserve: Int
    public let framingOverhead: Int
    public let currentUserInputTokens: Int
    public let remainingEvidenceBudget: Int?
    public let strategy: AttacheContextStrategy
    public let unknownCapacity: Bool
    public let estimatorFamily: String
    public let estimatorVersion: Int

    public init(
        effectiveHardLimit: Int?,
        outputReserve: Int,
        toolReserve: Int,
        safetyMargin: Int,
        retrievalReserve: Int,
        framingOverhead: Int,
        currentUserInputTokens: Int,
        remainingEvidenceBudget: Int?,
        strategy: AttacheContextStrategy,
        unknownCapacity: Bool,
        estimatorFamily: String,
        estimatorVersion: Int
    ) {
        self.effectiveHardLimit = effectiveHardLimit
        self.outputReserve = outputReserve
        self.toolReserve = toolReserve
        self.safetyMargin = safetyMargin
        self.retrievalReserve = retrievalReserve
        self.framingOverhead = framingOverhead
        self.currentUserInputTokens = currentUserInputTokens
        self.remainingEvidenceBudget = remainingEvidenceBudget
        self.strategy = strategy
        self.unknownCapacity = unknownCapacity
        self.estimatorFamily = estimatorFamily
        self.estimatorVersion = estimatorVersion
    }

    /// The total reserved portion (output + tool + safety + retrieval + framing
    /// + current input). Never exceeds the hard limit on a valid plan.
    public var totalReserved: Int {
        outputReserve + toolReserve + safetyMargin + retrievalReserve + framingOverhead + currentUserInputTokens
    }
}

/// A typed budget failure (INF-309). Overflow fails before any network or CLI
/// invocation and preserves the user draft so the caller can surface it.
public enum AttacheBudgetFailure: Error, Equatable, Sendable {
    case protectedContentOverflow(userDraft: String, requestedTokens: Int, hardLimit: Int)
    case invalidCustomPolicy(AttacheContextPolicyError)
}

/// A deterministic context budget planner (INF-309). Given a capability profile,
/// a strategy, a request role, the current user input, and the framing material
/// (tool definitions, bridge wrappers), it resolves the effective input capacity
/// and every reserve, then returns the remaining evidence budget or a typed
/// failure when protected content cannot fit. Pure and independent of SwiftUI.
public enum ContextBudgetPlanner {
    /// A conservative progressive envelope used when capacity is unknown, so a
    /// request can still proceed without inventing a provider hard limit.
    public static let unknownCapacityEnvelope = 16_384

    /// Strategy multipliers on the remaining evidence budget, enforcing
    /// monotonicity: Efficient never allocates more than Automatic, and Maximum
    /// coverage may use more (INF-309).
    static let efficientMultiplier = 0.5
    static let automaticMultiplier = 0.75
    static let maximumCoverageMultiplier = 1.0

    public static func plan(
        capability: AttacheModelCapabilityProfile,
        strategy: AttacheContextStrategy,
        role: AttacheRequestRole,
        currentUserInput: String,
        estimator: TokenEstimating = AttacheFallbackTokenEstimator(),
        toolDefinitionsText: String = "",
        bridgeWrapperText: String = ""
    ) throws -> AttacheContextBudgetPlan {
        // Custom strategy validates its own policy first.
        if strategy.kind == .custom, let custom = strategy.custom {
            do {
                try custom.validate()
            } catch let error as AttacheContextPolicyError {
                throw AttacheBudgetFailure.invalidCustomPolicy(error)
            }
        }

        let unknownCapacity = capability.declaredInputCeiling == nil
        let capabilityCeiling: Int? = capability.declaredInputCeiling
        let inputTokens = estimator.estimate(text: currentUserInput)

        // The effective hard limit merges the detected ceiling with a Custom
        // policy's hard cap. Unknown capacity uses the progressive envelope,
        // labeled, never a fake provider fact.
        let customHardCap = (strategy.kind == .custom ? strategy.custom?.hardInputLimit : nil)
        let mergedCeiling: Int? = {
            switch (capabilityCeiling, customHardCap) {
            case let (cap?, custom?): return min(cap, custom)
            case (let cap?, nil): return cap
            case (nil, let custom?): return custom
            default: return nil
            }
        }()
        let effectiveHardLimit: Int? = mergedCeiling ?? (unknownCapacity ? unknownCapacityEnvelope : nil)

        let toolDefinitionTokens = estimator.estimate(text: toolDefinitionsText)
        let bridgeTokens = estimator.estimate(text: bridgeWrapperText)

        // Reserves are proportionally capped by the effective hard limit so they
        // never exceed it on a small model (INF-309: "never reserve beyond the
        // hard limit"). Custom uses the user's validated values.
        let limit = effectiveHardLimit ?? Int.max
        let outputReserve: Int
        let toolReserve: Int
        let safetyMargin: Int
        if strategy.kind == .custom, let custom = strategy.custom {
            outputReserve = custom.outputReserve
            toolReserve = custom.toolReserve
            safetyMargin = custom.safetyMargin
        } else {
            outputReserve = Self.capped(Self.defaultOutputReserve(role: role), limit: limit, divisor: 8)
            toolReserve = Self.capped(Self.defaultToolReserve(role: role), limit: limit, divisor: 4)
            safetyMargin = Self.capped(Self.safetyMargin(for: capability), limit: limit, divisor: 16)
        }
        let framingOverhead = min(framingOverhead(role: role) + toolDefinitionTokens + bridgeTokens, max(64, limit / 16))
        let retrievalReserve = Self.capped(Self.defaultRetrievalReserve(role: role), limit: limit, divisor: 4)

        guard effectiveHardLimit != nil else {
            // Unbounded: return nil budget (no ceiling to plan against).
            return AttacheContextBudgetPlan(
                effectiveHardLimit: nil, outputReserve: outputReserve, toolReserve: toolReserve,
                safetyMargin: safetyMargin, retrievalReserve: retrievalReserve,
                framingOverhead: framingOverhead, currentUserInputTokens: inputTokens,
                remainingEvidenceBudget: nil, strategy: strategy, unknownCapacity: unknownCapacity,
                estimatorFamily: estimator.family, estimatorVersion: estimator.version
            )
        }

        let hard = effectiveHardLimit!

        // Never reserve beyond the hard limit. If protected content (current
        // input + all reserves + framing) cannot fit, fail before inference and
        // preserve the user draft.
        let totalReserved = outputReserve + toolReserve + safetyMargin + retrievalReserve + framingOverhead + inputTokens
        if totalReserved > hard {
            throw AttacheBudgetFailure.protectedContentOverflow(
                userDraft: currentUserInput,
                requestedTokens: totalReserved,
                hardLimit: hard
            )
        }

        let afterReserves = hard - totalReserved
        let multiplier = strategyMultiplier(strategy.kind)
        let evidenceBudget = max(0, Int(Double(afterReserves) * multiplier))

        return AttacheContextBudgetPlan(
            effectiveHardLimit: hard,
            outputReserve: outputReserve,
            toolReserve: toolReserve,
            safetyMargin: safetyMargin,
            retrievalReserve: retrievalReserve,
            framingOverhead: framingOverhead,
            currentUserInputTokens: inputTokens,
            remainingEvidenceBudget: evidenceBudget,
            strategy: strategy,
            unknownCapacity: unknownCapacity,
            estimatorFamily: estimator.family,
            estimatorVersion: estimator.version
        )
    }

    /// Cap a default reserve to a fraction of the hard limit so small models
    /// never over-reserve, with a minimum floor so the reserve stays useful.
    static func capped(_ defaultValue: Int, limit: Int, divisor: Int) -> Int {
        let proportional = max(128, limit / divisor)
        return min(defaultValue, proportional)
    }

    static func strategyMultiplier(_ kind: AttacheContextStrategyKind) -> Double {
        switch kind {
        case .efficient: return efficientMultiplier
        case .automatic: return automaticMultiplier
        case .maximumCoverage: return maximumCoverageMultiplier
        case .custom: return maximumCoverageMultiplier // custom uses its own reserves; evidence gets the full remainder
        }
    }

    static func defaultOutputReserve(role: AttacheRequestRole) -> Int {
        switch role {
        case .conversation, .liveFollowUp: return 2_048
        case .recap: return 3_072
        case .presentation, .anotherTake, .preview, .followUp, .topicTagging: return 1_536
        }
    }

    static func defaultToolReserve(role: AttacheRequestRole) -> Int {
        switch role {
        case .conversation: return 4_096
        default: return 1_024
        }
    }

    static func defaultRetrievalReserve(role: AttacheRequestRole) -> Int {
        switch role {
        case .conversation, .liveFollowUp: return 6_144
        case .recap, .followUp: return 2_048
        default: return 1_024
        }
    }

    /// Per-message framing overhead (role/name tags, separators) plus a small
    /// conservative constant. Scales slightly with role complexity.
    static func framingOverhead(role: AttacheRequestRole) -> Int {
        switch role {
        case .conversation: return 64
        case .recap: return 48
        default: return 32
        }
    }

    /// Safety margin scales with capability confidence: unknown or guessed
    /// capacity gets a larger margin; authoritative provider facts get a small
    /// one (INF-309).
    static func safetyMargin(for capability: AttacheModelCapabilityProfile) -> Int {
        switch capability.confidence {
        case .authoritative: return 256
        case .observed: return 512
        case .inferred: return 1_024
        case .guessed, .unknown: return 2_048
        }
    }
}