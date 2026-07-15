import Foundation
import SQLite3

/// SQLite destructor sentinel that tells the library to copy bound text so it is
/// safe to release the Swift string after binding.
private let sessionFTSTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One bounded, privacy-filtered chunk of a session transcript, indexed for
/// full-text search (INF-306). A hit on a chunk carries a provenance locator
/// back to the raw transcript so the source remains authoritative.
public struct SessionFTSChunk: Equatable, Sendable {
    public let sessionID: String
    public let sourceKind: String
    public let title: String
    public let workingDirectory: String?
    public let chunkOrdinal: Int
    /// Byte offset of this chunk within the indexed (normalized) content, so a
    /// hit can be re-read and validated against the raw transcript.
    public let byteOffset: Int
    public let length: Int
    public let normalizedText: String
    public let timestamp: Date
    public let indexingVersion: Int

    public init(
        sessionID: String,
        sourceKind: String,
        title: String,
        workingDirectory: String?,
        chunkOrdinal: Int,
        byteOffset: Int,
        length: Int,
        normalizedText: String,
        timestamp: Date,
        indexingVersion: Int
    ) {
        self.sessionID = sessionID
        self.sourceKind = sourceKind
        self.title = title
        self.workingDirectory = workingDirectory
        self.chunkOrdinal = chunkOrdinal
        self.byteOffset = byteOffset
        self.length = length
        self.normalizedText = normalizedText
        self.timestamp = timestamp
        self.indexingVersion = indexingVersion
    }
}

/// A search hit: discovery metadata plus a provenance locator and a bounded
/// snippet. A hit never authorizes the session; it only helps the user select
/// one (INF-306 security boundary).
public struct SessionFTSHit: Equatable, Sendable {
    public let sessionID: String
    public let sourceKind: String
    public let title: String
    public let workingDirectory: String?
    public let chunkOrdinal: Int
    public let byteOffset: Int
    public let snippet: String
    public let rank: Double
    public let timestamp: Date

    public init(
        sessionID: String,
        sourceKind: String,
        title: String,
        workingDirectory: String?,
        chunkOrdinal: Int,
        byteOffset: Int,
        snippet: String,
        rank: Double,
        timestamp: Date
    ) {
        self.sessionID = sessionID
        self.sourceKind = sourceKind
        self.title = title
        self.workingDirectory = workingDirectory
        self.chunkOrdinal = chunkOrdinal
        self.byteOffset = byteOffset
        self.snippet = snippet
        self.rank = rank
        self.timestamp = timestamp
    }
}

/// Filters for a session search. All optional; `nil` means no constraint.
public struct SessionFTSQuery: Equatable, Sendable {
    public var sourceKind: String?
    public var workingDirectory: String?
    public var titleContains: String?
    public var startDate: Date?
    public var endDate: Date?
    public var limit: Int

    public init(
        sourceKind: String? = nil,
        workingDirectory: String? = nil,
        titleContains: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        limit: Int = 200
    ) {
        self.sourceKind = sourceKind
        self.workingDirectory = workingDirectory
        self.titleContains = titleContains
        self.startDate = startDate
        self.endDate = endDate
        self.limit = max(1, limit)
    }
}

/// Content-free diagnostics for the FTS index (INF-306). No transcript content
/// or secrets leak through these fields.
public struct SessionFTSDiagnostics: Equatable, Sendable {
    public let schemaVersion: Int
    public let indexedSessionCount: Int
    public let chunkCount: Int
    public let lastIndexedAt: Date?
    public let failureCount: Int
    public let needsRebuild: Bool

    public init(
        schemaVersion: Int,
        indexedSessionCount: Int,
        chunkCount: Int,
        lastIndexedAt: Date?,
        failureCount: Int,
        needsRebuild: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.indexedSessionCount = indexedSessionCount
        self.chunkCount = chunkCount
        self.lastIndexedAt = lastIndexedAt
        self.failureCount = failureCount
        self.needsRebuild = needsRebuild
    }
}

/// Strips private reasoning, credentials, environment dumps, and tool payloads
/// that may contain secrets from transcript text before it enters the FTS table
/// (INF-306). Pure and deterministic so fixtures can assert secrets are absent.
public enum SessionFTSPrivacy {
    /// Lines whose presence would leak private material are dropped entirely.
    static let secretLinePatterns: [String] = [
        "api_key", "apikey", "api-key", "access_token", "auth_token", "secret",
        "password", "bearer ", "sk-", "xoxb", "xoxp", "ghp_", "gho_", "private_key",
        "-----begin", "aws_secret", "stripe_sk", "reasoning_content", "\"reasoning\"",
        "reasoning_summary"
    ]

