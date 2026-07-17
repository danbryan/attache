import Foundation
import SQLite3

/// Read-only access to opencode's SQLite database. Always opened with
/// `SQLITE_OPEN_READONLY` (never `SQLITE_OPEN_READWRITE`, never creates a
/// file that does not exist) so Attaché can never mutate opencode's own
/// state, and with a short `busy_timeout` so a poll never blocks the UI
/// waiting on the real `opencode` process's writer lock. `sqlite3_step`
/// returning `SQLITE_BUSY` after the timeout elapses is treated as "skip
/// this scan cycle," not an error surfaced to the user: the next poll tries
/// again, mirroring how a locked JSONL file would just be re-read on the
/// next tick rather than reported as a failure (INF-362 step 6, live-writer
/// safety).
public final class OpencodeReadOnlyDatabase {
    private var db: OpaquePointer?
    /// Short enough that a poll never visibly stalls the UI; long enough to
    /// ride out opencode's own brief write transactions rather than losing
    /// every read to contention.
    private static let busyTimeoutMS: Int32 = 200

    public init?(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, Self.busyTimeoutMS)
        self.db = handle
    }

    public func close() {
        guard let db else { return }
        sqlite3_close(db)
        self.db = nil
    }

    deinit { close() }

    public struct SessionSummary {
        public let id: String
        public let directory: String?
        public let title: String
        public let parentID: String?
        public let timeUpdated: Double
        public let archived: Bool
    }

    /// Every session, newest `time_updated` first. Returns an empty array
    /// (not a thrown error) on `SQLITE_BUSY` or any prepare/step failure,
    /// consistent with the fail-soft, skip-this-cycle contract above.
    public func sessionSummaries() -> [SessionSummary] {
        let sql = """
            SELECT id, directory, title, parent_id, time_updated, time_archived
            FROM session
            ORDER BY time_updated DESC
            """
        guard let statement = prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }

        var results: [SessionSummary] = []
        while true {
            let stepResult = sqlite3_step(statement)
            guard stepResult == SQLITE_ROW else {
                if stepResult != SQLITE_DONE {
                    // SQLITE_BUSY (or any other non-DONE code): stop reading
                    // and return whatever was already collected rather than
                    // blocking or throwing; the next poll retries.
                }
                break
            }
            guard let id = columnText(statement, 0) else { continue }
            let directory = columnText(statement, 1)
            let title = columnText(statement, 2) ?? "Session \(id.prefix(8))"
            let parentID = columnText(statement, 3)
            let timeUpdated = columnDouble(statement, 4)
            let archived = columnIsNotNull(statement, 5)
            results.append(SessionSummary(
                id: id, directory: directory, title: title, parentID: parentID,
                timeUpdated: timeUpdated / 1000, archived: archived
            ))
        }
        return results
    }

    public func sessionSummary(id: String) -> SessionSummary? {
        sessionSummaries().first { $0.id == id }
    }

    /// All messages for a session with their parts, ordered oldest first.
    /// `part.data`/`message.data` are opencode's own JSON blobs (verified
    /// against real sessions, INF-362): `message.data.role`,
    /// `message.data.finish`, `message.data.time.created`; `part.data.type`,
    /// `part.data.text`. Malformed JSON on any single row is skipped rather
    /// than aborting the whole read, the same tolerance
    /// `TranscriptParser`'s line parsers apply to a bad JSONL line.
    public func messages(forSessionID sessionID: String) -> [OpencodeTranscriptAdapter.MessageRow] {
        let messageSQL = "SELECT id, data, time_created FROM message WHERE session_id = ? ORDER BY time_created ASC, id ASC"
        guard let messageStatement = prepare(messageSQL) else { return [] }
        defer { sqlite3_finalize(messageStatement) }
        bindText(messageStatement, index: 1, value: sessionID)

        var rows: [(id: String, role: String?, finish: String?, timeCreated: Double)] = []
        while sqlite3_step(messageStatement) == SQLITE_ROW {
            guard let id = columnText(messageStatement, 0) else { continue }
            let dataText = columnText(messageStatement, 1) ?? ""
            let timeCreated = columnDouble(messageStatement, 2)
            let json = decodeJSONObject(dataText)
            let role = json?["role"] as? String
            let finish = json?["finish"] as? String
            rows.append((id: id, role: role, finish: finish, timeCreated: timeCreated))
        }
        guard !rows.isEmpty else { return [] }

        let partSQL = "SELECT message_id, id, data FROM part WHERE session_id = ? ORDER BY message_id ASC, id ASC"
        guard let partStatement = prepare(partSQL) else {
            return rows.map { OpencodeTranscriptAdapter.MessageRow(id: $0.id, role: $0.role, finish: $0.finish, timeCreated: $0.timeCreated, parts: []) }
        }
        defer { sqlite3_finalize(partStatement) }
        bindText(partStatement, index: 1, value: sessionID)

        var partsByMessage: [String: [OpencodeTranscriptAdapter.PartRow]] = [:]
        while sqlite3_step(partStatement) == SQLITE_ROW {
            guard let messageID = columnText(partStatement, 0) else { continue }
            let dataText = columnText(partStatement, 2) ?? ""
            let json = decodeJSONObject(dataText)
            let type = json?["type"] as? String
            let text = json?["text"] as? String
            partsByMessage[messageID, default: []].append(.init(type: type, text: text))
        }

        return rows.map { row in
            OpencodeTranscriptAdapter.MessageRow(
                id: row.id, role: row.role, finish: row.finish, timeCreated: row.timeCreated,
                parts: partsByMessage[row.id] ?? []
            )
        }
    }

    // MARK: - Low-level helpers

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        return statement
    }

    private func bindText(_ statement: OpaquePointer?, index: Int32, value: String) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func columnDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return 0 }
        return sqlite3_column_double(statement, index)
    }

    private func columnIsNotNull(_ statement: OpaquePointer?, _ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) != SQLITE_NULL
    }

    private func decodeJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
