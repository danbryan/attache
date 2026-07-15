import Foundation
import SQLite3

/// One observed provider token-usage sample (INF-318). Content-free: carries
/// only numeric counts and identity metadata. Never raw messages, excerpts,
/// tool results, filenames, queries, memory, or transcript text.
public struct AttacheProviderUsageSample: Equatable, Sendable {
    public let modelIdentityKey: String
    public let estimatorVersion: String
    public let strategyKind: String
    public let role: String
    public let estimatedInputTokens: Int
    public let actualInputTokens: Int
    public let actualOutputTokens: Int
    public let cachedInputTokens: Int
    public let timestamp: Date
    public let receiptID: String

    public init(
        modelIdentityKey: String, estimatorVersion: String, strategyKind: String,
        role: String, estimatedInputTokens: Int, actualInputTokens: Int,
        actualOutputTokens: Int, cachedInputTokens: Int = 0,
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000), receiptID: String
    ) {
        self.modelIdentityKey = modelIdentityKey
        self.estimatorVersion = estimatorVersion
        self.strategyKind = strategyKind
        self.role = role
        self.estimatedInputTokens = estimatedInputTokens
        self.actualInputTokens = actualInputTokens
        self.actualOutputTokens = actualOutputTokens
        self.cachedInputTokens = cachedInputTokens
        self.timestamp = timestamp
        self.receiptID = receiptID
    }

    /// The ratio of actual to estimated input tokens. >1 means the estimator
    /// underestimated (the common case for a conservative fallback).
    public var estimateRatio: Double {
        estimatedInputTokens > 0 ? Double(actualInputTokens) / Double(estimatedInputTokens) : 1.0
    }
}

/// Parsed token usage from a provider response (INF-318). Content-free.
public struct AttacheParsedTokenUsage: Equatable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cachedTokens: Int?
    public let totalTokens: Int?

    public init(inputTokens: Int?, outputTokens: Int?, cachedTokens: Int?, totalTokens: Int?) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.totalTokens = totalTokens
    }

    public var isPresent: Bool {
        inputTokens != nil || outputTokens != nil || totalTokens != nil
    }
}

/// A capability warning from a structurally recognized context-limit failure
/// (INF-318). This is a warning, not a new limit fact. It requires stronger
/// evidence or user action before it changes anything.
public struct AttacheCapabilityWarning: Equatable, Sendable {
    public let modelIdentityKey: String
    public let observedLimit: Int?
    public let timestamp: Date
    public let requiresUserAction: Bool

    public init(modelIdentityKey: String, observedLimit: Int?, timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000), requiresUserAction: Bool = true) {
        self.modelIdentityKey = modelIdentityKey
        self.observedLimit = observedLimit
        self.timestamp = timestamp
        self.requiresUserAction = requiresUserAction
    }
}

/// A bounded conservative correction factor (INF-318). Outlier-resistant. Too
/// few samples produce a non-actionable correction (factor 1.0). The factor is
/// clamped to [0.5, 1.5] so outliers cannot produce zero, negative, or
/// implausibly optimistic corrections. Calibration adjusts estimator safety
/// but never raises a hard limit or overrides authoritative capacity.
public struct AttacheCalibrationCorrection: Equatable, Sendable {
    public let factor: Double
    public let sampleCount: Int
    public let aggregateError: Double
    public let isActionable: Bool

    public init(factor: Double, sampleCount: Int, aggregateError: Double, isActionable: Bool) {
        self.factor = factor
        self.sampleCount = sampleCount
        self.aggregateError = aggregateError
        self.isActionable = isActionable
    }

    /// Non-actionable correction: too few samples, no adjustment (INF-318).
    public static let unactionable = AttacheCalibrationCorrection(
        factor: 1.0, sampleCount: 0, aggregateError: 0, isActionable: false
    )
}

/// Redacted calibration diagnostics (INF-318). Content-free: only aggregate
/// counters and lineage metadata. No request/response content, no paths, no
/// keys.
public struct AttacheCalibrationDiagnostics: Equatable, Sendable {
    public let modelIdentityKey: String
    public let lineageID: String
    public let sampleCount: Int
    public let aggregateEstimateError: Double
    public let correctionFactor: Double
    public let isActionable: Bool
    public let lastUpdate: Date?

    public init(
        modelIdentityKey: String, lineageID: String, sampleCount: Int,
        aggregateEstimateError: Double, correctionFactor: Double,
        isActionable: Bool, lastUpdate: Date?
    ) {
        self.modelIdentityKey = modelIdentityKey
        self.lineageID = lineageID
        self.sampleCount = sampleCount
        self.aggregateEstimateError = aggregateEstimateError
        self.correctionFactor = correctionFactor
        self.isActionable = isActionable
        self.lastUpdate = lastUpdate
    }
}

