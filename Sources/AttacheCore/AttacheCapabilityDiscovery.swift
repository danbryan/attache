import Foundation

/// Pure, provider-specific capability parsers (INF-308). Each takes raw
/// provider metadata (already fetched by the App, never via an inference call)
/// and emits the INF-305 `AttacheModelCapabilityProfile`. Parsers are tolerant
/// of added fields and strict about malformed numeric limits: a bad value is
/// dropped to unknown rather than trusted. No parser sends a prompt, incurs
/// inference, or logs credentials or response content.
public enum AttacheCapabilityParser {
    /// Bumped when a parser's field mapping changes, so cache lineage can fork.
    public static let parserVersion = 1

    /// Reject implausible context-window values: non-positive, or above 100M
    /// tokens (no current model ships a window that large). Returns nil so the
    /// caller records unknown instead of trusting a corrupt field.
    public static func sanitizeContextWindow(_ value: Int?) -> Int? {
        guard let value, value > 0, value <= 100_000_000 else { return nil }
        return value
    }

    public static func sanitizeOutputLimit(_ value: Int?) -> Int? {
        guard let value, value > 0, value <= 10_000_000 else { return nil }
        return value
    }

    /// JSONSerialization may surface an untrusted numeric field as `Double`.
    /// A direct `Int(double)` traps for non-finite or out-of-range values, so
    /// capability metadata must use an exact, failable conversion before the
    /// normal plausibility bounds are applied.
    static func integerValue(_ value: Any?) -> Int? {
        if value is Bool { return nil }
        if let integer = value as? Int { return integer }
        guard let double = value as? Double,
              double.isFinite else { return nil }
        return Int(exactly: double)
    }

    // MARK: - Codex local model cache

    /// Parse a Codex local model-cache entry. Expected shape (fields optional):
    /// `context_window`, `slug`/`fingerprint`, `reasoning_levels`, `max_output_tokens`,
    /// `fetched_at` (epoch or ISO8601). Missing fields surface as unknown.
    public static func parseCodexCache(_ json: [String: Any]) -> AttacheModelCapabilityProfile? {
        let context = sanitizeContextWindow(integerValue(json["context_window"]))
        let output = sanitizeOutputLimit(integerValue(json["max_output_tokens"]))
        let reasoningLevels = (json["reasoning_levels"] as? [String]) ?? []
        let supportsReasoning = !reasoningLevels.isEmpty
        let fingerprint = (json["fingerprint"] as? String) ?? (json["slug"] as? String)
        _ = fingerprint // callers key the cache by ModelIdentity, which carries the fingerprint
        let freshness = parseDate(json["fetched_at"])
        return AttacheModelCapabilityProfile(
            architecturalMaximum: context,
            configuredRuntimeLimit: nil,
            outputLimit: output,
            estimatorFamily: nil,
            supportsReasoning: supportsReasoning,
            reasoningLevels: reasoningLevels,
            freshness: freshness,
            confidence: context != nil ? .authoritative : .unknown,
            provenance: .localCache
        )
    }

    // MARK: - Ollama /api/show + /api/ps

    /// Parse Ollama's `/api/show` (and optional `/api/ps`) into a capability
    /// profile. Distinguishes the architectural maximum (from `model_info`
    /// context_length) from the configured `num_ctx` (from `parameters`).
    /// `/api/ps` confirms a model is loaded; the configured `num_ctx` is the
    /// live runtime limit when loaded. Reasoning support is unknown unless the
    /// metadata establishes it, never fabricated from a model name.
    public static func parseOllama(
        show: [String: Any],
        ps: [String: Any]? = nil,
        now: Date = Date()
    ) -> AttacheModelCapabilityProfile? {
        let modelInfo = show["model_info"] as? [String: Any] ?? [:]
        let architectural = sanitizeContextWindow(ollamaContextLength(from: modelInfo))
        let configured = sanitizeContextWindow(ollamaNumCtx(from: show))
        let output = sanitizeOutputLimit((modelInfo["llama.max_output_tokens"] as? Int))
        let loaded = ollamaIsLoaded(modelName: show["name"] as? String, ps: ps)
        // The effective runtime limit is the configured num_ctx when the model
        // is loaded; otherwise the architectural ceiling stands alone.
        let runtimeLimit: Int? = loaded ? configured : configured
        let estimator = ollamaEstimatorFamily(from: modelInfo, details: show["details"] as? [String: Any])
        return AttacheModelCapabilityProfile(
            architecturalMaximum: architectural,
            configuredRuntimeLimit: runtimeLimit,
            outputLimit: output,
            estimatorFamily: estimator,
            supportsReasoning: false,
            reasoningLevels: [],
            freshness: now,
            confidence: architectural != nil ? .observed : .unknown,
            provenance: .providerMetadata
        )
    }

