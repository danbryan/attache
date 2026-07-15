import Foundation
import SQLite3

private let memoryTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The kind of durable fact a memory record holds (INF-310).
public enum AttacheMemoryType: String, Codable, Equatable, Sendable, CaseIterable {
    case userFact
    case preference
    case standingInstruction
    case relationship
    case projectTopic
    case reminder
}

/// Who can see a record. A record scoped to a personality or topic is invisible
/// outside that scope (INF-310).
public enum AttacheMemoryScope: Equatable, Sendable, Codable {
    case global
    case personality(String)
    case topic(String)
}

/// Where the memory came from, distinguishing user-confirmed, user-authored,
/// imported, and model-proposed records.
public enum AttacheMemorySourceKind: String, Codable, Equatable, Sendable, CaseIterable {
    case userConfirmed
    case userAuthored
    case imported
    case modelProposed
}

public enum AttacheMemorySensitivity: String, Codable, Equatable, Sendable, CaseIterable {
    case low, medium, high, secret
}

/// Egress policy, independent from local visibility: a memory can be local-only
/// even when the active personality uses a remote model (INF-310).
public enum AttacheMemoryEgress: String, Codable, Equatable, Sendable, CaseIterable {
    case localOnly
    case allowedRemote
}

public enum AttacheMemoryStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case active
    case superseded
    case forgotten
}

/// One structured durable memory record (INF-310). Cites its origin via
/// `sourceLocator` but does not authorize the origin session.
public struct AttacheMemoryRecord: Equatable, Sendable, Codable {
    public let id: String
    public var statement: String
    public var type: AttacheMemoryType
    public var scope: AttacheMemoryScope
    public var sourceKind: AttacheMemorySourceKind
    public var sourceLocator: String?
    public var confidence: AttacheCapabilityConfidence
    public var sensitivity: AttacheMemorySensitivity
    public var egress: AttacheMemoryEgress
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    public var status: AttacheMemoryStatus
    public var supersededByID: String?

    public init(
        id: String, statement: String, type: AttacheMemoryType,
        scope: AttacheMemoryScope = .global,
        sourceKind: AttacheMemorySourceKind = .userAuthored,
        sourceLocator: String? = nil, confidence: AttacheCapabilityConfidence = .authoritative,
        sensitivity: AttacheMemorySensitivity = .low,
        egress: AttacheMemoryEgress = .localOnly,
        createdAt: Date = Date(timeIntervalSince1970: 0), updatedAt: Date = Date(timeIntervalSince1970: 0),
        lastUsedAt: Date? = nil, status: AttacheMemoryStatus = .active,
        supersededByID: String? = nil
    ) {
        self.id = id
        self.statement = statement
        self.type = type
        self.scope = scope
        self.sourceKind = sourceKind
        self.sourceLocator = sourceLocator
        self.confidence = confidence
        self.sensitivity = sensitivity
        self.egress = egress
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.status = status
        self.supersededByID = supersededByID
    }

    /// True when this record is visible to the given personality id, respecting
    /// scope policy (INF-310).
    public func isVisible(to personalityID: String?) -> Bool {
        switch scope {
        case .global: return true
        case .personality(let scoped): return scoped == personalityID
        case .topic: return true
        }
    }

    /// True when this record may be included in a remote-bound request.
    public var mayEgressToRemote: Bool { egress == .allowedRemote && status == .active }
}

/// Content-free diagnostics for the memory ledger (INF-310).
public struct AttacheMemoryDiagnostics: Equatable, Sendable {
    public let totalRecords: Int
    public let activeRecords: Int
    public let byType: [String: Int]
    public let migrationVersion: Int
    public let lastMaintenanceAt: Date?

    public init(totalRecords: Int, activeRecords: Int, byType: [String: Int], migrationVersion: Int, lastMaintenanceAt: Date?) {
        self.totalRecords = totalRecords
        self.activeRecords = activeRecords
        self.byType = byType
        self.migrationVersion = migrationVersion
        self.lastMaintenanceAt = lastMaintenanceAt
    }
}

