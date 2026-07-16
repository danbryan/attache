import Foundation

// MARK: - Model identity

/// Identifies one concrete model endpoint precisely enough that capability
/// data is never shared across aliases, endpoints, or provider defaults
/// (INF-305). Two identities are equal only when provider, normalized
/// endpoint, resolved model, and fingerprint all agree.
public struct ModelIdentity: Equatable, Hashable, Codable, Sendable {
    /// Normalized provider id, e.g. "ollama", "openai", "anthropic". Lowercased
    /// and trimmed so alias spellings collapse to one authority.
    public let provider: String
    /// Canonical base URL for the endpoint, or "" for non-HTTP providers. Two
    /// providers on different endpoints must never share capability even if the
    /// model name matches.
    public let normalizedEndpoint: String
    /// The model the user selected, before any provider-side alias resolution.
    public let requestedModel: String
    /// The concrete model the provider resolved the request to. Defaults to the
    /// requested model when no aliasing occurred.
    public let resolvedModel: String
    /// A provider fingerprint or version string when available, so a rebranded
    /// or re-versioned model does not inherit another's capability.
    public let fingerprint: String?

    public init(
        provider: String,
        normalizedEndpoint: String,
        requestedModel: String,
        resolvedModel: String? = nil,
        fingerprint: String? = nil
    ) {
        self.provider = ModelIdentity.normalize(provider)
        self.normalizedEndpoint = ModelIdentity.normalizeEndpoint(normalizedEndpoint)
        self.requestedModel = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.resolvedModel = (resolvedModel ?? requestedModel).trimmingCharacters(in: .whitespacesAndNewlines)
        self.fingerprint = fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// A stable key for capability lookup. Endpoint + resolved model + fingerprint
    /// so the same model on a different endpoint (a self-hosted mirror) does not
    /// inherit the upstream provider's measured capability.
    public var capabilityKey: String {
        let fp = fingerprint?.nilIfEmpty.map { "|\($0)" } ?? ""
        return "\(provider)@\(normalizedEndpoint)|\(resolvedModel)\(fp)"
    }

    public static func == (lhs: ModelIdentity, rhs: ModelIdentity) -> Bool {
        lhs.provider == rhs.provider
            && lhs.normalizedEndpoint == rhs.normalizedEndpoint
            && lhs.resolvedModel == rhs.resolvedModel
            && lhs.fingerprint?.nilIfEmpty == rhs.fingerprint?.nilIfEmpty
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(provider)
        hasher.combine(normalizedEndpoint)
        hasher.combine(resolvedModel)
        hasher.combine(fingerprint?.nilIfEmpty)
    }

    static func normalize(_ provider: String) -> String {
        provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func normalizeEndpoint(_ endpoint: String) -> String {
        var text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("/") { text.removeLast() }
        return text.lowercased()
    }
}

// MARK: - Provenance and confidence

/// Where a capability fact came from. Kept distinct from the fact itself so a
/// guessed number is never disguised as a provider fact (INF-305).
public enum AttacheCapabilityProvenance: String, Codable, Equatable, Sendable, CaseIterable {
    case runtimeObservation
    case providerMetadata
    case localCache
    case explicitUserOverride
    case curatedFallback
    case unknown
}

/// How trustworthy a capability fact is. `unknown`/`guessed` must surface
/// honestly to the user and the compiler.
public enum AttacheCapabilityConfidence: String, Codable, Equatable, Sendable, CaseIterable {
    case authoritative
    case observed
    case inferred
    case guessed
    case unknown
}

// MARK: - Detected capability profile

/// The detected, read-only capability record for one model. This is observed
/// fact, not user policy. Runtime/provider facts can never overwrite Custom
/// policy, and Custom policy can never overwrite this record (INF-305).
public struct AttacheModelCapabilityProfile: Equatable, Codable, Sendable {
    public static let unknown = AttacheModelCapabilityProfile(
        architecturalMaximum: nil,
        configuredRuntimeLimit: nil,
        outputLimit: nil,
        estimatorFamily: nil,
        supportsReasoning: false,
        reasoningLevels: [],
        freshness: nil,
        confidence: .unknown,
        provenance: .unknown
    )

    /// Architectural maximum context window in tokens. `nil` means unknown.
    public let architecturalMaximum: Int?
    /// A configured runtime cap the provider enforces, if any.
    public let configuredRuntimeLimit: Int?
    /// Maximum output tokens the model can produce in one response.
    public let outputLimit: Int?
    /// Tokenizer/estimator family name, e.g. "tiktoken-cl100k", "llama3".
    public let estimatorFamily: String?
    /// Whether the provider supports reasoning-effort controls.
    public let supportsReasoning: Bool
    /// Named reasoning levels the provider accepts, when known.
    public let reasoningLevels: [String]
    /// When this evidence was gathered or last confirmed.
    public let freshness: Date?
    public let confidence: AttacheCapabilityConfidence
    public let provenance: AttacheCapabilityProvenance

    public init(
        architecturalMaximum: Int?,
        configuredRuntimeLimit: Int? = nil,
        outputLimit: Int? = nil,
        estimatorFamily: String? = nil,
        supportsReasoning: Bool = false,
        reasoningLevels: [String] = [],
        freshness: Date? = nil,
        confidence: AttacheCapabilityConfidence = .unknown,
        provenance: AttacheCapabilityProvenance = .unknown
    ) {
        self.architecturalMaximum = architecturalMaximum
        self.configuredRuntimeLimit = configuredRuntimeLimit
        self.outputLimit = outputLimit
        self.estimatorFamily = estimatorFamily
        self.supportsReasoning = supportsReasoning
        self.reasoningLevels = reasoningLevels
        self.freshness = freshness
        self.confidence = confidence
        self.provenance = provenance
    }

    /// Unknown capacity is represented explicitly, never as a guessed number.
    public var isUnknown: Bool {
        architecturalMaximum == nil && configuredRuntimeLimit == nil
    }

    /// True when the evidence is too old to trust without re-checking. A nil
    /// freshness is never stale (it has no expiry to check).
    public func isStale(olderThan maxAge: TimeInterval, now: Date = Date()) -> Bool {
        guard let freshness else { return false }
        return now.timeIntervalSince(freshness) > maxAge
    }

    /// The architectural ceiling after any provider runtime cap. `nil` when
    /// neither is known, so callers must treat it as unknown rather than zero.
    public var declaredInputCeiling: Int? {
        guard let max = architecturalMaximum else { return configuredRuntimeLimit }
        guard let runtime = configuredRuntimeLimit else { return max }
        return min(max, runtime)
    }
}

// MARK: - Strategies

public enum AttacheContextStrategyKind: String, Codable, Equatable, Sendable, CaseIterable {
    case automatic
    case maximumCoverage
    case efficient
    case custom
}

/// One context strategy. `automatic` is the no-knobs default; `maximumCoverage`
/// and `efficient` are named presets; `custom` carries explicit limits. All four
/// serialize and round-trip (INF-305).
public struct AttacheContextStrategy: Equatable, Codable, Sendable {
    public let kind: AttacheContextStrategyKind
    /// Only meaningful for `.custom`; `nil` for the named presets.
    public let custom: AttacheContextCustomPolicy?

    public init(_ kind: AttacheContextStrategyKind, custom: AttacheContextCustomPolicy? = nil) {
        self.kind = kind
        self.custom = kind == .custom ? custom : nil
    }

    public static let automatic = AttacheContextStrategy(.automatic)
    public static let maximumCoverage = AttacheContextStrategy(.maximumCoverage)
    public static let efficient = AttacheContextStrategy(.efficient)

    /// Resolve a per-personality override against the global default. A
    /// personality that does not set a strategy falls back to the global one
    /// (INF-305). An override of `.automatic` is honored, not treated as nil.
    public static func resolving(override: AttacheContextStrategy?, global: AttacheContextStrategy) -> AttacheContextStrategy {
        override ?? global
    }
}

// MARK: - Custom policy

/// User-controlled context limits. These are policy, not detected fact: they
/// override how detected capacity is used but never replace the detected record.
/// Invalid combinations are rejected with an actionable message (INF-305).
public struct AttacheContextCustomPolicy: Equatable, Codable, Sendable {
    /// Hard cap on input tokens. `nil` means use the detected ceiling.
    public var hardInputLimit: Int?
    /// A softer working limit below the hard cap. `nil` means derive from hard.
    public var effectiveInputLimit: Int?
    /// Tokens reserved for model output.
    public var outputReserve: Int
    /// Tokens reserved for tool results that may be appended mid-turn.
    public var toolReserve: Int
    /// Safety margin kept below the effective limit so the request never sits
    /// exactly at the provider ceiling.
    public var safetyMargin: Int
    public var evidencePreferences: AttacheEvidencePreferences
    public var stagedThresholds: AttacheStagedThresholds

    public init(
        hardInputLimit: Int? = nil,
        effectiveInputLimit: Int? = nil,
        outputReserve: Int = 4_096,
        toolReserve: Int = 4_096,
        safetyMargin: Int = 512,
        evidencePreferences: AttacheEvidencePreferences = AttacheEvidencePreferences(),
        stagedThresholds: AttacheStagedThresholds = AttacheStagedThresholds()
    ) {
        self.hardInputLimit = hardInputLimit
        self.effectiveInputLimit = effectiveInputLimit
        self.outputReserve = outputReserve
        self.toolReserve = toolReserve
        self.safetyMargin = safetyMargin
        self.evidencePreferences = evidencePreferences
        self.stagedThresholds = stagedThresholds
    }

    /// Validate that the policy is internally consistent. Throws an actionable
    /// `AttacheContextPolicyError` for negative/zero reserves, an effective limit
    /// above the hard limit, or reserves that overcommit the hard cap.
    public func validate() throws {
        if let hardInputLimit, hardInputLimit <= 0 {
            throw AttacheContextPolicyError.invalidLimit(field: "hardInputLimit", value: hardInputLimit)
        }
        if let effectiveInputLimit, effectiveInputLimit <= 0 {
            throw AttacheContextPolicyError.invalidLimit(field: "effectiveInputLimit", value: effectiveInputLimit)
        }
        if outputReserve < 0 {
            throw AttacheContextPolicyError.negativeReserve(field: "outputReserve", value: outputReserve)
        }
        if toolReserve < 0 {
            throw AttacheContextPolicyError.negativeReserve(field: "toolReserve", value: toolReserve)
        }
        if safetyMargin < 0 {
            throw AttacheContextPolicyError.negativeReserve(field: "safetyMargin", value: safetyMargin)
        }
        if outputReserve == 0 || toolReserve == 0 || safetyMargin == 0 {
            let zeroField = outputReserve == 0 ? "outputReserve" : (toolReserve == 0 ? "toolReserve" : "safetyMargin")
            throw AttacheContextPolicyError.zeroReserve(field: zeroField)
        }
        if let hard = hardInputLimit, let effective = effectiveInputLimit, effective > hard {
            throw AttacheContextPolicyError.effectiveExceedsHard(effective: effective, hard: hard)
        }
        let outputAndTools = outputReserve.addingReportingOverflow(toolReserve)
        let allReserves = outputAndTools.partialValue.addingReportingOverflow(safetyMargin)
        if outputAndTools.overflow || allReserves.overflow {
            throw AttacheContextPolicyError.reserveTotalOverflow
        }
        if let hard = hardInputLimit {
            let committed = allReserves.partialValue
            if committed >= hard {
                throw AttacheContextPolicyError.overcommittedReserves(committed: committed, hard: hard)
            }
        }
        try stagedThresholds.validate()
    }
}

/// What evidence the compiler should prefer when it must drop material.
public struct AttacheEvidencePreferences: Equatable, Codable, Sendable {
    /// Prefer recent exact turns over older summaries when both fit partially.
    public var preferRecentExactTurns: Bool
    /// Prefer condensed summaries over raw transcripts when space is tight.
    public var preferSummariesOverRaw: Bool
    /// Drop tool output before dropping user/assistant turns.
    public var dropToolOutputFirst: Bool

    public init(
        preferRecentExactTurns: Bool = true,
        preferSummariesOverRaw: Bool = false,
        dropToolOutputFirst: Bool = true
    ) {
        self.preferRecentExactTurns = preferRecentExactTurns
        self.preferSummariesOverRaw = preferSummariesOverRaw
        self.dropToolOutputFirst = dropToolOutputFirst
    }
}

/// When to switch from one-shot inclusion to staged/progressive processing.
public struct AttacheStagedThresholds: Equatable, Codable, Sendable {
    /// Character count above which a transcript is staged instead of inlined.
    public var stageTranscriptChars: Int
    /// Character count above which a project file is read progressively.
    public var stageFileChars: Int

    public init(stageTranscriptChars: Int = 24_000, stageFileChars: Int = 24_000) {
        self.stageTranscriptChars = stageTranscriptChars
        self.stageFileChars = stageFileChars
    }

    /// Thresholds must be positive; a zero/negative threshold would stage
    /// everything or nothing in a way the user did not ask for.
    public func validate() throws {
        if stageTranscriptChars <= 0 {
            throw AttacheContextPolicyError.invalidThreshold(field: "stageTranscriptChars", value: stageTranscriptChars)
        }
        if stageFileChars <= 0 {
            throw AttacheContextPolicyError.invalidThreshold(field: "stageFileChars", value: stageFileChars)
        }
    }
}

// MARK: - Errors

public enum AttacheContextPolicyError: Error, Equatable, LocalizedError {
    case invalidLimit(field: String, value: Int)
    case negativeReserve(field: String, value: Int)
    case zeroReserve(field: String)
    case effectiveExceedsHard(effective: Int, hard: Int)
    case overcommittedReserves(committed: Int, hard: Int)
    case reserveTotalOverflow
    case invalidThreshold(field: String, value: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidLimit(let field, let value):
            return "\(field) is \(value); context limits must be positive. Set a positive token count or leave it unset."
        case .negativeReserve(let field, let value):
            return "\(field) is \(value); reserves cannot be negative. Set it to a positive number of tokens."
        case .zeroReserve(let field):
            return "\(field) is 0; reserves must leave room for their purpose. Set it to a positive number of tokens."
        case .effectiveExceedsHard(let effective, let hard):
            return "effectiveInputLimit (\(effective)) is above hardInputLimit (\(hard)). Lower the effective limit or raise the hard cap."
        case .overcommittedReserves(let committed, let hard):
            return "output + tool + safety reserves (\(committed)) meet or exceed hardInputLimit (\(hard)). Lower a reserve or raise the hard cap."
        case .reserveTotalOverflow:
            return "output + tool + safety reserves are too large to calculate safely. Lower one or more reserves."
        case .invalidThreshold(let field, let value):
            return "\(field) is \(value); staging thresholds must be positive. Set a positive character count."
        }
    }
}

// MARK: - Effective merged profile

/// The merged, inspectable result of combining detected capability with user
/// policy under a strategy. Detected fact, user override, and the effective
/// merge are all kept separately inspectable (INF-305). Runtime/provider facts
/// never overwrite Custom values, and Custom values never overwrite the
/// detected record: this struct holds references to both originals untouched.
public struct AttacheEffectiveContextProfile: Equatable, Sendable {
    public let identity: ModelIdentity
    public let detected: AttacheModelCapabilityProfile
    public let strategy: AttacheContextStrategy
    /// The Custom override in effect, if the strategy is `.custom`.
    public let customOverride: AttacheContextCustomPolicy?