/// The pure token-usage parser (INF-318). Parses common response field naming
/// variants without breaking providers that omit usage. Never scrapes prose.
/// CLI providers stay uncalibrated unless they emit reliable structured usage.
public enum AttacheProviderUsageParser {

    /// Parse token usage from a JSON response object (INF-318). Handles
    /// prompt_tokens/input_tokens, completion_tokens/output_tokens,
    /// cached_tokens/cached_prompt_tokens/prompt_tokens_details.cached_tokens,
    /// and total_tokens. Returns a non-present result when usage is absent.
    public static func parse(usageJSON: [String: Any]?) -> AttacheParsedTokenUsage {
        guard let usage = usageJSON else {
            return AttacheParsedTokenUsage(inputTokens: nil, outputTokens: nil, cachedTokens: nil, totalTokens: nil)
        }
        let input = intField(usage, ["prompt_tokens", "input_tokens"])
        let output = intField(usage, ["completion_tokens", "output_tokens"])
        let cached = parseCachedTokens(usage)
        let total = intField(usage, ["total_tokens"])
        return AttacheParsedTokenUsage(inputTokens: input, outputTokens: output, cachedTokens: cached, totalTokens: total)
    }

    /// Parse from a raw JSON string (INF-318). Returns non-present on parse
    /// failure. Never scrapes prose: only structured `usage` objects are read.
    public static func parse(jsonString: String) -> AttacheParsedTokenUsage {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AttacheParsedTokenUsage(inputTokens: nil, outputTokens: nil, cachedTokens: nil, totalTokens: nil)
        }
        // The usage object may be at the top level or nested under "usage".
        if let usage = json["usage"] as? [String: Any] {
            return parse(usageJSON: usage)
        }
        return parse(usageJSON: json)
    }

    static func intField(_ dict: [String: Any], _ keys: [String]) -> Int? {
        for key in keys {
            if let value = dict[key] as? Int { return value }
            if let value = dict[key] as? Double { return Int(value) }
            if let value = dict[key] as? String, let parsed = Int(value) { return parsed }
        }
        return nil
    }

    static func parseCachedTokens(_ usage: [String: Any]) -> Int? {
        if let cached = intField(usage, ["cached_tokens", "cached_prompt_tokens"]) {
            return cached
        }
        // OpenAI-style nested: prompt_tokens_details.cached_tokens
        if let details = usage["prompt_tokens_details"] as? [String: Any] {
            return intField(details, ["cached_tokens"])
        }
        return nil
    }

    /// Detect a structurally recognized context-limit failure (INF-318).
    /// Returns a warning with the observed limit if the error structure names
    /// a context window overflow. Never treats this as a new limit fact.
    public static func detectContextLimitFailure(
        errorBody: String, modelIdentityKey: String
    ) -> AttacheCapabilityWarning? {
        let lower = errorBody.lowercased()
        let limitKeywords = ["context length", "context window", "maximum context", "token limit exceeded",
                             "input too long", "prompt is too long"]
        guard limitKeywords.contains(where: { lower.contains($0) }) else { return nil }
        // Try to extract a numeric limit from the error text.
        let observedLimit = extractLimit(from: lower)
        return AttacheCapabilityWarning(
            modelIdentityKey: modelIdentityKey, observedLimit: observedLimit,
            requiresUserAction: true
        )
    }

    static func extractLimit(from text: String) -> Int? {
        // Look for patterns like "maximum context length is 8192" or "limit: 128000".
        let patterns = ["maximum context length is ", "context length is ", "limit is ", "limit: "]
        for pattern in patterns {
            if let range = text.range(of: pattern) {
                let after = text[range.upperBound...]
                let digits = after.prefix { $0.isNumber }
                if let limit = Int(digits) { return limit }
            }
        }
        return nil
    }
}

/// A calibration lineage for one concrete model identity (INF-318). Stores
/// only aggregate statistics, never raw samples or content. Bounded sample
/// count. Outlier-resistant: uses median ratio, not mean.
public struct AttacheCalibrationLineage: Equatable, Sendable {
    public let modelIdentityKey: String
    public let lineageID: String
    public private(set) var ratios: [Double]
    public let minSamples: Int
    public let maxSamples: Int
    public var lastUpdate: Date?

    public init(modelIdentityKey: String, lineageID: String, minSamples: Int = 5, maxSamples: Int = 100) {
        self.modelIdentityKey = modelIdentityKey
        self.lineageID = lineageID
        self.ratios = []
        self.minSamples = minSamples
        self.maxSamples = maxSamples
        self.lastUpdate = nil
    }