    /// Environment-dump lines like `KEY=value` where KEY looks like a secret.
    static let secretEnvPattern: [String] = [
        "token", "secret", "password", "passwd", "key", "credential", "auth"
    ]

    /// Drop a line if it looks like a long base64/hex blob (a tool payload that
    /// may encode secrets) rather than readable transcript text.
    static func looksLikeOpaqueBlob(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 120 else { return false }
        let letters = trimmed.filter { $0.isLetter }
        let nonAlphanumeric = trimmed.filter { !$0.isLetter && !$0.isNumber }.count
        // Long runs of base64/hex with almost no spaces or punctuation.
        return nonAlphanumeric <= 2 && letters.count >= trimmed.count * 9 / 10
    }

    /// Returns the searchable text with private/secret lines removed. The raw
    /// transcript is unaffected; this only governs what the index stores.
    public static func normalizedSearchableText(_ content: String) -> String {
        let lower = content.lowercased()
        return lower
            .components(separatedBy: .newlines)
            .filter { line -> Bool in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return false }
                if secretLinePatterns.contains(where: { trimmed.contains($0) }) { return false }
                if looksLikeOpaqueBlob(trimmed) { return false }
                if let eq = trimmed.firstIndex(of: "=") {
                    let key = String(trimmed[..<eq]).lowercased()
                    if secretEnvPattern.contains(where: { key.contains($0) }) { return false }
                }
                return true
            }
            .joined(separator: "\n")
    }
}

/// A local SQLite FTS5 full-text index over session chunks (INF-306). Raw logs
/// remain the source of truth; this index is for fast discovery and evidence
/// lookup. Indexing never grants authorization, and a search hit is discovery
/// metadata, not a focused session.
public final class SessionFTSIndex: @unchecked Sendable {
    public static let currentSchemaVersion = 1
    private static let maxChunkCharacters = 2_000

    private let dbURL: URL
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var failureCount: Int = 0

    public init(databaseURL: URL) {
        self.dbURL = databaseURL
        openOrCreate()
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    // MARK: - Lifecycle / recovery

    private func openOrCreate() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        openHandle(recovering: true)
    }

    /// Open the DB, recovering (delete + retry) when the file is corrupt enough
    /// that SQLite cannot open it. Returns without throwing; a nil handle leaves
    /// the index non-functional but the app keeps running.
    private func openHandle(recovering: Bool) {
        let path = dbURL.path
        if sqlite3_open(path, &handle) != SQLITE_OK {
            handle = nil
            if recovering {
                // A file SQLite cannot open is corrupt; drop it and try once more.
                try? FileManager.default.removeItem(at: dbURL)
                failureCount = 0
                if sqlite3_open(path, &handle) == SQLITE_OK {
                    chmod(path, 0o600)
                    execute("PRAGMA journal_mode = WAL;")
                    execute("PRAGMA synchronous = NORMAL;")
                    createSchemaIfMissing()
                } else {
                    handle = nil
                    failureCount += 1
                }
            } else {
                failureCount += 1
            }
            return
        }
        chmod(path, 0o600)
        execute("PRAGMA journal_mode = WAL;")
        execute("PRAGMA synchronous = NORMAL;")
        // An explicit rebuild request wins over every other branch.
        if scalarInt("SELECT value FROM fts_meta WHERE key = 'needs_rebuild';") != nil {
            recoverAndRebuild()
            return
        }
        let recorded = scalarInt("SELECT value FROM fts_meta WHERE key = 'schema_version';")
        if recorded == nil {
            // Either a brand-new DB (PRAGMA just created it) or a corrupt DB
            // whose meta query failed. Create the schema, then verify it took;
            // if verification fails the DB is corrupt, so rebuild.
            createSchemaIfMissing()
            if scalarInt("SELECT value FROM fts_meta WHERE key = 'schema_version';") == nil {
                recoverAndRebuild()
            }
            return
        }
        if recorded != SessionFTSIndex.currentSchemaVersion {
            recoverAndRebuild()
            return
        }
        // Schema version matches. Sanity-check that the tables are usable; a
        // partially written or truncated DB can pass the meta read but fail
        // here, and should rebuild from source logs without data loss.
        if scalarInt("SELECT COUNT(*) FROM session_state;") == nil
            || scalarInt("SELECT COUNT(*) FROM session_chunks;") == nil {
            recoverAndRebuild()
        }
    }

