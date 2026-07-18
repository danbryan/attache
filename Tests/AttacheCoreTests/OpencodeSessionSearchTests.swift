import XCTest
import SQLite3
@testable import AttacheCore

/// INF-395 regression: an opencode session must be searchable by its transcript
/// CONTENT (e.g. a nonce that appears only in a user/assistant message), not
/// just its title. opencode is DB-backed: `record.filePath` is the shared
/// SQLite database, not a per-session JSONL transcript. The FTS indexer used to
/// stream that path as JSONL (parsing zero turns) and, because a binary `.db`
/// is not "readable plain text," dropped the searchable digest entirely,
/// indexing only a title-only chunk. Command-K content search then returned
/// "No sessions match" for a content nonce even though the row existed - the
/// exact f24 gate failure. This drives the real launch-time indexing/search
/// path end to end (OpencodeSessionScanner -> SessionIndexer -> SessionFTSIndex
/// -> AttacheSessionSearchService) against a fixture database.
final class OpencodeSessionSearchTests: XCTestCase {
    private func makeDataHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-opencode-search-\(UUID().uuidString)", isDirectory: true)
    }

    /// The full launch-time path: index an opencode fixture DB, then search by a
    /// nonce that appears ONLY in message content (never in the auto-generated
    /// title), and assert the session surfaces.
    func testOpencodeSessionSearchableByContentNonce() throws {
        let home = makeDataHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let nonce = "ATTACHENONCE\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"
        try makeDatabase(
            in: home,
            sessions: [(id: "ses_1", directory: "/Users/tester/proj", title: "Generic auto title", timeUpdated: 1_000)],
            messages: [
                "ses_1": [
                    (id: "m1", role: "user", finish: nil, timeCreated: 900, parts: [(type: "text", text: "Attache smoke \(nonce) please investigate")]),
                    (id: "m2", role: "assistant", finish: "stop", timeCreated: 1_000, parts: [(type: "text", text: "Done, reply token \(nonce)")])
                ]
            ]
        )

        // Drive the same launch-time indexing/FTS/search path, but with the
        // opencode scanner pointed explicitly at the FIXTURE data home. (The
        // production registry's `makeScanner` resolves the real, env-aware home
        // via `OpencodePaths.dataHome()`, which for a test must never be Dan's
        // real database; XDG resolution itself is covered separately below.)
        let scanners: [SessionScanner] = [OpencodeSessionScanner(opencodeDataHome: home)]
        let cacheURL = home.appendingPathComponent("index-cache.json")
        let indexer = SessionIndexer(cacheURL: cacheURL, scanners: scanners)
        let records = indexer.refresh()
        XCTAssertEqual(records.count, 1, "the opencode session must be indexed")
        XCTAssertTrue(records[0].content.contains(nonce.lowercased()), "the record digest must carry the content nonce")

        let ftsURL = home.appendingPathComponent("fts.sqlite")
        let fts = SessionFTSIndex(databaseURL: ftsURL)
        _ = fts.index(records: records)

        let service = AttacheSessionSearchService(ftsIndex: fts, records: records)
        let results = service.search(AttacheSessionSearchQuery(text: nonce))
        XCTAssertEqual(results.first?.sessionID, "ses_1", "an opencode session must be searchable by a content-only nonce; got \(results.map(\.sessionID))")
    }

    /// Direct FTS-level proof the digest is chunked (not dropped to a title-only
    /// chunk) for a DB-backed opencode record.
    func testFTSIndexesOpencodeRecordContent() throws {
        let home = makeDataHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbPath = home.appendingPathComponent("opencode.db")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Genuinely non-UTF8 binary (like a real SQLite database), so the FTS
        // indexer's plain-text-digest fallback is NOT taken and only the
        // opencode short-circuit can index this record's content.
        var header: [UInt8] = Array("SQLite format 3\u{0}".utf8)
        header += [0xFF, 0xFE, 0xC0, 0xC1, 0x00, 0x80, 0x81]
        FileManager.default.createFile(atPath: dbPath.path, contents: Data(header))

        let record = SessionRecord(
            id: "ses_x",
            title: "Auto title without the token",
            project: "/tmp/proj",
            threadName: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            archived: false,
            filePath: dbPath.path,          // a binary SQLite DB, not JSONL
            fileMtime: 1_000,
            content: "uniquecontentmarkerzeta the assistant fixed the flaky login test",
            topicTag: nil,
            sourceKind: .opencode
        )
        let fts = SessionFTSIndex(databaseURL: home.appendingPathComponent("fts.sqlite"))
        _ = fts.index(records: [record])

        let hits = fts.search("uniquecontentmarkerzeta")
        XCTAssertEqual(hits.first?.sessionID, "ses_x", "opencode record content must be indexed, not dropped to a title-only chunk")
    }

    /// The XDG override the gate relies on resolves to the same data home the
    /// gate constructs (pure, no ProcessInfo caching).
    func testXDGDataHomeResolvesToOpencodeSubdir() {
        let url = OpencodePaths.databaseURL(environment: ["XDG_DATA_HOME": "/tmp/attache-xdg"])
        XCTAssertEqual(url.path, "/tmp/attache-xdg/opencode/opencode.db")
    }

    // MARK: - Fixture DB helper (observed schema, no real content)

    @discardableResult
    private func makeDatabase(
        in dataHome: URL,
        sessions: [(id: String, directory: String, title: String, timeUpdated: Double)],
        messages: [String: [(id: String, role: String, finish: String?, timeCreated: Double, parts: [(type: String, text: String?)])]]
    ) throws -> URL {
        try FileManager.default.createDirectory(at: dataHome, withIntermediateDirectories: true)
        let dbURL = dataHome.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func exec(_ sql: String) { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, "exec failed: \(sql)") }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }

        exec("CREATE TABLE session (id text PRIMARY KEY, directory text, title text, parent_id text, time_updated integer, time_archived integer)")
        exec("CREATE TABLE message (id text PRIMARY KEY, session_id text, data text, time_created integer)")
        exec("CREATE TABLE part (id text PRIMARY KEY, message_id text, session_id text, data text)")

        for session in sessions {
            exec("""
                INSERT INTO session (id, directory, title, parent_id, time_updated, time_archived)
                VALUES (\(quote(session.id)), \(quote(session.directory)), \(quote(session.title)), NULL, \(Int64(session.timeUpdated * 1000)), NULL)
                """)
            for message in messages[session.id] ?? [] {
                var data: [String: Any] = ["role": message.role]
                if let finish = message.finish { data["finish"] = finish }
                let dataText = String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self)
                exec("""
                    INSERT INTO message (id, session_id, data, time_created)
                    VALUES (\(quote(message.id)), \(quote(session.id)), \(quote(dataText)), \(Int64(message.timeCreated * 1000)))
                    """)
                for (index, part) in message.parts.enumerated() {
                    var partData: [String: Any] = ["type": part.type]
                    if let value = part.text { partData["text"] = value }
                    let partText = String(decoding: try JSONSerialization.data(withJSONObject: partData), as: UTF8.self)
                    exec("""
                        INSERT INTO part (id, message_id, session_id, data)
                        VALUES (\(quote("\(message.id)-p\(index)")), \(quote(message.id)), \(quote(session.id)), \(quote(partText)))
                        """)
                }
            }
        }
        return dbURL
    }
}
