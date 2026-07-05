import Foundation
import SQLite3

public enum CardStoreError: Error, LocalizedError {
    case openFailed(String)
    case executeFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case missingDatabase

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "SQLite open failed: \(message)"
        case .executeFailed(let message):
            return "SQLite execute failed: \(message)"
        case .prepareFailed(let message):
            return "SQLite prepare failed: \(message)"
        case .stepFailed(let message):
            return "SQLite step failed: \(message)"
        case .missingDatabase:
            return "SQLite database is not open."
        }
    }
}

public final class CardStore {
    private var db: OpaquePointer?
    private let databaseURL: URL
    private let audioAssetsURL: URL
    private let dateFormatter = ISO8601DateFormatter()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// Compiled statements keyed by SQL text, kept for the lifetime of the store
    /// so repeated reads/writes skip re-parsing. Assumes serialized access (the
    /// store is driven from the main actor), the same as the raw sqlite3 handle.
    private var statementCache: [String: OpaquePointer] = [:]

    public convenience init(databaseURL: URL, audioAssetsURL: URL? = nil) throws {
        try self.init(databaseURL: databaseURL, audioAssetsURL: audioAssetsURL, inMemory: false)
    }

    /// A throwaway in-memory store used as a degraded fallback when the on-disk
    /// store cannot be opened, so Attaché still runs (without saved history).
    public static func inMemory() throws -> CardStore {
        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-audio-\(UUID().uuidString)", isDirectory: true)
        return try CardStore(databaseURL: URL(fileURLWithPath: ":memory:"), audioAssetsURL: audio, inMemory: true)
    }