    /// The effective input budget in tokens, after applying the strategy and any
    /// Custom cap to the detected ceiling. `nil` means capacity is unknown and
    /// the compiler must treat the request as unbounded-but-uncertain.
    public var effectiveInputLimit: Int? {
        let ceiling = detected.declaredInputCeiling
        switch strategy.kind {
        case .automatic, .maximumCoverage, .efficient:
            return ceiling
        case .custom:
            guard let custom = customOverride else { return ceiling }
            let candidates: [Int] = [
                ceiling,
                custom.hardInputLimit,
                custom.effectiveInputLimit
            ].compactMap { $0 }
            return candidates.min()
        }
    }

    public var effectiveOutputReserve: Int {
        if strategy.kind == .custom, let custom = customOverride {
            return custom.outputReserve
        }
        // Named presets reserve a conservative default for output.
        return 4_096
    }

    public var effectiveToolReserve: Int {
        if strategy.kind == .custom, let custom = customOverride {
            return custom.toolReserve
        }
        return 4_096
    }

    public var effectiveSafetyMargin: Int {
        if strategy.kind == .custom, let custom = customOverride {
            return custom.safetyMargin
        }
        return 512
    }

    public init(
        identity: ModelIdentity,
        detected: AttacheModelCapabilityProfile,
        strategy: AttacheContextStrategy,
        customOverride: AttacheContextCustomPolicy? = nil
    ) {
        self.identity = identity
        self.detected = detected
        self.strategy = strategy
        self.customOverride = customOverride
    }