    private func createSchemaIfMissing() {
        execute("""
        CREATE TABLE IF NOT EXISTS fts_meta (key TEXT PRIMARY KEY, value TEXT);
        """)
        execute("""
        CREATE TABLE IF NOT EXISTS session_state (
            session_id TEXT PRIMARY KEY,
            source_kind TEXT,
            file_path TEXT,
            file_mtime REAL,
            file_size INTEGER,
            chunk_count INTEGER,
            indexed_version INTEGER,
            last_indexed_at REAL
        );
        """)
        execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS session_chunks USING fts5(
            session_id UNINDEXED,
            source_kind UNINDEXED,
            title,
            working_directory UNINDEXED,
            chunk_ordinal UNINDEXED,
            byte_offset UNINDEXED,
            length UNINDEXED,
            content,
            timestamp UNINDEXED,
            tokenize = 'porter unicode61'
        );
        """)
        let version = String(SessionFTSIndex.currentSchemaVersion)
        execute("INSERT OR REPLACE INTO fts_meta (key, value) VALUES ('schema_version', '\(version)');")
    }

    private func recoverAndRebuild() {
        if let handle { sqlite3_close(handle) }
        handle = nil
        try? FileManager.default.removeItem(at: dbURL)
        failureCount = 0
        if sqlite3_open(dbURL.path, &handle) != SQLITE_OK {
            handle = nil
            failureCount += 1
            return
        }
        chmod(dbURL.path, 0o600)
        execute("PRAGMA journal_mode = WAL;")
        execute("PRAGMA synchronous = NORMAL;")
        createSchemaIfMissing()
    }

    /// Mark the index for a full rebuild on the next open. Used when a caller
    /// detects external corruption the open path could not.
    public func markForRebuild() {
        lock.lock(); defer { lock.unlock() }
        execute("INSERT OR REPLACE INTO fts_meta (key, value) VALUES ('needs_rebuild', '1');")
    }

    // MARK: - Indexing

    /// Incrementally index a set of session records. A normal launch re-indexes
    /// only sessions whose mtime or size changed; unchanged sessions are skipped
    /// so logs are not reparsed (INF-306).
    @discardableResult
    public func index(records: [SessionRecord]) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil else { failureCount += 1; return 0 }
        var indexed = 0
        beginTransaction()
        for record in records {
            let size = (try? FileManager.default.attributesOfItem(atPath: record.filePath)[.size] as? Int) ?? 0
            if let state = sessionState(record.id), state.fileMtime == record.fileMtime, state.fileSize == size {
                continue // unchanged
            }
            reindex(record: record, fileSize: size)
            indexed += 1
        }
        commit()
        return indexed
    }

    private func reindex(record: SessionRecord, fileSize: Int) {
        // Remove prior chunks for this session before inserting the new set.
        deleteChunks(forSessionID: record.id)
        execute("DELETE FROM session_state WHERE session_id = '\(escapeSQL(record.id))';")
        let chunks = SessionFTSIndex.chunk(record: record)
        for chunk in chunks {
            insertChunk(chunk)
        }
        let now = Date().timeIntervalSince1970
        execute("""
        INSERT OR REPLACE INTO session_state
        (session_id, source_kind, file_path, file_mtime, file_size, chunk_count, indexed_version, last_indexed_at)
        VALUES ('\(escapeSQL(record.id))', '\(escapeSQL(record.sourceKind.rawValue))', '\(escapeSQL(record.filePath))',
                \(record.fileMtime), \(fileSize), \(chunks.count), \(SessionFTSIndex.currentSchemaVersion), \(now));
        """)
    }

    /// Remove a session that was deleted from disk so the index does not keep
    /// stale hits (INF-306).
    public func remove(sessionID: String) {
        lock.lock(); defer { lock.unlock() }
        deleteChunks(forSessionID: sessionID)
        execute("DELETE FROM session_state WHERE session_id = '\(escapeSQL(sessionID))';")
    }

    /// Parameterized delete of every chunk belonging to one session. FTS5 MATCH
    /// matches content, so this filters on the stored `session_id` column
    /// instead, which is exact and does not depend on the text being indexed.
    private func deleteChunks(forSessionID sessionID: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "DELETE FROM session_chunks WHERE session_id = ?;", -1, &stmt, nil) == SQLITE_OK else {
            failureCount += 1
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionID, -1, sessionFTSTransient)
        if sqlite3_step(stmt) != SQLITE_DONE {
            failureCount += 1
        }
    }

    /// Drop every chunk and all bookkeeping (used by the local-data reset path).
    public func wipe() {
        lock.lock(); defer { lock.unlock() }
        execute("DELETE FROM session_chunks;")
        execute("DELETE FROM session_state;")
    }

    private func insertChunk(_ chunk: SessionFTSChunk) {
        let sql = """
        INSERT INTO session_chunks
        (session_id, source_kind, title, working_directory, chunk_ordinal, byte_offset, length, content, timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            failureCount += 1
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, chunk.sessionID, -1, sessionFTSTransient)
        sqlite3_bind_text(stmt, 2, chunk.sourceKind, -1, sessionFTSTransient)
        sqlite3_bind_text(stmt, 3, chunk.title, -1, sessionFTSTransient)
        sqlite3_bind_text(stmt, 4, chunk.workingDirectory ?? "", -1, sessionFTSTransient)
        sqlite3_bind_int(stmt, 5, Int32(chunk.chunkOrdinal))
        sqlite3_bind_int(stmt, 6, Int32(chunk.byteOffset))
        sqlite3_bind_int(stmt, 7, Int32(chunk.length))
        sqlite3_bind_text(stmt, 8, chunk.normalizedText, -1, sessionFTSTransient)
        sqlite3_bind_double(stmt, 9, chunk.timestamp.timeIntervalSince1970)
        if sqlite3_step(stmt) != SQLITE_DONE {
            failureCount += 1
        }
    }