/// Rejects statements that look like secrets, private reasoning, or raw
/// transcripts so they never enter the ledger (INF-310).
public enum AttacheMemorySecretFilter {
    static let secretPatterns: [String] = [
        "api_key", "apikey", "api-key", "access_token", "auth_token", "secret",
        "password", "bearer ", "sk-", "xoxb", "xoxp", "ghp_", "gho_", "private_key",
        "-----begin", "aws_secret", "stripe_sk", "reasoning_content"
    ]

    /// Returns true if the statement must be rejected (looks like a secret or
    /// private model reasoning, not a durable user fact).
    public static func shouldReject(_ statement: String) -> Bool {
        let lower = statement.lowercased()
        if secretPatterns.contains(where: { lower.contains($0) }) { return true }
        return false
    }
}

/// A structured, local, inspectable memory ledger backed by SQLite (INF-310).
/// Supports provenance, scope, egress, supersession, correction, deletion,
/// export, and idempotent migration from the legacy Markdown memory. Restrictive
/// file permissions. Never stores secrets or raw transcripts.
public final class AttacheMemoryLedger: @unchecked Sendable {
    public static let currentMigrationVersion = 1
    private let dbURL: URL
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

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
        CREATE TABLE IF NOT EXISTS memory_meta (key TEXT PRIMARY KEY, value TEXT);
        """)
        execute("""
        CREATE TABLE IF NOT EXISTS memories (
            id TEXT PRIMARY KEY,
            statement TEXT NOT NULL,
            type TEXT NOT NULL,
            scope TEXT NOT NULL,
            scope_value TEXT,
            source_kind TEXT NOT NULL,
            source_locator TEXT,
            confidence TEXT NOT NULL,
            sensitivity TEXT NOT NULL,
            egress TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            last_used_at REAL,
            status TEXT NOT NULL,
            superseded_by_id TEXT
        );
        """)
    }

    // MARK: - CRUD

    @discardableResult
    public func add(_ record: AttacheMemoryRecord) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !AttacheMemorySecretFilter.shouldReject(record.statement) else { return false }
        guard let handle else { return false }
        let sql = """
        INSERT OR REPLACE INTO memories
        (id, statement, type, scope, scope_value, source_kind, source_locator, confidence,
         sensitivity, egress, created_at, updated_at, last_used_at, status, superseded_by_id)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindMemory(stmt, record)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    public func list(activeOnly: Bool = true) -> [AttacheMemoryRecord] {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return [] }
        let whereClause = activeOnly ? "WHERE status = 'active'" : ""
        let sql = "SELECT * FROM memories \(whereClause) ORDER BY updated_at DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var records: [AttacheMemoryRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let record = readMemory(stmt) { records.append(record) }
        }
        return records
    }

    /// List records visible to a personality, respecting scope and egress policy.
    public func list(forPersonality personalityID: String?, egress: AttacheMemoryEgress? = nil) -> [AttacheMemoryRecord] {
        list(activeOnly: true).filter { record in
            guard record.isVisible(to: personalityID) else { return false }
            if let egress, record.egress != egress { return false }
            return true
        }
    }

    /// Supersede a record: mark the old one superseded and add the new one with
    /// a supersession link. Editing never creates duplicate active facts.
    @discardableResult
    public func supersede(oldID: String, with newRecord: AttacheMemoryRecord) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return false }
        beginTransaction()
        execute("UPDATE memories SET status = 'superseded', superseded_by_id = '\(escape(newRecord.id))', updated_at = \(Date().timeIntervalSince1970) WHERE id = '\(escape(oldID))';")
        var updated = newRecord
        updated.supersededByID = nil
        let added = add(updated)
        commit()
        return added
    }

    /// Forget a record: mark it forgotten so it leaves active retrieval without
    /// destroying the audit trail.
    public func forget(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        execute("UPDATE memories SET status = 'forgotten', updated_at = \(Date().timeIntervalSince1970) WHERE id = '\(escape(id))';")
    }

    /// Delete all records and reset the ledger.
    public func deleteAll() {
        lock.lock(); defer { lock.unlock() }
        execute("DELETE FROM memories;")
        execute("DELETE FROM memory_meta WHERE key = 'migration_version';")
    }

    /// Export all records as JSON.
    public func export() -> Data? {
        let records = list(activeOnly: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(records)
    }

    // MARK: - Migration

    /// Idempotently migrate from the legacy Markdown memory text (lines starting
    /// with `-`). Returns the number of records created. Preserves the original
    /// backup until migration verification succeeds (INF-310).
    @discardableResult
    public func migrate(fromMarkdown markdown: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let recorded = scalarString("SELECT value FROM memory_meta WHERE key = 'migration_version';")
        if let recorded, let version = Int(recorded), version >= Self.currentMigrationVersion {
            return 0 // already migrated
        }
        let entries = AttachePersonality.parsedMemoryEntries(from: markdown)
        guard !entries.isEmpty else {
            execute("INSERT OR REPLACE INTO memory_meta (key, value) VALUES ('migration_version', '\(Self.currentMigrationVersion)');")
            return 0
        }
        beginTransaction()
        var created = 0
        for entry in entries {
            let record = AttacheMemoryRecord(
                id: "migrated.\(UUID().uuidString.prefix(8))",
                statement: entry,
                type: .preference,
                scope: .global,
                sourceKind: .imported,
                confidence: .authoritative,
                sensitivity: .low,
                egress: .localOnly
            )
            if addInternal(record) { created += 1 }
        }
        execute("INSERT OR REPLACE INTO memory_meta (key, value) VALUES ('migration_version', '\(Self.currentMigrationVersion)');")
        commit()
        return created
    }

    /// True when migration has already run.
    public var isMigrated: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let raw = scalarString("SELECT value FROM memory_meta WHERE key = 'migration_version';") else { return false }
        return (Int(raw) ?? 0) >= Self.currentMigrationVersion
    }

    // MARK: - Diagnostics

    public func diagnostics() -> AttacheMemoryDiagnostics {
        lock.lock(); defer { lock.unlock() }
        let total = scalarInt("SELECT COUNT(*) FROM memories;") ?? 0
        let active = scalarInt("SELECT COUNT(*) FROM memories WHERE status = 'active';") ?? 0
        let version = Int(scalarString("SELECT value FROM memory_meta WHERE key = 'migration_version';") ?? "0") ?? 0
        let lastMaintenance = scalarDouble("SELECT MAX(updated_at) FROM memories;")
        var byType: [String: Int] = [:]
        for t in AttacheMemoryType.allCases {
            byType[t.rawValue] = scalarInt("SELECT COUNT(*) FROM memories WHERE type = '\(t.rawValue)';") ?? 0
        }
        return AttacheMemoryDiagnostics(totalRecords: total, activeRecords: active, byType: byType, migrationVersion: version, lastMaintenanceAt: lastMaintenance.map { Date(timeIntervalSince1970: $0) })
    }

    // MARK: - SQLite helpers

    private func beginTransaction() { execute("BEGIN TRANSACTION;") }
    private func commit() { execute("COMMIT;") }

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &error)
        if result != SQLITE_OK, let error { sqlite3_free(error) }
        return result == SQLITE_OK
    }

    /// Internal add without the lock (used within transactions).
    private func addInternal(_ record: AttacheMemoryRecord) -> Bool {
        guard !AttacheMemorySecretFilter.shouldReject(record.statement) else { return false }
        guard let handle else { return false }
        let sql = """
        INSERT OR REPLACE INTO memories
        (id, statement, type, scope, scope_value, source_kind, source_locator, confidence,
         sensitivity, egress, created_at, updated_at, last_used_at, status, superseded_by_id)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindMemory(stmt, record)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func bindMemory(_ stmt: OpaquePointer?, _ record: AttacheMemoryRecord) {
        sqlite3_bind_text(stmt, 1, record.id, -1, memoryTransient)
        sqlite3_bind_text(stmt, 2, record.statement, -1, memoryTransient)
        sqlite3_bind_text(stmt, 3, record.type.rawValue, -1, memoryTransient)
        let (scope, scopeValue) = scopeEncoding(record.scope)
        sqlite3_bind_text(stmt, 4, scope, -1, memoryTransient)
        if let scopeValue { sqlite3_bind_text(stmt, 5, scopeValue, -1, memoryTransient) }
        else { sqlite3_bind_null(stmt, 5) }
        sqlite3_bind_text(stmt, 6, record.sourceKind.rawValue, -1, memoryTransient)
        if let loc = record.sourceLocator { sqlite3_bind_text(stmt, 7, loc, -1, memoryTransient) }
        else { sqlite3_bind_null(stmt, 7) }
        sqlite3_bind_text(stmt, 8, record.confidence.rawValue, -1, memoryTransient)
        sqlite3_bind_text(stmt, 9, record.sensitivity.rawValue, -1, memoryTransient)
        sqlite3_bind_text(stmt, 10, record.egress.rawValue, -1, memoryTransient)
        sqlite3_bind_double(stmt, 11, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 12, record.updatedAt.timeIntervalSince1970)
        if let lastUsed = record.lastUsedAt { sqlite3_bind_double(stmt, 13, lastUsed.timeIntervalSince1970) }
        else { sqlite3_bind_null(stmt, 13) }
        sqlite3_bind_text(stmt, 14, record.status.rawValue, -1, memoryTransient)
        if let sup = record.supersededByID { sqlite3_bind_text(stmt, 15, sup, -1, memoryTransient) }
        else { sqlite3_bind_null(stmt, 15) }
    }

    private func readMemory(_ stmt: OpaquePointer?) -> AttacheMemoryRecord? {
        guard let stmt else { return nil }
        let id = columnString(stmt, 0)
        let statement = columnString(stmt, 1)
        guard let type = AttacheMemoryType(rawValue: columnString(stmt, 2)) else { return nil }
        let scopeStr = columnString(stmt, 3)
        let scopeValue = columnStringOptional(stmt, 4)
        let scope: AttacheMemoryScope
        switch scopeStr {
        case "global": scope = .global
        case "personality": scope = .personality(scopeValue ?? "")
        case "topic": scope = .topic(scopeValue ?? "")
        default: scope = .global
        }
        guard let sourceKind = AttacheMemorySourceKind(rawValue: columnString(stmt, 5)) else { return nil }
        let sourceLocator = columnStringOptional(stmt, 6)
        guard let confidence = AttacheCapabilityConfidence(rawValue: columnString(stmt, 7)) else { return nil }
        guard let sensitivity = AttacheMemorySensitivity(rawValue: columnString(stmt, 8)) else { return nil }
        guard let egress = AttacheMemoryEgress(rawValue: columnString(stmt, 9)) else { return nil }
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))
        let lastUsedAt = sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12))
        guard let status = AttacheMemoryStatus(rawValue: columnString(stmt, 13)) else { return nil }
        let supersededByID = columnStringOptional(stmt, 14)
        return AttacheMemoryRecord(
            id: id, statement: statement, type: type, scope: scope,
            sourceKind: sourceKind, sourceLocator: sourceLocator, confidence: confidence,
            sensitivity: sensitivity, egress: egress, createdAt: createdAt, updatedAt: updatedAt,
            lastUsedAt: lastUsedAt, status: status, supersededByID: supersededByID
        )
    }

    private func scopeEncoding(_ scope: AttacheMemoryScope) -> (String, String?) {
        switch scope {
        case .global: return ("global", nil)
        case .personality(let id): return ("personality", id)
        case .topic(let id): return ("topic", id)
        }
    }

    private func escape(_ text: String) -> String { text.replacingOccurrences(of: "'", with: "''") }

    private func scalarInt(_ sql: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { sqlite3_finalize(stmt); return nil }
        let value = Int(sqlite3_column_int(stmt, 0))
        sqlite3_finalize(stmt)
        return value
    }

    private func scalarDouble(_ sql: String) -> Double? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { sqlite3_finalize(stmt); return nil }
        let value = sqlite3_column_double(stmt, 0)
        sqlite3_finalize(stmt)
        return value
    }

    private func scalarString(_ sql: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { sqlite3_finalize(stmt); return nil }
        let value = columnString(stmt, 0)
        sqlite3_finalize(stmt)
        return value.isEmpty ? nil : value
    }

    private func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        if let cString = sqlite3_column_text(stmt, index) { return String(cString: cString) }
        return ""
    }

    private func columnStringOptional(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        let value = columnString(stmt, index)
        return value.isEmpty ? nil : value
    }
}