    /// Build an effective profile from detected fact plus a resolved strategy,
    /// validating any Custom policy. Detected fact and Custom override remain
    /// separately inspectable on the result.
    public static func merged(
        identity: ModelIdentity,
        detected: AttacheModelCapabilityProfile,
        strategy: AttacheContextStrategy
    ) throws -> AttacheEffectiveContextProfile {
        let override = strategy.kind == .custom ? strategy.custom : nil
        if let override {
            try override.validate()
        }
        return AttacheEffectiveContextProfile(
            identity: identity,
            detected: detected,
            strategy: strategy,
            customOverride: override
        )
    }
}

// MARK: - Persistence schema version

/// Versioned schema for the persisted context-policy payload so future detected
/// facts and user policy can migrate without changing behavior until the
/// compiler is adopted (INF-305).
public struct AttacheContextPolicyRecord: Equatable, Codable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let globalStrategy: AttacheContextStrategy

    public init(version: Int = AttacheContextPolicyRecord.currentVersion, globalStrategy: AttacheContextStrategy) {
        self.version = version
        self.globalStrategy = globalStrategy
    }

    /// Decode and migrate a record from persisted JSON. Unknown versions are
    /// returned as-is for the caller to decide; the current version passes
    /// through. This never raises a first-launch prompt.
    public static func migrate(_ data: Data) -> AttacheContextPolicyRecord? {
        guard let record = try? JSONDecoder().decode(AttacheContextPolicyRecord.self, from: data) else {
            return nil
        }
        return record
    }
}

// MARK: - String helper

extension String {
    /// Empty after trimming becomes nil. Internal to keep the public API tidy.
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