    private init(databaseURL: URL, audioAssetsURL: URL?, inMemory: Bool) throws {
        self.databaseURL = databaseURL
        self.audioAssetsURL = audioAssetsURL ?? databaseURL.deletingLastPathComponent().appendingPathComponent("audio-assets", isDirectory: true)
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if !inMemory {
            try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: self.audioAssetsURL, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let openPath = inMemory ? ":memory:" : databaseURL.path
        if sqlite3_open(openPath, &handle) != SQLITE_OK {
            let message = handle.flatMap { sqlite3_errmsg($0).map { String(cString: $0) } } ?? "unknown"
            sqlite3_close(handle)
            throw CardStoreError.openFailed(message)
        }
        db = handle
        try migrate()
    }

    deinit {
        for statement in statementCache.values {
            sqlite3_finalize(statement)
        }
        sqlite3_close(db)
    }

    public static func defaultStore() throws -> CardStore {
        try CardStore(databaseURL: CompanionAppSupport.databaseURL())
    }

    public var databasePath: String { databaseURL.path }
    public var audioAssetsPath: String { audioAssetsURL.path }

    public func insertEvent(
        _ rawEvent: NormalizedEvent,
        status initialStatus: CardStatus = .unread,
        heardAt initialHeardAt: Date? = nil
    ) throws -> VoicemailCard {
        let event = try EventNormalizer.normalize(rawEvent)
        let now = Date()
        // Order by when the agent wrote the turn, not when we finished processing
        // it, so a slow presentation call can't reorder the inbox (INF-163).
        let sourceTimeString = event.metadata["source_time"] ?? PipelineOrdering.isoString(from: now)
        let createdAt = PipelineOrdering.date(from: sourceTimeString) ?? now
        let heardAt = initialStatus == .heard ? (initialHeardAt ?? now) : initialHeardAt
        let source = try upsertSource(kind: event.source, displayName: displayName(for: event.source))
        let session = try upsertSession(
            sourceID: source.id,
            externalSessionID: event.externalSessionID ?? "local-\(event.source)",
            projectPath: event.projectPath,
            title: event.title,
            lastSeenAt: now
        )

        let summary = EventNormalizer.storedSummary(for: event)
        let spokenText = EventNormalizer.storedSpokenText(for: event, summary: summary)
        let durationMs = CaptionAlignmentBuilder.estimatedDurationMs(for: spokenText)
        let alignment = CaptionAlignmentBuilder.fallback(text: spokenText, durationMs: durationMs)
        let alignmentJSON = try encodeJSON(alignment)
        let metadataJSON = EventNormalizer.metadataJSON(for: event)
        // Deterministic id: the same agent turn arriving via the watcher and the
        // HTTP hook (or a client retry) collapses to one card instead of doubling.
        let cardID = PipelineOrdering.stableCardID(
            source: event.source,
            sessionID: event.externalSessionID,
            sourceTime: sourceTimeString,
            content: event.text
        )
        if let existing = try? fetchCard(id: cardID) {
            return existing
        }

        try execute(
            """
            INSERT INTO cards (
                id, source_id, session_id, kind, raw_text, summary, spoken_text,
                status, created_at, heard_at, metadata_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(cardID),
                .text(source.id),
                .text(session.id),
                .text(CardKind.update.rawValue),
                .text(event.text),
                .text(summary),
                .text(spokenText),
                .text(initialStatus.rawValue),
                .text(formatDate(createdAt)),
                heardAt.map { .text(formatDate($0)) } ?? .null,
                .text(metadataJSON)
            ]
        )

        try execute(
            """
            INSERT INTO audio_assets (
                id, card_id, file_path, duration_ms, alignment_json, voice_provider, voice_id, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(UUID().uuidString),
                .text(cardID),
                .null,
                .int(durationMs),
                .text(alignmentJSON),
                .text("macos_nsspeech"),
                .text("system-default"),
                .text(formatDate(now))
            ]
        )

        return try fetchCard(id: cardID)
    }

    // MARK: - Instructions (two-way)

    private static let instructionColumns =
        "id, session_id, source_kind, text, state, created_at, confirmed_at, delivered_at, delivery_mechanism, error, resulting_card_id"

    public func upsertInstruction(_ instruction: Instruction) throws {
        try execute(
            """
            INSERT INTO instructions (\(Self.instructionColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                session_id = excluded.session_id,
                source_kind = excluded.source_kind,
                text = excluded.text,
                state = excluded.state,
                created_at = excluded.created_at,
                confirmed_at = excluded.confirmed_at,
                delivered_at = excluded.delivered_at,
                delivery_mechanism = excluded.delivery_mechanism,
                error = excluded.error,
                resulting_card_id = excluded.resulting_card_id
            """,
            [
                .text(instruction.id),
                .text(instruction.sessionID),
                .text(instruction.sourceKind),
                .text(instruction.text),
                .text(instruction.state.rawValue),
                .text(formatDate(instruction.createdAt)),
                .optionalText(instruction.confirmedAt.map(formatDate)),
                .optionalText(instruction.deliveredAt.map(formatDate)),
                .optionalText(instruction.deliveryMechanism),
                .optionalText(instruction.error),
                .optionalText(instruction.resultingCardID)
            ]
        )
    }

    public func fetchInstruction(id: String) throws -> Instruction? {
        try query(
            sql: "SELECT \(Self.instructionColumns) FROM instructions WHERE id = ? LIMIT 1",
            bindings: [.text(id)],
            map: mapInstruction
        ).first
    }

    public func fetchInstructions(forSessionID sessionID: String) throws -> [Instruction] {
        try query(
            sql: "SELECT \(Self.instructionColumns) FROM instructions WHERE session_id = ? ORDER BY created_at ASC",
            bindings: [.text(sessionID)],
            map: mapInstruction
        )
    }

    public func fetchInstructions(inStates states: [InstructionState]) throws -> [Instruction] {
        guard !states.isEmpty else { return [] }
        let placeholders = states.map { _ in "?" }.joined(separator: ", ")
        return try query(
            sql: "SELECT \(Self.instructionColumns) FROM instructions WHERE state IN (\(placeholders)) ORDER BY created_at ASC",
            bindings: states.map { .text($0.rawValue) },
            map: mapInstruction
        )
    }

    /// The delivery log, newest first, for the send-UX surface.
    public func fetchInstructionLog(limit: Int = 100) throws -> [Instruction] {
        try query(
            sql: "SELECT \(Self.instructionColumns) FROM instructions ORDER BY created_at DESC LIMIT ?",
            bindings: [.int(limit)],
            map: mapInstruction
        )
    }

    private func mapInstruction(_ stmt: OpaquePointer?) -> Instruction {
        Instruction(
            id: columnText(stmt, 0) ?? "",
            sessionID: columnText(stmt, 1) ?? "",
            sourceKind: columnText(stmt, 2) ?? "",
            text: columnText(stmt, 3) ?? "",
            state: InstructionState(rawValue: columnText(stmt, 4) ?? "") ?? .failed,
            createdAt: parseDate(columnText(stmt, 5)) ?? Date(timeIntervalSince1970: 0),
            confirmedAt: parseDate(columnText(stmt, 6)),
            deliveredAt: parseDate(columnText(stmt, 7)),
            deliveryMechanism: columnText(stmt, 8),
            error: columnText(stmt, 9),
            resultingCardID: columnText(stmt, 10)
        )
    }

    public func fetchCards(includeArchived: Bool = false, limit: Int? = nil) throws -> [VoicemailCard] {
        let archivedClause = includeArchived ? "" : "WHERE c.status != 'archived'"
        let limitClause = limit.map { "LIMIT \($0)" } ?? ""
        let sql =
            """
            SELECT
                c.id, c.source_id, src.kind, src.display_name, c.session_id,
                sess.external_session_id, sess.project_path, sess.title,
                c.kind, c.raw_text, c.summary, c.spoken_text, c.status,
                c.created_at, c.heard_at, c.metadata_json,
                COALESCE(aa.duration_ms, 0), aa.alignment_json
            FROM cards c
            JOIN sources src ON src.id = c.source_id
            LEFT JOIN sessions sess ON sess.id = c.session_id
            LEFT JOIN audio_assets aa ON aa.card_id = c.id
            \(archivedClause)
            ORDER BY c.created_at DESC
            \(limitClause)
            """
        return try queryCards(sql: sql, bindings: [])
    }

    /// Delete archived cards older than `days` (their audio_assets cascade via the
    /// foreign key). Bounds unbounded card growth over months of use (INF-170).
    /// Returns the number of cards removed.
    @discardableResult
    public func pruneArchivedCards(olderThan days: Int = 90) throws -> Int {
        let cutoff = formatDate(Date().addingTimeInterval(-Double(days) * 86_400))
        let count = try query(
            sql: "SELECT COUNT(*) FROM cards WHERE status = 'archived' AND created_at < ?",
            bindings: [.text(cutoff)]
        ) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
        if count > 0 {
            try execute("DELETE FROM cards WHERE status = 'archived' AND created_at < ?", [.text(cutoff)])
        }
        return count
    }

    public func fetchCard(id: String) throws -> VoicemailCard {
        let cards = try queryCards(
            sql:
                """
                SELECT
                    c.id, c.source_id, src.kind, src.display_name, c.session_id,
                    sess.external_session_id, sess.project_path, sess.title,
                    c.kind, c.raw_text, c.summary, c.spoken_text, c.status,
                    c.created_at, c.heard_at, c.metadata_json,
                    COALESCE(aa.duration_ms, 0), aa.alignment_json
                FROM cards c
                JOIN sources src ON src.id = c.source_id
                LEFT JOIN sessions sess ON sess.id = c.session_id
                LEFT JOIN audio_assets aa ON aa.card_id = c.id
                WHERE c.id = ?
                LIMIT 1
                """,
            bindings: [.text(id)]
        )
        guard let card = cards.first else {
            throw CardStoreError.stepFailed("Card not found: \(id)")
        }
        return card
    }

    public func recentCards(
        forExternalSessionID externalSessionID: String,
        limit: Int = 20,
        includeArchived: Bool = false
    ) throws -> [VoicemailCard] {
        let archivedClause = includeArchived ? "" : "AND c.status != 'archived'"
        let sql =
            """
            SELECT
                c.id, c.source_id, src.kind, src.display_name, c.session_id,
                sess.external_session_id, sess.project_path, sess.title,
                c.kind, c.raw_text, c.summary, c.spoken_text, c.status,
                c.created_at, c.heard_at, c.metadata_json,
                COALESCE(aa.duration_ms, 0), aa.alignment_json
            FROM cards c
            JOIN sources src ON src.id = c.source_id
            LEFT JOIN sessions sess ON sess.id = c.session_id
            LEFT JOIN audio_assets aa ON aa.card_id = c.id
            WHERE sess.external_session_id = ? \(archivedClause)
            ORDER BY c.created_at DESC
            LIMIT ?
            """
        return try queryCards(sql: sql, bindings: [.text(externalSessionID), .int(limit)])
    }

    public func markHeard(cardID: String, at date: Date = Date()) throws {
        try execute(
            "UPDATE cards SET status = ?, heard_at = ? WHERE id = ?",
            [.text(CardStatus.heard.rawValue), .text(formatDate(date)), .text(cardID)]
        )
    }

    public func markAllHeard(at date: Date = Date()) throws {
        try execute(
            "UPDATE cards SET status = ?, heard_at = COALESCE(heard_at, ?) WHERE status = ?",
            [.text(CardStatus.heard.rawValue), .text(formatDate(date)), .text(CardStatus.unread.rawValue)]
        )
    }

    public func archive(cardID: String) throws {
        try execute(
            "UPDATE cards SET status = ? WHERE id = ?",
            [.text(CardStatus.archived.rawValue), .text(cardID)]
        )
    }

    public func archiveAll() throws {
        try execute(
            "UPDATE cards SET status = ? WHERE status != ?",
            [.text(CardStatus.archived.rawValue), .text(CardStatus.archived.rawValue)]
        )
    }

    private func migrate() throws {
        try exec(
            """
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;

            CREATE TABLE IF NOT EXISTS sources (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                display_name TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                config_json TEXT NOT NULL DEFAULT '{}',
                UNIQUE(kind, display_name)
            );

            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                external_session_id TEXT,
                project_path TEXT,
                title TEXT NOT NULL,
                last_seen_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_sessions_lookup
            ON sessions(source_id, external_session_id, project_path);

            CREATE INDEX IF NOT EXISTS idx_sessions_external
            ON sessions(external_session_id);

            CREATE TABLE IF NOT EXISTS cards (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL,
                kind TEXT NOT NULL,
                raw_text TEXT NOT NULL,
                summary TEXT NOT NULL,
                spoken_text TEXT NOT NULL,
                status TEXT NOT NULL,
                created_at TEXT NOT NULL,
                heard_at TEXT,
                metadata_json TEXT NOT NULL DEFAULT '{}'
            );

            CREATE INDEX IF NOT EXISTS idx_cards_status_created
            ON cards(status, created_at);

            CREATE INDEX IF NOT EXISTS idx_cards_session ON cards(session_id);
            CREATE INDEX IF NOT EXISTS idx_cards_created ON cards(created_at);

            CREATE TABLE IF NOT EXISTS audio_assets (
                id TEXT PRIMARY KEY,
                card_id TEXT NOT NULL UNIQUE REFERENCES cards(id) ON DELETE CASCADE,
                file_path TEXT,
                duration_ms INTEGER NOT NULL,
                alignment_json TEXT NOT NULL,
                voice_provider TEXT NOT NULL,
                voice_id TEXT NOT NULL,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value_json TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS instructions (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                source_kind TEXT NOT NULL,
                text TEXT NOT NULL,
                state TEXT NOT NULL,
                created_at TEXT NOT NULL,
                confirmed_at TEXT,
                delivered_at TEXT,
                delivery_mechanism TEXT,
                error TEXT,
                resulting_card_id TEXT
            );

            CREATE INDEX IF NOT EXISTS idx_instructions_session
            ON instructions(session_id, created_at);
            CREATE INDEX IF NOT EXISTS idx_instructions_state ON instructions(state);
            """
        )
    }

    private func upsertSource(kind: String, displayName: String) throws -> StoredSource {
        if let existing = try fetchSource(kind: kind, displayName: displayName) {
            return existing
        }
        let source = StoredSource(
            id: UUID().uuidString,
            kind: kind,
            displayName: displayName,
            enabled: true,
            configJSON: "{}"
        )
        try execute(
            "INSERT INTO sources (id, kind, display_name, enabled, config_json) VALUES (?, ?, ?, ?, ?)",
            [.text(source.id), .text(source.kind), .text(source.displayName), .int(1), .text(source.configJSON)]
        )
        return source
    }

    private func fetchSource(kind: String, displayName: String) throws -> StoredSource? {
        let rows = try query(
            sql: "SELECT id, kind, display_name, enabled, config_json FROM sources WHERE kind = ? AND display_name = ? LIMIT 1",
            bindings: [.text(kind), .text(displayName)]
        ) { stmt in
            StoredSource(
                id: columnText(stmt, 0) ?? "",
                kind: columnText(stmt, 1) ?? "",
                displayName: columnText(stmt, 2) ?? "",
                enabled: sqlite3_column_int(stmt, 3) == 1,
                configJSON: columnText(stmt, 4) ?? "{}"
            )
        }
        return rows.first
    }

    private func upsertSession(sourceID: String, externalSessionID: String?, projectPath: String?, title: String, lastSeenAt: Date) throws -> StoredSession {
        if let existing = try fetchSession(sourceID: sourceID, externalSessionID: externalSessionID, projectPath: projectPath) {
            try execute(
                "UPDATE sessions SET title = ?, last_seen_at = ? WHERE id = ?",
                [.text(title), .text(formatDate(lastSeenAt)), .text(existing.id)]
            )
            return StoredSession(
                id: existing.id,
                sourceID: sourceID,
                externalSessionID: externalSessionID,
                projectPath: projectPath,
                title: title,
                lastSeenAt: lastSeenAt
            )
        }

        let session = StoredSession(
            id: UUID().uuidString,
            sourceID: sourceID,
            externalSessionID: externalSessionID,
            projectPath: projectPath,
            title: title,
            lastSeenAt: lastSeenAt
        )
        try execute(
            """
            INSERT INTO sessions (id, source_id, external_session_id, project_path, title, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                .text(session.id),
                .text(sourceID),
                .optionalText(externalSessionID),
                .optionalText(projectPath),
                .text(title),
                .text(formatDate(lastSeenAt))
            ]
        )
        return session
    }

    private func fetchSession(sourceID: String, externalSessionID: String?, projectPath: String?) throws -> StoredSession? {
        let rows = try query(
            sql:
                """
                SELECT id, source_id, external_session_id, project_path, title, last_seen_at
                FROM sessions
                WHERE source_id = ?
                  AND COALESCE(external_session_id, '') = COALESCE(?, '')
                  AND COALESCE(project_path, '') = COALESCE(?, '')
                LIMIT 1
                """,
            bindings: [.text(sourceID), .optionalText(externalSessionID), .optionalText(projectPath)]
        ) { stmt in
            StoredSession(
                id: columnText(stmt, 0) ?? "",
                sourceID: columnText(stmt, 1) ?? "",
                externalSessionID: columnText(stmt, 2),
                projectPath: columnText(stmt, 3),
                title: columnText(stmt, 4) ?? "",
                lastSeenAt: parseDate(columnText(stmt, 5)) ?? Date(timeIntervalSince1970: 0)
            )
        }
        return rows.first
    }

    private func queryCards(sql: String, bindings: [SQLiteBinding]) throws -> [VoicemailCard] {
        try query(sql: sql, bindings: bindings) { [decoder] stmt in
            let alignmentJSON = columnText(stmt, 17)
            let alignment = alignmentJSON
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? decoder.decode(CaptionAlignment.self, from: $0) }
            return VoicemailCard(
                id: columnText(stmt, 0) ?? "",
                sourceID: columnText(stmt, 1) ?? "",
                sourceKind: columnText(stmt, 2) ?? "",
                sourceDisplayName: columnText(stmt, 3) ?? "",
                sessionID: columnText(stmt, 4),
                externalSessionID: columnText(stmt, 5),
                projectPath: columnText(stmt, 6),
                sessionTitle: columnText(stmt, 7),
                kind: CardKind(rawValue: columnText(stmt, 8) ?? "") ?? .update,
                rawText: columnText(stmt, 9) ?? "",
                summary: columnText(stmt, 10) ?? "",
                spokenText: columnText(stmt, 11) ?? "",
                status: CardStatus(rawValue: columnText(stmt, 12) ?? "") ?? .failed,
                createdAt: parseDate(columnText(stmt, 13)) ?? Date(timeIntervalSince1970: 0),
                heardAt: parseDate(columnText(stmt, 14)),
                metadataJSON: columnText(stmt, 15) ?? "{}",
                durationMs: Int(sqlite3_column_int(stmt, 16)),
                alignment: alignment
            )
        }
    }

    private func displayName(for source: String) -> String {
        switch source {
        case "codex": return "Codex"
        case "claude_code": return "Claude Code"
        case "mcp": return "MCP"
        case "simulated": return "Simulator"
        default:
            return source.split(separator: "_").map { part in
                part.prefix(1).uppercased() + part.dropFirst()
            }.joined(separator: " ")
        }
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw CardStoreError.missingDatabase }
        var errorMessage: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? sqliteError()
            sqlite3_free(errorMessage)
            throw CardStoreError.executeFailed(message)
        }
    }

    private func execute(_ sql: String, _ bindings: [SQLiteBinding]) throws {
        let stmt = try cachedStatement(sql)
        defer { sqlite3_reset(stmt) }
        try bind(bindings, to: stmt)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw CardStoreError.stepFailed(sqliteError())
        }
    }

    private func query<T>(sql: String, bindings: [SQLiteBinding], map: (OpaquePointer?) throws -> T) throws -> [T] {
        let stmt = try cachedStatement(sql)
        defer { sqlite3_reset(stmt) }
        try bind(bindings, to: stmt)

        var rows: [T] = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW {
                rows.append(try map(stmt))
            } else if result == SQLITE_DONE {
                return rows
            } else {
                throw CardStoreError.stepFailed(sqliteError())
            }
        }
    }

    /// Returns the compiled statement for `sql`, preparing and caching it on first
    /// use. Cached statements are reset (cursor + bindings cleared) before reuse.
    private func cachedStatement(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw CardStoreError.missingDatabase }
        if let cached = statementCache[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var statement: OpaquePointer?
        let flags = UInt32(SQLITE_PREPARE_PERSISTENT)
        guard sqlite3_prepare_v3(db, sql, -1, flags, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CardStoreError.prepareFailed(sqliteError())
        }
        statementCache[sql] = statement
        return statement
    }

    private func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer?) throws {
        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch binding {
            case .text(let value):
                result = sqlite3_bind_text(statement, position, value, -1, sqliteTransient)
            case .optionalText(let value):
                if let value {
                    result = sqlite3_bind_text(statement, position, value, -1, sqliteTransient)
                } else {
                    result = sqlite3_bind_null(statement, position)
                }
            case .int(let value):
                result = sqlite3_bind_int(statement, position, Int32(value))
            case .null:
                result = sqlite3_bind_null(statement, position)
            }
            if result != SQLITE_OK {
                throw CardStoreError.stepFailed(sqliteError())
            }
        }
    }

    private func sqliteError() -> String {
        guard let db, let message = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: message)
    }

    private func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}

private enum SQLiteBinding {
    case text(String)
    case optionalText(String?)
    case int(Int)
    case null
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let pointer = sqlite3_column_text(statement, index)
    else { return nil }
    return String(cString: pointer)
}

private let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let iso8601WithoutFractionalSeconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

private func parseDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    return iso8601WithFractionalSeconds.date(from: value)
        ?? iso8601WithoutFractionalSeconds.date(from: value)
}
