import CryptoKit
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
public struct AttacheMemoryRecord: Equatable, Sendable, Codable, Identifiable {
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
    public func isVisible(to personalityID: String?, topic: String? = nil) -> Bool {
        switch scope {
        case .global: return true
        case .personality(let scoped): return scoped == personalityID
        case .topic(let scoped): return scoped == topic
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

public struct AttacheMemoryImportResult: Equatable, Sendable {
    public let imported: Int
    public let rejected: Int

    public init(imported: Int, rejected: Int) {
        self.imported = imported
        self.rejected = rejected
    }
}

/// Rejects statements that look like secrets, private reasoning, or raw
/// transcripts so they never enter the ledger (INF-310).
public enum AttacheMemorySecretFilter {
    public static let secretPatterns: [String] = [
        "api_key", "apikey", "api-key", "access_token", "auth_token", "secret",
        "password", "bearer ", "sk-", "xoxb", "xoxp", "ghp_", "gho_", "private_key",
        "-----begin", "aws_secret", "stripe_sk", "reasoning_content"
    ]

    /// Returns true if the statement must be rejected (looks like a secret or
    /// private model reasoning, not a durable user fact).
    public static func shouldReject(_ statement: String) -> Bool {
        let lower = statement.lowercased()
        if secretPatterns.contains(where: { lower.contains($0) }) { return true }
        return containsFinancialAccountData(statement)
            || containsCredentialLikeToken(statement)
    }

    /// Detect account identifiers even when a proposal omits helpful labels.
    /// The checks use structural validation where one exists, such as Luhn,
    /// ABA routing checksum, and IBAN mod-97, and otherwise require an explicit
    /// financial marker next to a digit sequence.
    public static func containsFinancialAccountData(_ statement: String) -> Bool {
        if matches(#"(?<!\d)\d{3}[ -]?\d{2}[ -]?\d{4}(?!\d)"#, in: statement) {
            return true
        }

        for candidate in digitCandidates(in: statement, minimum: 13, maximum: 19)
        where luhnValid(candidate) {
            return true
        }

        for candidate in digitCandidates(in: statement, minimum: 9, maximum: 9)
        where abaRoutingValid(candidate) {
            return true
        }

        if containsValidIBAN(statement) { return true }

        let lower = statement.lowercased()
        let accountMarkers = [
            "account number", "bank account", "routing number", "routing #",
            "aba number", "iban", "swift account", "acct number", "acct #"
        ]
        return accountMarkers.contains(where: { lower.contains($0) })
            && matches(#"(?<!\d)\d(?:[ -]?\d){3,}(?!\d)"#, in: statement)
    }

    /// Detect unlabeled token-shaped material. Long natural-language words do
    /// not qualify: a candidate must mix letters and digits and have high
    /// character entropy, or have a credential-specific structure such as JWT.
    public static func containsCredentialLikeToken(_ statement: String) -> Bool {
        if matches(#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]{8,})?\b"#, in: statement) {
            return true
        }
        for candidate in regexMatches(
            #"(?<![A-Za-z0-9])[A-Za-z0-9+/_=-]{24,}(?![A-Za-z0-9])"#,
            in: statement
        ) {
            let hasLetter = candidate.rangeOfCharacter(from: .letters) != nil
            let hasDigit = candidate.rangeOfCharacter(from: .decimalDigits) != nil
            if hasLetter, hasDigit, shannonEntropy(candidate) >= 3.5 {
                return true
            }
        }
        return false
    }

    private static func regexMatches(_ pattern: String, in value: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: value) else { return nil }
            return String(value[swiftRange])
        }
    }

    private static func matches(_ pattern: String, in value: String) -> Bool {
        !regexMatches(pattern, in: value).isEmpty
    }

    private static func digitCandidates(
        in value: String,
        minimum: Int,
        maximum: Int
    ) -> [String] {
        regexMatches(#"(?<!\d)\d(?:[ -]?\d){8,18}(?!\d)"#, in: value)
            .map { $0.filter(\.isNumber) }
            .filter { $0.count >= minimum && $0.count <= maximum }
    }

    private static func luhnValid(_ digits: String) -> Bool {
        guard digits.count >= 13, digits.count <= 19 else { return false }
        let values = digits.compactMap(\.wholeNumberValue)
        guard values.count == digits.count else { return false }
        let sum = values.reversed().enumerated().reduce(0) { total, pair in
            let (index, value) = pair
            if index.isMultiple(of: 2) { return total + value }
            let doubled = value * 2
            return total + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum > 0 && sum.isMultiple(of: 10)
    }

    private static func abaRoutingValid(_ digits: String) -> Bool {
        let values = digits.compactMap(\.wholeNumberValue)
        guard values.count == 9, values.contains(where: { $0 != 0 }) else { return false }
        let checksum = 3 * (values[0] + values[3] + values[6])
            + 7 * (values[1] + values[4] + values[7])
            + values[2] + values[5] + values[8]
        return checksum.isMultiple(of: 10)
    }

    private static func containsValidIBAN(_ statement: String) -> Bool {
        for raw in regexMatches(#"(?i)(?<![A-Z0-9])[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]){10,30}(?![A-Z0-9])"#, in: statement) {
            let compact = raw.uppercased().filter { !$0.isWhitespace }
            guard compact.count >= 15, compact.count <= 34 else { continue }
            let rearranged = compact.dropFirst(4) + compact.prefix(4)
            var remainder = 0
            var valid = true
            for scalar in rearranged.unicodeScalars {
                let piece: String
                if scalar.value >= 48, scalar.value <= 57 {
                    piece = String(Character(scalar))
                } else if scalar.value >= 65, scalar.value <= 90 {
                    piece = String(scalar.value - 55)
                } else {
                    valid = false
                    break
                }
                for digit in piece.compactMap(\.wholeNumberValue) {
                    remainder = (remainder * 10 + digit) % 97
                }
            }
            if valid, remainder == 1 { return true }
        }
        return false
    }

    private static func shannonEntropy(_ value: String) -> Double {
        guard !value.isEmpty else { return 0 }
        let counts = Dictionary(grouping: value, by: { $0 }).mapValues(\.count)
        let length = Double(value.count)
        return counts.values.reduce(0) { entropy, count in
            let probability = Double(count) / length
            return entropy - probability * log2(probability)
        }
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
        _ = openOrCreate()
    }

    deinit { if let handle { sqlite3_close(handle) } }

    @discardableResult
    private func openOrCreate() -> Bool {
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: dbURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return false
        }
        if sqlite3_open(dbURL.path, &handle) != SQLITE_OK {
            if let handle { sqlite3_close(handle) }
            handle = nil
            return false
        }
        guard chmod(dbURL.path, 0o600) == 0,
              execute("PRAGMA journal_mode = WAL;"),
              execute("PRAGMA synchronous = NORMAL;"),
              execute("PRAGMA secure_delete = ON;"),
              execute("""
        CREATE TABLE IF NOT EXISTS memory_meta (key TEXT PRIMARY KEY, value TEXT);
        """),
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
        """),
              // Repair databases created by the first implementation, which
              // preserved remote egress on migrated/imported rows. A native
              // per-record promotion creates a userConfirmed replacement, so
              // imported provenance is always safe to downgrade here.
              execute("UPDATE memories SET egress = 'localOnly' WHERE source_kind = 'imported' AND egress != 'localOnly';") else {
            if let handle { sqlite3_close(handle) }
            handle = nil
            return false
        }
        return secureArtifactPermissions()
    }

    // MARK: - CRUD

    @discardableResult
    public func add(_ record: AttacheMemoryRecord) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !AttacheMemorySecretFilter.shouldReject(record.statement) else { return false }
        guard let handle else { return false }
        let sql = """
        INSERT INTO memories
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

    /// Record that a bounded selection actually entered a request snapshot.
    /// This is diagnostics only and never affects authorization or relevance.
    @discardableResult
    public func markUsed(_ ids: [String], at date: Date = Date()) -> Bool {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return true }
        lock.lock(); defer { lock.unlock() }
        guard let handle, beginTransaction() else { return false }
        var shouldCommit = false
        defer { if !shouldCommit { rollback() } }
        let sql = "UPDATE memories SET last_used_at = ? WHERE id = ? AND status = 'active';"
        for id in unique {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                return false
            }
            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, id, -1, memoryTransient)
            let result = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            guard result == SQLITE_DONE else { return false }
        }
        guard commit(), secureArtifactPermissions() else { return false }
        shouldCommit = true
        return true
    }

    /// List records visible to a personality, respecting scope and egress policy.
    public func list(forPersonality personalityID: String?, topic: String? = nil, egress: AttacheMemoryEgress? = nil) -> [AttacheMemoryRecord] {
        list(activeOnly: true).filter { record in
            guard record.isVisible(to: personalityID, topic: topic) else { return false }
            if let egress, record.egress != egress { return false }
            return true
        }
    }

    /// Supersede a record: mark the old one superseded and add the new one with
    /// a supersession link. Editing never creates duplicate active facts.
    @discardableResult
    public func supersede(oldID: String, with newRecord: AttacheMemoryRecord) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil, oldID != newRecord.id,
              !AttacheMemorySecretFilter.shouldReject(newRecord.statement),
              beginTransaction() else { return false }
        var shouldCommit = false
        defer { if !shouldCommit { rollback() } }
        guard scalarInt("SELECT COUNT(*) FROM memories WHERE id = '\(escape(oldID))' AND status = 'active';") == 1 else {
            return false
        }
        var updated = newRecord
        updated.supersededByID = nil
        guard addInternal(updated) else { return false }
        guard execute("UPDATE memories SET status = 'superseded', superseded_by_id = '\(escape(newRecord.id))', updated_at = \(Date().timeIntervalSince1970) WHERE id = '\(escape(oldID))' AND status = 'active';"),
              sqlite3_changes(handle) == 1,
              commit() else { return false }
        shouldCommit = true
        return true
    }