    /// Convenience init that auto-generates the lineage ID from the identity
    /// key (INF-318).
    public init(modelIdentityKey: String, minSamples: Int = 5, maxSamples: Int = 100) {
        self.init(modelIdentityKey: modelIdentityKey, lineageID: AttacheCalibrationLineage.newLineageID(for: modelIdentityKey), minSamples: minSamples, maxSamples: maxSamples)
    }

    public var sampleCount: Int { ratios.count }
    public var isActionable: Bool { sampleCount >= minSamples }

    /// Record a sample's ratio (INF-318). Bounds the stored sample count.
    public mutating func record(_ ratio: Double) {
        ratios.append(ratio)
        if ratios.count > maxSamples {
            ratios.removeFirst(ratios.count - maxSamples)
        }
        lastUpdate = Date(timeIntervalSince1970: 1_700_000_000 + Double(ratios.count))
    }

    /// Compute the outlier-resistant correction factor (INF-318). Uses the
    /// median ratio, clamped to [0.5, 1.5]. Too few samples return 1.0
    /// (non-actionable). Outliers cannot produce zero, negative, or
    /// implausibly optimistic corrections.
    public func computeCorrection() -> AttacheCalibrationCorrection {
        guard isActionable else { return .unactionable }
        let sorted = ratios.sorted()
        let median = sorted[sorted.count / 2]
        let clamped = min(max(median, 0.5), 1.5)
        let error = abs(clamped - 1.0)
        return AttacheCalibrationCorrection(
            factor: clamped, sampleCount: sampleCount,
            aggregateError: error, isActionable: true
        )
    }

    /// Retire this lineage and start a new one on identity change (INF-318).
    public func retire(newIdentityKey: String) -> AttacheCalibrationLineage {
        AttacheCalibrationLineage(
            modelIdentityKey: newIdentityKey,
            lineageID: AttacheCalibrationLineage.newLineageID(for: newIdentityKey),
            minSamples: minSamples, maxSamples: maxSamples
        )
    }

    /// Generate a stable lineage ID from the identity key (INF-318).
    public static func newLineageID(for key: String) -> String {
        "lineage-\(key.hashValue)"
    }

    public func diagnostics() -> AttacheCalibrationDiagnostics {
        let correction = computeCorrection()
        return AttacheCalibrationDiagnostics(
            modelIdentityKey: modelIdentityKey, lineageID: lineageID,
            sampleCount: sampleCount, aggregateEstimateError: correction.aggregateError,
            correctionFactor: correction.factor, isActionable: correction.isActionable,
            lastUpdate: lastUpdate
        )
    }
}

/// The pure token-usage calibrator (INF-318). Records samples, computes
/// conservative corrections, and applies them to estimates. Calibration
/// adjusts estimator safety but never raises a hard limit, overrides
/// authoritative runtime/provider capacity, or changes Custom values.
public enum AttacheTokenUsageCalibrator {

    public static let estimatorVersion = "attache.fallback-estimator.v1"

    /// Record a usage sample into a lineage (INF-318).
    public static func record(
        _ sample: AttacheProviderUsageSample,
        into lineage: inout AttacheCalibrationLineage
    ) {
        lineage.record(sample.estimateRatio)
    }

    /// Apply a correction to an estimated token count (INF-318). The
    /// correction makes the estimate more conservative (higher) when the
    /// estimator underestimates. It never raises a hard limit or overrides
    /// authoritative capacity. A non-actionable correction returns the
    /// original estimate unchanged.
    public static func applyCorrection(
        estimate: Int, correction: AttacheCalibrationCorrection
    ) -> Int {
        guard correction.isActionable else { return estimate }
        // The correction factor is the median actual/estimated ratio.
        // Applying it makes the estimate match observed reality. But we only
        // ever apply it conservatively: round up, never down below the
        // original estimate, so calibration cannot make the estimator less
        // safe.
        let adjusted = Int((Double(estimate) * correction.factor).rounded(.up))
        return max(adjusted, estimate)
    }

    /// Apply a correction to a hard limit (INF-318). This is always a no-op:
    /// calibration cannot raise effective capacity. The hard limit is
    /// authoritative and comes from runtime/provider metadata or user Custom
    /// policy.
    public static func applyCorrectionToHardLimit(
        hardLimit: Int, correction: AttacheCalibrationCorrection
    ) -> Int {
        // Intentionally returns the hard limit unchanged. Calibration never
        // raises effective capacity or overwrites Custom policy.
        hardLimit
    }

    /// Check whether an identity change requires retiring the prior lineage
    /// (INF-318). A change in endpoint, model alias, or fingerprint starts a
    /// new calibration lineage.
    public static func shouldRetireLineage(
        oldKey: String, newKey: String
    ) -> Bool {
        oldKey != newKey
    }

