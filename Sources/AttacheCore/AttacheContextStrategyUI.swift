import Foundation

/// User-facing descriptions for each context strategy (INF-313). Plain language
/// so ordinary users never need to understand tokenization to use Automatic.
public enum AttacheContextStrategyDescription {
    public static func title(_ kind: AttacheContextStrategyKind) -> String {
        switch kind {
        case .automatic: return "Automatic"
        case .maximumCoverage: return "Maximum coverage"
        case .efficient: return "Efficient"
        case .custom: return "Custom"
        }
    }

    public static func explanation(_ kind: AttacheContextStrategyKind) -> String {
        switch kind {
        case .automatic:
            return "Attaché balances evidence and speed automatically. No tuning needed."
        case .maximumCoverage:
            return "Attaché uses more relevant raw evidence and staged verification when useful. It does not promise to send everything."
        case .efficient:
            return "Attaché prefers compact evidence for speed and local-model limits."
        case .custom:
            return "Advanced: set your own input limits, reserves, and evidence preferences."
        }
    }

    /// True when the strategy requires numeric decisions (only Custom).
    public static func requiresNumericControls(_ kind: AttacheContextStrategyKind) -> Bool {
        kind == .custom
    }
}

/// A formatted capability summary for the advanced view (INF-313). Distinguishes
/// detected, stale, unknown, and overridden values. Pure and content-free.
public struct AttacheCapabilitySummary: Equatable, Sendable {
    public let effectiveCapacityLabel: String
    public let reasoningSupportLabel: String
    public let sourceLabel: String
    public let freshnessLabel: String
    public let isStale: Bool
    public let isUnknown: Bool
    public let isOverridden: Bool

    public init(
        effectiveCapacityLabel: String, reasoningSupportLabel: String,
        sourceLabel: String, freshnessLabel: String,
        isStale: Bool, isUnknown: Bool, isOverridden: Bool
    ) {
        self.effectiveCapacityLabel = effectiveCapacityLabel
        self.reasoningSupportLabel = reasoningSupportLabel
        self.sourceLabel = sourceLabel
        self.freshnessLabel = freshnessLabel
        self.isStale = isStale
        self.isUnknown = isUnknown
        self.isOverridden = isOverridden
    }

    /// Build a summary from a detected capability profile and an optional
    /// user override (INF-313).
    public static func from(
        detected: AttacheModelCapabilityProfile,
        override: AttacheContextCustomPolicy? = nil,
        maxStaleness: TimeInterval = 86_400 * 7,
        now: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> AttacheCapabilitySummary {
        let capacity: String
        if let ceiling = detected.declaredInputCeiling {
            capacity = "\(ceiling) tokens"
        } else {
            capacity = "Unknown"
        }
        let reasoning: String
        if detected.supportsReasoning {
            reasoning = detected.reasoningLevels.isEmpty ? "Supported" : "Levels: \(detected.reasoningLevels.joined(separator: ", "))"
        } else if detected.confidence == .unknown {
            reasoning = "Unknown"
        } else {
            reasoning = "Not supported"
        }
        let source: String
        switch detected.provenance {
        case .providerMetadata: source = "Provider metadata"
        case .runtimeObservation: source = "Runtime observation"
        case .localCache: source = "Local model cache"
        case .explicitUserOverride: source = "Your Custom limits"
        case .curatedFallback: source = "Verified model catalog"
        case .unknown: source = "Not reported"
        }
        let freshness: String
        if let date = detected.freshness {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            freshness = formatter.string(from: date)
        } else {
            freshness = "No timestamp"
        }
        return AttacheCapabilitySummary(
            effectiveCapacityLabel: capacity,
            reasoningSupportLabel: reasoning,
            sourceLabel: source,
            freshnessLabel: freshness,
            isStale: detected.isStale(olderThan: maxStaleness, now: now),
            isUnknown: detected.isUnknown,
            isOverridden: override != nil
        )
    }
}

/// A pure view model for context strategy selection and custom policy editing
/// (INF-313). Handles selecting a strategy kind, editing custom values,
/// validating, resetting the override, and resolving the effective strategy.
public struct ContextStrategyViewModel: Equatable, Sendable {
    public private(set) var selectedKind: AttacheContextStrategyKind
    public private(set) var customPolicy: AttacheContextCustomPolicy
    public private(set) var validationError: AttacheContextPolicyError?
    public let globalDefault: AttacheContextStrategy

    public init(globalDefault: AttacheContextStrategy = .automatic) {
        self.selectedKind = globalDefault.kind
        self.customPolicy = globalDefault.custom ?? AttacheContextCustomPolicy()
        self.validationError = nil
        self.globalDefault = globalDefault
    }

    /// Select a strategy kind. Switching away from Custom clears the validation
    /// error; switching to Custom validates immediately.
    public mutating func select(_ kind: AttacheContextStrategyKind) {
        selectedKind = kind
        if kind == .custom {
            validate()
        } else {
            validationError = nil
        }
    }

    /// Update a custom policy field and re-validate.
    public mutating func updateCustom(_ policy: AttacheContextCustomPolicy) {
        customPolicy = policy
        validate()
    }

    /// Reset to the global default (removes the per-personality override).
    public mutating func reset() {
        selectedKind = globalDefault.kind
        customPolicy = globalDefault.custom ?? AttacheContextCustomPolicy()
        validationError = nil
    }

    /// The resolved strategy for this personality. Returns nil when the model
    /// is Custom but validation has not passed, so the caller cannot save an
    /// invalid policy (INF-313).
    public var resolvedStrategy: AttacheContextStrategy? {
        guard selectedKind != .custom else {
            guard validationError == nil else { return nil }
            return AttacheContextStrategy(.custom, custom: customPolicy)
        }
        return AttacheContextStrategy(selectedKind)
    }

    /// True when the current state can be saved (no validation error).
    public var canSave: Bool { validationError == nil }

    /// Validate the custom policy and store any error.
    public mutating func validate() {
        do {
            try customPolicy.validate()
            validationError = nil
        } catch let error as AttacheContextPolicyError {
            validationError = error
        } catch {
            validationError = nil
        }
    }
}
