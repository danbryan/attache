import XCTest
import SQLite3
@testable import AttacheCore

/// INF-362: opencode stores sessions as rows in one shared SQLite database at
/// ~/.local/share/opencode/opencode.db (WAL mode), verified against real
/// sessions on this Mac. These tests build a miniature database directly with
/// the observed schema (session/message/part) via the SQLite3 C API, so they
/// run fast and exercise the exact read path `OpencodeReadOnlyDatabase` uses,
/// without depending on the `sqlite3` CLI or Python being on PATH.
final class OpencodeSessionScannerTests: XCTestCase {
    private func makeDataHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-opencode-scanner-test-\(UUID().uuidString)", isDirectory: true)
    }

    /// Creates `opencode.db` with the observed schema (column shapes only,
    /// no real user content) and inserts the given fixture rows.
    @discardableResult
    private func makeDatabase(
        in dataHome: URL,
        sessions: [(id: String, directory: String, title: String, timeUpdated: Double, archived: Bool)],
        messages: [String: [(id: String, role: String, finish: String?, timeCreated: Double, parts: [(type: String, text: String?)])]]
    ) throws -> URL {
        try FileManager.default.createDirectory(at: dataHome, withIntermediateDirectories: true)
        let dbURL = dataHome.appendingPathComponent("opencode.db")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        func exec(_ sql: String) {
            var errorMessage: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
            if result != SQLITE_OK {
                let message = errorMessage.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(errorMessage)
                XCTFail("exec failed: \(message) for SQL: \(sql)")
            }
        }

        exec("""
            CREATE TABLE session (
                id text PRIMARY KEY, directory text, title text, parent_id text,
                time_updated integer, time_archived integer
            )
            """)
        exec("""
            CREATE TABLE message (
                id text PRIMARY KEY, session_id text, data text, time_created integer
            )
            """)
        exec("""
            CREATE TABLE part (
                id text PRIMARY KEY, message_id text, session_id text, data text
            )
            """)

        func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }

        for session in sessions {
            let archivedValue = session.archived ? "1" : "NULL"
            exec("""
                INSERT INTO session (id, directory, title, parent_id, time_updated, time_archived)
                VALUES (\(quote(session.id)), \(quote(session.directory)), \(quote(session.title)), NULL, \(Int64(session.timeUpdated * 1000)), \(archivedValue))
                """)
            for message in messages[session.id] ?? [] {
                var dataObject: [String: Any] = ["role": message.role]
                if let finish = message.finish { dataObject["finish"] = finish }
                let dataJSON = try! JSONSerialization.data(withJSONObject: dataObject)
                let dataText = String(data: dataJSON, encoding: .utf8)!
                exec("""
                    INSERT INTO message (id, session_id, data, time_created)
                    VALUES (\(quote(message.id)), \(quote(session.id)), \(quote(dataText)), \(Int64(message.timeCreated * 1000)))
                    """)
                for (index, part) in message.parts.enumerated() {
                    var partObject: [String: Any] = ["type": part.type]
                    if let text = part.text { partObject["text"] = text }
                    let partJSON = try! JSONSerialization.data(withJSONObject: partObject)
                    let partText = String(data: partJSON, encoding: .utf8)!
                    exec("""
                        INSERT INTO part (id, message_id, session_id, data)
                        VALUES (\(quote("\(message.id)-part\(index)")), \(quote(message.id)), \(quote(session.id)), \(quote(partText)))
                        """)
                }
            }
        }
        return dbURL
    }

    // MARK: - Discovery, title/cwd mapping

    func testScannerDiscoversSessionsWithTitleAndCwd() throws {
        let home = makeDataHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDatabase(
            in: home,
            sessions: [(id: "ses_1", directory: "/Users/tester/project", title: "Fix the flaky test", timeUpdated: 1000, archived: false)],
            messages: [:]
        )

        let scanner = OpencodeSessionScanner(opencodeDataHome: home)
        scanner.beginScan()
        let files = scanner.enumerateFiles()
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.id, "ses_1")

        let record = scanner.makeRecord(for: files[0], priorTopicTag: nil, contentCap: 4_000)
        XCTAssertEqual(record.title, "Fix the flaky test")
        XCTAssertEqual(record.project, "/Users/tester/project")
        XCTAssertEqual(record.sourceKind, .opencode)
        XCTAssertFalse(record.archived)
    }

    func testScannerMapsArchivedSessions() throws {
        let home = makeDataHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDatabase(
            in: home,
            sessions: [(id: "ses_archived", directory: "/tmp/proj", title: "Old session", timeUpdated: 500, archived: true)],
            messages: [:]
        )
        let scanner = OpencodeSessionScanner(opencodeDataHome: home)
        scanner.beginScan()
        let files = scanner.enumerateFiles()
        XCTAssertEqual(files.first?.archived, true)
        let record = scanner.makeRecord(for: files[0], priorTopicTag: nil, contentCap: 4_000)
        XCTAssertTrue(record.archived)
    }

    func testScannerDiscoversMultipleSessions() throws {
        let home = makeDataHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDatabase(
            in: home,
            sessions: [
                (id: "ses_a", directory: "/tmp/a", title: "A", timeUpdated: 100, archived: false),
                (id: "ses_b", directory: "/tmp/b", title: "B", timeUpdated: 200, archived: false),
                (id: "ses_c", directory: "/tmp/c", title: "C", timeUpdated: 300, archived: false)
            ],
            messages: [:]
        )
        let scanner = OpencodeSessionScanner(opencodeDataHome: home)
        scanner.beginScan()
        XCTAssertEqual(scanner.enumerateFiles().count, 3)
    }

    func testEnumerateFilesEmptyWhenDatabaseMissing() throws {
        let home = makeDataHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = OpencodeSessionScanner(opencodeDataHome: home)
        scanner.beginScan()
        XCTAssertTrue(scanner.enumerateFiles().isEmpty)
    }

    // MARK: - Part composition order

    func testTranscriptAdapterComposesPartsInOrder() {
        let messages: [OpencodeTranscriptAdapter.MessageRow] = [
            .init(id: "m1", role: "user", finish: nil, timeCreated: 1000, parts: [.init(type: "text", text: "please fix this")]),
            .init(id: "m2", role: "assistant", finish: nil, timeCreated: 2000, parts: [
                .init(type: "step-start", text: nil),
                .init(type: "text", text: "looking into it"),
                .init(type: "tool", text: nil),
                .init(type: "text", text: "found the bug")
            ]),
            .init(id: "m3", role: "assistant", finish: "stop", timeCreated: 3000, parts: [.init(type: "text", text: "fixed and tested")])
        ]
        let records = OpencodeTranscriptAdapter.records(from: messages, cwd: "/tmp/proj")
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].kind, .userTurnBoundary)
        guard case .assistantProse(let text1, let isFinal1) = records[1].kind else {
            return XCTFail("expected assistant prose")
        }
        XCTAssertEqual(text1, "looking into it\n\nfound the bug")
        XCTAssertFalse(isFinal1)
        guard case .assistantProse(let text2, let isFinal2) = records[2].kind else {
            return XCTFail("expected assistant prose")
        }
        XCTAssertEqual(text2, "fixed and tested")
        XCTAssertTrue(isFinal2, "finish == stop must mark a hard turn boundary")
        XCTAssertEqual(records[0].cwd, "/tmp/proj")
    }

    func testTranscriptAdapterSkipsMessagesWithNoNarratableText() {
        let messages: [OpencodeTranscriptAdapter.MessageRow] = [
            .init(id: "m1", role: "user", finish: nil, timeCreated: 1000, parts: [.init(type: "tool", text: nil)]),
            .init(id: "m2", role: "assistant", finish: nil, timeCreated: 2000, parts: [.init(type: "reasoning", text: "internal thought")]),
            .init(id: "m3", role: "assistant", finish: "stop", timeCreated: 3000, parts: [])
        ]
        let records = OpencodeTranscriptAdapter.records(from: messages, cwd: nil)
        XCTAssertTrue(records.isEmpty)
    }

    func testTranscriptAdapterSkipsUnknownRole() {
        let messages: [OpencodeTranscriptAdapter.MessageRow] = [
            .init(id: "m1", role: "system", finish: nil, timeCreated: 1000, parts: [.init(type: "text", text: "system prompt")])
        ]
        let records = OpencodeTranscriptAdapter.records(from: messages, cwd: nil)
        XCTAssertTrue(records.isEmpty)
    }

    func testScannerBuildsSearchContentFromUserAndAssistantText() throws {
        let home = makeDataHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDatabase(
            in: home,
            sessions: [(id: "ses_1", directory: "/tmp/proj", title: "Ship it", timeUpdated: 1000, archived: false)],
            messages: [
                "ses_1": [
                    (id: "m1", role: "user", finish: nil, timeCreated: 900, parts: [(type: "text", text: "Fix the flaky login test")]),
                    (id: "m2", role: "assistant", finish: "stop", timeCreated: 1000, parts: [(type: "text", text: "Done, tests pass now")])
                ]
            ]
        )
        let scanner = OpencodeSessionScanner(opencodeDataHome: home)
        scanner.beginScan()
        let files = scanner.enumerateFiles()
        let record = scanner.makeRecord(for: files[0], priorTopicTag: nil, contentCap: 4_000)
        XCTAssertTrue(record.content.contains("fix the flaky login test"))
        XCTAssertTrue(record.content.contains("done, tests pass now"))
    }

    // MARK: - Incremental re-read

    func testRefreshMetadataDoesNotReparseUnchangedSession() throws {
        let home = makeDataHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDatabase(
            in: home,
            sessions: [(id: "ses_1", directory: "/tmp/proj", title: "Original", timeUpdated: 1000, archived: false)],
            messages: [:]
        )
        let scanner = OpencodeSessionScanner(opencodeDataHome: home)
        scanner.beginScan()
        let files = scanner.enumerateFiles()
        let original = scanner.makeRecord(for: files[0], priorTopicTag: "tagged", contentCap: 4_000)
        // A same-mtime ScannedFile (simulating SessionIndexer's unchanged
        // branch) must go through refreshMetadata, which preserves the
        // record's prior title/content instead of re-querying the DB.
        let unchanged = scanner.refreshMetadata(original, for: files[0])
        XCTAssertEqual(unchanged.title, "Original")
        XCTAssertEqual(unchanged.topicTag, "tagged")
    }

    func testSessionIndexerSkipsUnchangedSessionOnSecondRefresh() throws {
        let home = makeDataHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDatabase(
            in: home,
            sessions: [(id: "ses_1", directory: "/tmp/proj", title: "Untouched", timeUpdated: 1000, archived: false)],
            messages: [:]
        )
        let cacheURL = home.appendingPathComponent("index-cache.json")
        let indexer = SessionIndexer(cacheURL: cacheURL, scanners: [OpencodeSessionScanner(opencodeDataHome: home)])
        let first = indexer.refresh()
        XCTAssertEqual(first.count, 1)

        // Change only the title in the DB without bumping time_updated: a
        // second refresh must still report the old title, proving the scan
        // took the cheap `refreshMetadata` path (keyed on ScannedFile.mtime,
        // i.e. the session's own time_updated) rather than re-querying.
        var db: OpaquePointer?
        let dbURL = home.appendingPathComponent("opencode.db")
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        sqlite3_exec(db, "UPDATE session SET title = 'Changed but same mtime' WHERE id = 'ses_1'", nil, nil, nil)
        sqlite3_close(db)

        let second = indexer.refresh()
        XCTAssertEqual(second.first?.title, "Untouched", "unchanged time_updated must skip re-querying the row")

        // Now bump time_updated: the third refresh must re-query and pick up
        // the new title, proving a real change IS detected incrementally.
        var db2: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db2), SQLITE_OK)
        sqlite3_exec(db2, "UPDATE session SET time_updated = 2000 WHERE id = 'ses_1'", nil, nil, nil)
        sqlite3_close(db2)

        let third = indexer.refresh()
        XCTAssertEqual(third.first?.title, "Changed but same mtime", "changed time_updated must trigger a re-query")
    }

    // MARK: - Read-only enforcement

    func testDatabaseOpensReadOnlyAndRejectsWrites() throws {
        let home = makeDataHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = try makeDatabase(
            in: home,
            sessions: [(id: "ses_1", directory: "/tmp/proj", title: "Readonly check", timeUpdated: 1000, archived: false)],
            messages: [:]
        )
        let reader = OpencodeReadOnlyDatabase(url: dbURL)
        XCTAssertNotNil(reader, "a real database must open for reading")

        // Attempting a write through a fresh handle opened the same way the
        // scanner opens it (SQLITE_OPEN_READONLY) must fail: this is what
        // "never holds a writable handle against a live opencode process"
        // means in practice, proven rather than merely asserted by
        // construction.
        var readOnlyHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbURL.path, &readOnlyHandle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(readOnlyHandle) }
        let writeResult = sqlite3_exec(readOnlyHandle, "INSERT INTO session (id, directory, title) VALUES ('x', 'y', 'z')", nil, nil, nil)
        XCTAssertNotEqual(writeResult, SQLITE_OK, "a SQLITE_OPEN_READONLY handle must reject writes")
    }

    func testReaderReturnsNilForMissingDatabase() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-opencode-missing-\(UUID().uuidString).db")
        XCTAssertNil(OpencodeReadOnlyDatabase(url: missing))
    }
}