    static func ollamaContextLength(from modelInfo: [String: Any]) -> Int? {
        // Ollama nests architecture under keys like "llama.context_length".
        for (key, value) in modelInfo where key.hasSuffix(".context_length") {
            if let n = integerValue(value) { return n }
        }
        return integerValue(modelInfo["context_length"])
    }

    /// Ollama's `parameters` field is a string like "num_ctx 8192\nnum_batch 512".
    static func ollamaNumCtx(from show: [String: Any]) -> Int? {
        if let n = integerValue(show["num_ctx"]) { return n }
        guard let parameters = show["parameters"] as? String else { return nil }
        for line in parameters.components(separatedBy: .newlines) {
            let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces)
            if parts.count >= 2, parts[0] == "num_ctx", let n = Int(parts[1]) { return n }
        }
        return nil
    }

    static func ollamaIsLoaded(modelName: String?, ps: [String: Any]?) -> Bool {
        guard let modelName, let ps else { return false }
        let models = (ps["models"] as? [[String: Any]]) ?? []
        return models.contains { ($0["name"] as? String) == modelName }
    }

    static func ollamaEstimatorFamily(from modelInfo: [String: Any], details: [String: Any]?) -> String? {
        if let family = (details?["family"] as? String), !family.isEmpty {
            return "ollama-\(family)"
        }
        for (key, _) in modelInfo where key.hasPrefix("llama.") { return "ollama-llama" }
        return nil
    }

    // MARK: - Hosted model-list entries (xAI, Groq, custom OpenAI-compatible)

    /// Parse a hosted model-list entry. Tolerant of added fields; unknown when
    /// the provider does not publish limits or reasoning levels. Expected shape:
    /// `id`, `context_window`/`max_context`, `supported_reasoning_efforts`,
    /// `max_output_tokens`/`max_completion_tokens`.
    public static func parseHostedModel(_ json: [String: Any], now: Date = Date()) -> AttacheModelCapabilityProfile? {
        let context = sanitizeContextWindow(
            integerValue(json["context_window"])
                ?? integerValue(json["max_context"])
        )
        let output = sanitizeOutputLimit(
            integerValue(json["max_output_tokens"])
                ?? integerValue(json["max_completion_tokens"])
        )
        let reasoningLevels = (json["supported_reasoning_efforts"] as? [String]) ?? []
        let supportsReasoning = !reasoningLevels.isEmpty
        return AttacheModelCapabilityProfile(
            architecturalMaximum: context,
            configuredRuntimeLimit: nil,
            outputLimit: output,
            estimatorFamily: nil,
            supportsReasoning: supportsReasoning,
            reasoningLevels: reasoningLevels,
            freshness: now,
            confidence: context != nil || supportsReasoning ? .authoritative : .unknown,
            provenance: .providerMetadata
        )
    }

    /// Parse a date from an epoch number or an ISO8601 string.
    static func parseDate(_ value: Any?) -> Date? {
        if let n = value as? Double { return Date(timeIntervalSince1970: n) }
        if let n = value as? Int { return Date(timeIntervalSince1970: TimeInterval(n)) }
        if let s = value as? String {
            return ISO8601DateFormatter().date(from: s)
        }
        return nil
    }
}

/// A cached capability record: the profile plus when it was recorded and the
/// parser version that produced it, so staleness and lineage forks are visible.
public struct AttacheCapabilityCacheRecord: Equatable, Codable, Sendable {
    /// The exact identity that produced this record. Older caches decode this
    /// as nil and continue to work through their dictionary key.
    public let identity: ModelIdentity?
    public let profile: AttacheModelCapabilityProfile
    public let recordedAt: Date
    public let parserVersion: Int