    /// One-shot repair for rows stamped with the 1970 epoch by an earlier save
    /// and migration path that relied on the record initializer's placeholder
    /// dates. Zero timestamps rot recency scoring and date display, so they
    /// become the given time at launch.
    @discardableResult
    public func repairEpochZeroTimestamps(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let stamp = now.timeIntervalSince1970
        return execute("UPDATE memories SET created_at = \(stamp) WHERE created_at <= 0;")
            && execute("UPDATE memories SET updated_at = \(stamp) WHERE updated_at <= 0;")
    }

    /// Forget a record: mark it forgotten so it leaves active retrieval without
    /// destroying the audit trail.
    @discardableResult
    public func forget(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard execute("UPDATE memories SET status = 'forgotten', updated_at = \(Date().timeIntervalSince1970) WHERE id = '\(escape(id))' AND status = 'active';") else {
            return false
        }
        return sqlite3_changes(handle) == 1
    }

    /// Undo a forget without inserting a duplicate primary key. Only a
    /// currently forgotten row can be restored, and the same secret boundary
    /// still applies to defense against corrupt legacy rows.
    @discardableResult
    public func restore(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let record = list(activeOnly: false).first(where: { $0.id == id }),
              record.status == .forgotten,
              !AttacheMemorySecretFilter.shouldReject(record.statement) else { return false }
        guard execute("UPDATE memories SET status = 'active', superseded_by_id = NULL, updated_at = \(Date().timeIntervalSince1970) WHERE id = '\(escape(id))' AND status = 'forgotten';") else {
            return false
        }
        return sqlite3_changes(handle) == 1
    }