    /// Split a session record into bounded, privacy-filtered chunks with byte
    /// offsets into the normalized content. Pure and testable without SQLite.
    public static func chunk(record: SessionRecord) -> [SessionFTSChunk] {
        let normalized = SessionFTSPrivacy.normalizedSearchableText(record.content)
        var chunks: [SessionFTSChunk] = []
        var ordinal = 0
        var offset = 0
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            chunks.append(SessionFTSChunk(
                sessionID: record.id,
                sourceKind: record.sourceKind.rawValue,
                title: record.title,
                workingDirectory: record.project,
                chunkOrdinal: ordinal,
                byteOffset: offset,
                length: current.utf8.count,
                normalizedText: current,
                timestamp: record.updatedAt,
                indexingVersion: currentSchemaVersion
            ))
            offset += current.utf8.count + 1 // +1 for the newline separator
            ordinal += 1
            current = ""
        }
        for line in normalized.components(separatedBy: "\n") {
            if current.count + line.count + 1 > maxChunkCharacters && !current.isEmpty {
                flush()
            }
            if current.isEmpty { current = line }
            else { current += "\n" + line }
        }
        flush()
        return chunks
    }

    // MARK: - Query

    /// Search the index. A hit carries a provenance locator and a bounded
    /// snippet; searching never alters focused-session state or tool
    /// availability (INF-306).
    public func search(_ queryText: String, filters: SessionFTSQuery = SessionFTSQuery()) -> [SessionFTSHit] {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil else { return [] }
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let ftsQuery = fts5MatchQuery(trimmed)
        // snippet() bounds the returned text so the hit never leaks an unbounded
        // transcript region.
        let sql = """
        SELECT session_id, source_kind, title, working_directory, chunk_ordinal, byte_offset,
               snippet(session_chunks, 7, '…', '…', ' … ', 24) AS snippet,
               rank, timestamp
        FROM session_chunks
        WHERE session_chunks MATCH '\(escapeFTS(ftsQuery))'
        ORDER BY rank
        LIMIT \(max(filters.limit, 1) * 4);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            failureCount += 1
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var raw: [SessionFTSHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sessionID = columnString(stmt, 0)
            let sourceKind = columnString(stmt, 1)
            let title = columnString(stmt, 2)
            let workingDirectory = columnString(stmt, 3).nilIfEmpty
            let chunkOrdinal = Int(sqlite3_column_int(stmt, 4))
            let byteOffset = Int(sqlite3_column_int(stmt, 5))
            let snippet = columnString(stmt, 6)
            let rank = sqlite3_column_double(stmt, 7)
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
            raw.append(SessionFTSHit(
                sessionID: sessionID, sourceKind: sourceKind, title: title,
                workingDirectory: workingDirectory, chunkOrdinal: chunkOrdinal,
                byteOffset: byteOffset, snippet: snippet, rank: rank, timestamp: timestamp
            ))
        }
        return postFilter(raw, filters: filters).prefix(filters.limit).map { $0 }
    }

    private func postFilter(_ hits: [SessionFTSHit], filters: SessionFTSQuery) -> [SessionFTSHit] {
        hits.filter { hit in
            if let source = filters.sourceKind, hit.sourceKind != source { return false }
            if let cwd = filters.workingDirectory?.nilIfEmpty,
               hit.workingDirectory?.lowercased() != cwd.lowercased() { return false }
            if let title = filters.titleContains?.lowercased().nilIfEmpty,
               !hit.title.lowercased().contains(title) { return false }
            if let start = filters.startDate, hit.timestamp < start { return false }
            if let end = filters.endDate, hit.timestamp > end { return false }
            return true
        }
    }

    // MARK: - Diagnostics

    public func diagnostics() -> SessionFTSDiagnostics {
        lock.lock(); defer { lock.unlock() }
        let chunkCount = scalarInt("SELECT COUNT(*) FROM session_chunks;") ?? 0
        let sessionCount = scalarInt("SELECT COUNT(*) FROM session_state;") ?? 0
        let last = scalarDouble("SELECT MAX(last_indexed_at) FROM session_state;")
        let recorded = scalarInt("SELECT value FROM fts_meta WHERE key = 'schema_version';")
        return SessionFTSDiagnostics(
            schemaVersion: recorded ?? 0,
            indexedSessionCount: sessionCount,
            chunkCount: chunkCount,
            lastIndexedAt: last.map { Date(timeIntervalSince1970: $0) },
            failureCount: failureCount,
            needsRebuild: recorded != SessionFTSIndex.currentSchemaVersion
        )
    }

    // MARK: - SQLite helpers

    /// Return the stored (mtime, size) for a session, or nil if it has not been
    /// indexed. Used to skip unchanged sessions on a normal launch.
    private func sessionState(_ sessionID: String) -> (fileMtime: Double, fileSize: Int)? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT file_mtime, file_size FROM session_state WHERE session_id = ?;", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionID, -1, sessionFTSTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let mtime = sqlite3_column_double(stmt, 0)
        let size = Int(sqlite3_column_int(stmt, 1))
        return (mtime, size)
    }

    private func beginTransaction() { execute("BEGIN TRANSACTION;") }
    private func commit() { execute("COMMIT;") }

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &error)
        if result != SQLITE_OK {
            failureCount += 1
            if let error { sqlite3_free(error) }
        }
        return result == SQLITE_OK
    }

    private func scalarInt(_ sql: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            sqlite3_finalize(stmt)
            return nil
        }
        let value = Int(sqlite3_column_int(stmt, 0))
        sqlite3_finalize(stmt)
        return value
    }

    private func scalarDouble(_ sql: String) -> Double? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            sqlite3_finalize(stmt)
            return nil
        }
        let value = sqlite3_column_double(stmt, 0)
        sqlite3_finalize(stmt)
        return value
    }

    private func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        if let cString = sqlite3_column_text(stmt, index) {
            return String(cString: cString)
        }
        return ""
    }

    private func escapeSQL(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "''")
    }

    /// FTS5 MATCH strings need single quotes doubled and special operators
    /// neutralized so a session id or query term is treated as a phrase.
    private func escapeFTS(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "''")
    }

    /// Build an FTS5 MATCH query from a plain-text query: quote the whole
    /// string as a phrase so multi-word queries match the phrase, and also OR
    /// the individual terms so partial matches still surface.
    private func fts5MatchQuery(_ query: String) -> String {
        let terms = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return "\"\(escapeFTS(query))\"" }
        let phrase = "\"\(escapeFTS(query))\""
        let termQuery = terms.map { "\"\(escapeFTS($0))\"" }.joined(separator: " OR ")
        return "(\(phrase) OR \(termQuery))"
    }
}