    public init(
        identity: ModelIdentity? = nil,
        profile: AttacheModelCapabilityProfile,
        recordedAt: Date,
        parserVersion: Int
    ) {
        self.identity = identity
        self.profile = profile
        self.recordedAt = recordedAt
        self.parserVersion = parserVersion
    }

    public func isStale(olderThan maxAge: TimeInterval, now: Date = Date()) -> Bool {
        now.timeIntervalSince(recordedAt) > maxAge
    }
}

/// A thread-safe cache of discovered capability profiles keyed by
/// `ModelIdentity.capabilityKey` (normalized endpoint + resolved model +
/// fingerprint), so two endpoints serving the same model name never share
/// cached facts (INF-308). Offline reads return the last known record, visibly
/// stale; a fingerprint or endpoint change is a different key, so stale
/// assumptions are never retained across an alias change.
public final class AttacheCapabilityCache: @unchecked Sendable {
    private var records: [String: AttacheCapabilityCacheRecord] = [:]
    private let lock = NSRecursiveLock()

    public init() {}

    public func record(identity: ModelIdentity, profile: AttacheModelCapabilityProfile, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        records[identity.capabilityKey] = AttacheCapabilityCacheRecord(
            identity: identity,
            profile: profile,
            recordedAt: now,
            parserVersion: AttacheCapabilityParser.parserVersion
        )
    }

    public func profile(for identity: ModelIdentity) -> AttacheModelCapabilityProfile? {
        lock.lock(); defer { lock.unlock() }
        return records[identity.capabilityKey]?.profile
    }

    public func record(for identity: ModelIdentity) -> AttacheCapabilityCacheRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[identity.capabilityKey]
    }

    /// Resolve a user's provider/endpoint/model selection to the newest exact
    /// discovered identity. This is what carries an Ollama digest from model
    /// discovery into a later frozen inference attempt. A changed digest is a
    /// different identity and cannot inherit the prior model's facts.
    public func resolvedRecord(
        for selection: ModelIdentity
    ) -> (identity: ModelIdentity, record: AttacheCapabilityCacheRecord)? {
        lock.lock(); defer { lock.unlock() }
        let candidates: [(identity: ModelIdentity, record: AttacheCapabilityCacheRecord)] = records.values.compactMap { record in
            guard let identity = record.identity,
                  identity.provider == selection.provider,
                  identity.normalizedEndpoint == selection.normalizedEndpoint,
                  identity.requestedModel == selection.requestedModel,
                  identity.resolvedModel == selection.resolvedModel else {
                return nil
            }
            return (identity: identity, record: record)
        }
        let discovered = candidates.max {
            $0.record.recordedAt < $1.record.recordedAt
        }
        if let discovered { return discovered }
        if let legacy = records[selection.capabilityKey] {
            return (legacy.identity ?? selection, legacy)
        }
        return nil
    }

    public func invalidate(for identity: ModelIdentity) {
        lock.lock(); defer { lock.unlock() }
        records.removeValue(forKey: identity.capabilityKey)
    }

    /// True when a cached record exists for this identity and is not stale.
    public func hasFresh(identity: ModelIdentity, maxAge: TimeInterval, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let record = records[identity.capabilityKey] else { return false }
        return !record.isStale(olderThan: maxAge, now: now)
    }

    public func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return records.count
    }

    /// Content-free snapshot for a local last-known cache. Keys contain only
    /// normalized endpoint/model identity and values contain numeric capability
    /// metadata, never prompts, API keys, or response bodies.
    public func snapshot() -> [String: AttacheCapabilityCacheRecord] {
        lock.lock(); defer { lock.unlock() }
        return records
    }

    /// Restore only records produced by the current parser lineage. Endpoint,
    /// alias, and fingerprint isolation remains encoded in each dictionary key.
    public func restore(_ persisted: [String: AttacheCapabilityCacheRecord]) {
        lock.lock(); defer { lock.unlock() }
        records = persisted.filter {
            $0.value.parserVersion == AttacheCapabilityParser.parserVersion
        }
    }
}