    /// Delete all records and reset the ledger. Success means the prior database
    /// and every SQLite sidecar were physically removed, a fresh restrictive
    /// database was created, the migration tombstone was persisted, and no
    /// memory rows remain. Callers must retain their visible state on failure.
    @discardableResult
    public func deleteAll() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let handle,
              sqlite3_wal_checkpoint_v2(
                handle, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil
              ) == SQLITE_OK,
              sqlite3_close(handle) == SQLITE_OK else {
            return false
        }
        self.handle = nil

        let fm = FileManager.default
        let artifacts = sqliteArtifactURLs
        do {
            for url in artifacts where fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        } catch {
            // Keep the ledger usable for a later retry when deletion was only
            // partially possible. Never claim erasure from this path.
            _ = openOrCreate()
            return false
        }
        guard artifacts.allSatisfy({ !fm.fileExists(atPath: $0.path) }),
              openOrCreate() else { return false }

        // Delete All is also a migration tombstone. Without this marker the
        // next launch would re-import the preserved legacy Markdown and
        // resurrect data the user explicitly deleted.
        guard execute("INSERT OR REPLACE INTO memory_meta (key, value) VALUES ('migration_version', '\(Self.currentMigrationVersion)');"),
              scalarInt("SELECT COUNT(*) FROM memories;") == 0,
              isMigrated,
              secureArtifactPermissions() else { return false }
        if let reopenedHandle = self.handle,
           sqlite3_wal_checkpoint_v2(
            reopenedHandle, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil
           ) != SQLITE_OK {
            return false
        }
        return scalarInt("SELECT COUNT(*) FROM memories;") == 0 && isMigrated
    }

    /// Export all records as JSON.
    public func export() -> Data? {
        let records = list(activeOnly: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(records)
    }

    /// Import a user-selected JSON export. Imported records keep their type,
    /// scope, sensitivity, and egress policy, but never retain an external ID,
    /// source authority, status, or supersession link. Every accepted entry is
    /// revalidated locally before one atomic transaction commits.
    public func importRecords(from data: Data) -> AttacheMemoryImportResult? {
        guard let decoded = try? JSONDecoder().decode([AttacheMemoryRecord].self, from: data),
              decoded.count <= 10_000 else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard beginTransaction() else { return nil }
        var imported = 0
        var rejected = 0
        var stagedStatements = list(activeOnly: true).map(\.statement)
        for candidate in decoded {
            let statement = candidate.statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !statement.isEmpty,
                  statement.count <= 10_000,
                  !AttacheMemorySecretFilter.shouldReject(statement),
                  !stagedStatements.contains(where: {
                      AttacheMemorySelector.lexicalOverlap($0, statement) > 0.85
                  }) else {
                rejected += 1
                continue
            }
            let record = AttacheMemoryRecord(
                id: "imported.\(UUID().uuidString)",
                statement: statement,
                type: candidate.type,
                scope: candidate.scope,
                sourceKind: .imported,
                sourceLocator: nil,
                confidence: .authoritative,
                sensitivity: candidate.sensitivity,
                // Import is permission to add local records, not blanket
                // permission for every imported statement to leave the Mac.
                // Remote promotion remains a native per-record action.
                egress: .localOnly,
                createdAt: Date(),
                updatedAt: Date(),
                status: .active
            )
            guard addInternal(record) else {
                rollback()
                return nil
            }
            stagedStatements.append(statement)
            imported += 1
        }
        guard commit() else {
            rollback()
            return nil
        }
        return AttacheMemoryImportResult(imported: imported, rejected: rejected)
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
        guard beginTransaction() else { return 0 }
        var committed = false
        defer { if !committed { rollback() } }
        guard let initialCount = scalarInt("SELECT COUNT(*) FROM memories;") else {
            return 0
        }
        var created = 0
        for entry in entries {
            // The legacy free-form file could contain material that the new
            // structured-memory safety contract forbids. Preserve the file in
            // the verified backup, but never promote a detected secret or
            // private-reasoning fragment into the active ledger.
            guard !AttacheMemorySecretFilter.shouldReject(entry) else { continue }
            let record = AttacheMemoryRecord(
                id: "migrated.\(UUID().uuidString)",
                statement: entry,
                type: .preference,
                scope: .global,
                sourceKind: .imported,
                confidence: .authoritative,
                sensitivity: .low,
                // Migration must not silently turn historical free-form text
                // into remote-disclosure authority. Users may promote an
                // individual record later through the native Memory UI.
                egress: .localOnly
            )
            guard addInternal(record) else { return 0 }
            created += 1
        }
        guard scalarInt("SELECT COUNT(*) FROM memories;") == initialCount + created else {
            return 0
        }
        let sourceHash = SHA256.hash(data: Data(markdown.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        guard execute("INSERT OR REPLACE INTO memory_meta (key, value) VALUES ('migration_source_hash', '\(sourceHash)');"),
              execute("INSERT OR REPLACE INTO memory_meta (key, value) VALUES ('migration_record_count', '\(created)');"),
              execute("INSERT OR REPLACE INTO memory_meta (key, value) VALUES ('migration_version', '\(Self.currentMigrationVersion)');"),
              commit() else {
            return 0
        }
        committed = true
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

    private var sqliteArtifactURLs: [URL] {
        [
            dbURL,
            URL(fileURLWithPath: dbURL.path + "-wal"),
            URL(fileURLWithPath: dbURL.path + "-shm")
        ]
    }

    /// SQLite creates WAL/SHM lazily. Every artifact that currently exists must
    /// be private to the user before the ledger is considered usable or erased.
    private func secureArtifactPermissions() -> Bool {
        let fm = FileManager.default
        for url in sqliteArtifactURLs where fm.fileExists(atPath: url.path) {
            guard chmod(url.path, 0o600) == 0,
                  let attributes = try? fm.attributesOfItem(atPath: url.path),
                  let raw = (attributes[.posixPermissions] as? NSNumber)?.intValue,
                  raw & 0o777 == 0o600 else {
                return false
            }
        }
        return true
    }

    @discardableResult private func beginTransaction() -> Bool { execute("BEGIN IMMEDIATE TRANSACTION;") }
    @discardableResult private func commit() -> Bool { execute("COMMIT;") }
    private func rollback() { _ = execute("ROLLBACK;") }

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
        INSERT INTO memories
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
        let storedEgress: AttacheMemoryEgress = record.sourceKind == .imported
            ? .localOnly
            : record.egress
        sqlite3_bind_text(stmt, 10, storedEgress.rawValue, -1, memoryTransient)
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