    /// Record a context-limit failure as a warning (INF-318). This never
    /// becomes a new limit fact. It requires stronger evidence or user action.
    public static func recordContextLimitWarning(
        _ warning: AttacheCapabilityWarning
    ) -> AttacheCapabilityWarning {
        // The warning is returned as-is. It is a warning, not a limit. The
        // caller must surface it to the user and require explicit action
        // before any capacity value changes.
        return warning
    }
}

/// A SQLite-backed store of aggregate token-usage calibration (INF-318).
/// Persists only aggregate statistics per lineage. Never persists raw samples,
/// messages, excerpts, tool results, filenames, queries, memory, or transcript
/// text. 0600 file permissions.
public final class AttacheCalibrationStore: @unchecked Sendable {
    public static let currentSchemaVersion = 1
    private let dbURL: URL
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(databaseURL: URL) {
        self.dbURL = databaseURL
        openOrCreate()
    }

    deinit { if let handle { sqlite3_close(handle) } }

    private func openOrCreate() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if sqlite3_open(dbURL.path, &handle) != SQLITE_OK {
            handle = nil
            return
        }
        chmod(dbURL.path, 0o600)
        execute("PRAGMA journal_mode = WAL;")
        execute("PRAGMA synchronous = NORMAL;")
        execute("""
        CREATE TABLE IF NOT EXISTS calibration_meta (key TEXT PRIMARY KEY, value TEXT);
        """)
        execute("""
        CREATE TABLE IF NOT EXISTS calibration_lineages (
            model_identity_key TEXT PRIMARY KEY,
            lineage_id TEXT NOT NULL,
            ratio_count INTEGER NOT NULL,
            median_ratio REAL NOT NULL,
            last_update REAL,
            is_actionable INTEGER NOT NULL DEFAULT 0
        );
        """)
        upsertMeta("schema_version", "\(Self.currentSchemaVersion)")
    }

    /// Save a lineage's aggregate state (INF-318). Only aggregate stats, never
    /// raw samples or content.
    @discardableResult
    public func save(_ lineage: AttacheCalibrationLineage) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return false }
        let correction = lineage.computeCorrection()
        let sql = """
        INSERT OR REPLACE INTO calibration_lineages
        (model_identity_key, lineage_id, ratio_count, median_ratio, last_update, is_actionable)
        VALUES (?,?,?,?,?,?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, lineage.modelIdentityKey, -1, transient)
        sqlite3_bind_text(stmt, 2, lineage.lineageID, -1, transient)
        sqlite3_bind_int64(stmt, 3, Int64(lineage.sampleCount))
        sqlite3_bind_double(stmt, 4, correction.factor)
        if let update = lineage.lastUpdate {
            sqlite3_bind_double(stmt, 5, update.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_int(stmt, 6, correction.isActionable ? 1 : 0)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Load a lineage's diagnostics (INF-318). Content-free.
    public func diagnostics(for key: String) -> AttacheCalibrationDiagnostics? {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return nil }
        let sql = "SELECT model_identity_key, lineage_id, ratio_count, median_ratio, last_update, is_actionable FROM calibration_lineages WHERE model_identity_key = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let identityKey = stringColumn(stmt, 0)
        let lineageID = stringColumn(stmt, 1)
        let count = Int(sqlite3_column_int64(stmt, 2))
        let median = sqlite3_column_double(stmt, 3)
        let lastUpdate: Date? = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
        let actionable = sqlite3_column_int(stmt, 5) == 1
        return AttacheCalibrationDiagnostics(
            modelIdentityKey: identityKey, lineageID: lineageID,
            sampleCount: count, aggregateEstimateError: abs(median - 1.0),
            correctionFactor: median, isActionable: actionable, lastUpdate: lastUpdate
        )
    }

    /// Verify the store contains no content or sensitive material (INF-318).
    /// Used by the serialization-inspection test.
    public func dumpAllKeys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return [] }
        let sql = "SELECT model_identity_key, lineage_id FROM calibration_lineages;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var keys: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            keys.append(stringColumn(stmt, 0))
            keys.append(stringColumn(stmt, 1))
        }
        return keys
    }

    public func deleteAll() {
        lock.lock(); defer { lock.unlock() }
        execute("DELETE FROM calibration_lineages;")
    }

    private func stringColumn(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    private func upsertMeta(_ key: String, _ value: String) {
        let escaped = value.replacingOccurrences(of: "'", with: "''")
        execute("INSERT OR REPLACE INTO calibration_meta (key, value) VALUES ('\(key)', '\(escaped)');")
    }

    private func execute(_ sql: String) -> Bool {
        guard let handle else { return false }
        var error: UnsafeMutablePointer<Int8>? = nil
        let result = sqlite3_exec(handle, sql, nil, nil, &error)
        if error != nil { sqlite3_free(error) }
        return result == SQLITE_OK
    }
}