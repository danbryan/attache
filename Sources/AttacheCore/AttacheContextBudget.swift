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

/// A conservative, tokenizer-independent fallback estimator (INF-309).
/// Ordinary lowercase prose keeps a four-characters-per-token baseline, while
/// token-dense material uses a much stricter envelope: non-ASCII scalars count
/// their UTF-8 bytes, punctuation counts individually, and mixed-case,
/// alphanumeric, base64-shaped, and long high-variety identifiers count one per
/// byte. This avoids the dangerous undercount from applying a prose heuristic
/// to minified JSON, URLs, random identifiers, emoji sequences, and non-Latin
/// scripts without reducing every prose budget to one quarter of capacity.
public struct AttacheFallbackTokenEstimator: TokenEstimating {
    public let family = "unicode-fallback"
    public let version = 2

    public init() {}

    public func estimate(text: String) -> Int {
        var tokens = 0
        var runCount = 0
        var runIsAllLowercase = true
        var runIsAllDigits = true
        var lowercaseVariety: Set<UInt8> = []
        var whitespaceCount = 0

        func flushRun() {
            guard runCount > 0 else { return }
            if runIsAllLowercase {
                let highVarietyLongIdentifier = runCount >= 12 && lowercaseVariety.count > 4
                tokens += highVarietyLongIdentifier ? runCount : (runCount + 3) / 4
            } else if runIsAllDigits {
                // Common tokenizers split long decimal strings into groups no
                // larger than about three digits.
                tokens += (runCount + 2) / 3
            } else {
                // Mixed case or letters plus digits are code/base64/identifier
                // shaped. One token per byte is the conservative fallback.
                tokens += runCount
            }
            runCount = 0
            runIsAllLowercase = true
            runIsAllDigits = true
            lowercaseVariety.removeAll(keepingCapacity: true)
        }

        func flushWhitespace() {
            guard whitespaceCount > 0 else { return }
            tokens += (whitespaceCount + 3) / 4
            whitespaceCount = 0
        }

        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value <= 0x7F {
                let byte = UInt8(value)
                let isAlphaNumeric = (byte >= 0x30 && byte <= 0x39)
                    || (byte >= 0x41 && byte <= 0x5A)
                    || (byte >= 0x61 && byte <= 0x7A)
                if isAlphaNumeric {
                    flushWhitespace()
                    runCount += 1
                    let isLowercase = byte >= 0x61 && byte <= 0x7A
                    let isDigit = byte >= 0x30 && byte <= 0x39
                    runIsAllLowercase = runIsAllLowercase && isLowercase
                    runIsAllDigits = runIsAllDigits && isDigit
                    if isLowercase, lowercaseVariety.count <= 4 {
                        lowercaseVariety.insert(byte)
                    }
                } else if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                    flushRun()
                    whitespaceCount += 1
                } else {
                    flushRun()
                    flushWhitespace()
                    tokens += 1
                }
            } else {
                flushRun()
                flushWhitespace()
                tokens += scalar.utf8.count
            }
        }
        flushRun()
        flushWhitespace()
        return tokens
    }
}

/// A conservative calibrated estimator (INF-318). Calibration may only raise
/// a base estimate. It never changes a provider hard limit and production does
/// not apply it to Custom policies.
public struct AttacheCalibratedTokenEstimator: TokenEstimating {
    public let family: String
    public let version: Int
    private let base: any TokenEstimating
    private let correction: AttacheCalibrationCorrection

    public init(
        base: any TokenEstimating,
        correction: AttacheCalibrationCorrection
    ) {
        self.base = base
        self.correction = correction
        family = "\(base.family)+calibrated"
        version = base.version
    }

    public func estimate(text: String) -> Int {
        AttacheTokenUsageCalibrator.applyCorrection(
            estimate: base.estimate(text: text),
            correction: correction
        )
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
        [
            outputReserve, toolReserve, safetyMargin, retrievalReserve,
            framingOverhead, currentUserInputTokens
        ].reduce(0) { partial, value in
            let result = partial.addingReportingOverflow(value)
            return result.overflow ? Int.max : result.partialValue
        }
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
        protectedContentText: String = "",
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
        let customWorkingCap = (strategy.kind == .custom ? strategy.custom?.effectiveInputLimit : nil)
        let mergedCeiling: Int? = {
            [capabilityCeiling, customHardCap, customWorkingCap]
                .compactMap { $0 }
                .min()
        }()
        let effectiveHardLimit: Int? = mergedCeiling ?? (unknownCapacity ? unknownCapacityEnvelope : nil)

        let toolDefinitionTokens = estimator.estimate(text: toolDefinitionsText)
        let bridgeTokens = estimator.estimate(text: bridgeWrapperText)
        let protectedContentTokens = estimator.estimate(text: protectedContentText)

        // Reserves are proportionally capped by the effective hard limit so they
        // never exceed it on a small model (INF-309: "never reserve beyond the
        // hard limit"). Custom uses the user's validated values.
        let limit = effectiveHardLimit ?? Int.max
        let outputReserve: Int
        var toolReserve: Int
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
        // Provider-bound wrappers and protected prompts are measured, not
        // capped. Capping these values made a giant tool schema appear small
        // enough to send even though the serialized request exceeded the
        // model's declared limit.
        let framingOverhead = framingOverhead(role: role)
            + toolDefinitionTokens
            + bridgeTokens
            + protectedContentTokens
        var retrievalReserve = Self.capped(Self.defaultRetrievalReserve(role: role), limit: limit, divisor: 4)

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
        var totalReserved = 0
        var reserveArithmeticOverflow = false
        for value in [
            outputReserve, toolReserve, safetyMargin, retrievalReserve,
            framingOverhead, inputTokens
        ] {
            let result = totalReserved.addingReportingOverflow(value)
            if result.overflow {
                reserveArithmeticOverflow = true
                totalReserved = Int.max
                break
            }
            totalReserved = result.partialValue
        }
        // Named strategies treat retrieval and tool-result room as elastic.
        // Protected prompts, the current user turn, output room, and the safety
        // margin must fit first. This keeps an otherwise ordinary request from
        // failing merely because conservative prospective reserves overlap on
        // a small or unknown-capacity model. Custom reserves remain exact.
        if !reserveArithmeticOverflow,
           totalReserved > hard,
           strategy.kind != .custom {
            let reserveFloor = 128
            let retrievalReduction = min(
                totalReserved - hard,
                max(retrievalReserve - reserveFloor, 0)
            )
            retrievalReserve -= retrievalReduction
            totalReserved -= retrievalReduction

            let toolReduction = min(
                max(totalReserved - hard, 0),
                max(toolReserve - reserveFloor, 0)
            )
            toolReserve -= toolReduction
            totalReserved -= toolReduction
        }
        if reserveArithmeticOverflow || totalReserved > hard {
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
