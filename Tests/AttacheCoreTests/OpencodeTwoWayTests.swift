import XCTest
import SQLite3
@testable import AttacheCore

/// INF-395: SQLite-backed two-way readiness and positional reply correlation
/// for opencode. Readiness/correlation are pure over `MessageRow` values, and
/// the snapshot loader is exercised against a miniature fixture database built
/// with the observed schema (session/message/part), mirroring
/// `OpencodeSessionScannerTests`. No real `opencode` process or user data is
/// touched.
final class OpencodeTwoWayTests: XCTestCase {
    private typealias MessageRow = OpencodeTranscriptAdapter.MessageRow
    private typealias PartRow = OpencodeTranscriptAdapter.PartRow

    private func text(_ value: String) -> PartRow { PartRow(type: "text", text: value) }
    private func tool() -> PartRow { PartRow(type: "tool", text: nil) }

    private func user(_ id: String, at time: Double, _ body: String) -> MessageRow {
        MessageRow(id: id, role: "user", finish: nil, timeCreated: time, parts: [text(body)])
    }
    /// A completed assistant turn (`finish == "stop"`).
    private func assistantDone(_ id: String, at time: Double, _ body: String, parts extra: [PartRow] = []) -> MessageRow {
        MessageRow(id: id, role: "assistant", finish: "stop", timeCreated: time, parts: extra + [text(body)])
    }
    /// An in-progress assistant turn (no `finish`), e.g. mid tool call.
    private func assistantPending(_ id: String, at time: Double, parts: [PartRow]) -> MessageRow {
        MessageRow(id: id, role: "assistant", finish: nil, timeCreated: time, parts: parts)
    }

    // MARK: - Readiness

    func testReadyWhenLatestIsCompletedAssistantTurn() {
        let messages = [
            user("m1", at: 1000, "fix the bug"),
            assistantDone("m2", at: 2000, "fixed and tested")
        ]
        XCTAssertTrue(OpencodeDeliveryReadiness.isReady(messages: messages))
    }

    func testNotReadyWhenLatestAssistantTurnStillRunningATool() {
        let messages = [
            user("m1", at: 1000, "fix the bug"),
            assistantPending("m2", at: 2000, parts: [text("looking into it"), tool()])
        ]
        XCTAssertFalse(OpencodeDeliveryReadiness.isReady(messages: messages), "a mid-tool turn (finish == nil) is not ready")
    }

    func testNotReadyWhenLatestMessageIsUser() {
        let messages = [
            assistantDone("m1", at: 1000, "earlier reply"),
            user("m2", at: 2000, "and now do this")
        ]
        XCTAssertFalse(OpencodeDeliveryReadiness.isReady(messages: messages), "a trailing user turn means the agent hasn't replied")
    }

    func testNotReadyWhenEmpty() {
        XCTAssertFalse(OpencodeDeliveryReadiness.isReady(messages: []))
    }

    func testCheckpointIsLatestMessageTimeOrZero() {
        XCTAssertEqual(OpencodeDeliveryReadiness.checkpoint(messages: []), 0)
        let messages = [user("m1", at: 1000, "a"), assistantDone("m2", at: 2500, "b")]
        XCTAssertEqual(OpencodeDeliveryReadiness.checkpoint(messages: messages), 2500)
    }

    // MARK: - Correlation

    func testCorrelationSimpleFirstCompletedAssistantTurnAfterCheckpoint() {
        // Checkpoint 2000 = pre-delivery state. The delivered user turn (3000)
        // and its completed assistant reply (4000) both follow it; the reply is
        // the correlated turn.
        let messages = [
            user("m1", at: 1000, "old prompt"),
            assistantDone("m2", at: 2000, "old reply"),
            user("m3", at: 3000, "reply exactly PONG"),
            assistantDone("m4", at: 4000, "PONG")
        ]
        let reply = OpencodeReplyCorrelation.firstCompletedAssistantTurn(messages: messages, afterCheckpoint: 2000)
        XCTAssertEqual(reply?.text, "PONG")
        XCTAssertEqual(reply?.timeCreated, 4000)
    }

    func testCorrelationSkipsInterleavedToolAndNonFinalTurns() {
        // After the checkpoint: a user turn, an in-progress assistant turn with
        // a pending tool, then the completed assistant reply. Only the last is
        // returned.
        let messages = [
            assistantDone("m1", at: 1000, "prior"),
            user("m2", at: 2000, "do the thing"),
            assistantPending("m3", at: 3000, parts: [text("running a tool"), tool()]),
            assistantDone("m4", at: 4000, "all done")
        ]
        let reply = OpencodeReplyCorrelation.firstCompletedAssistantTurn(messages: messages, afterCheckpoint: 1000)
        XCTAssertEqual(reply?.text, "all done")
    }

    func testCorrelationTwoInstructionsAreDistinguishedByCheckpoint() {
        let messages = [
            user("m1", at: 1000, "first instruction"),
            assistantDone("m2", at: 2000, "REPLY_ONE"),
            user("m3", at: 3000, "second instruction"),
            assistantDone("m4", at: 4000, "REPLY_TWO")
        ]
        // Instruction 1 checkpoint (pre-delivery: 1000, the old user turn was
        // its trigger) -> first completed assistant after 1000 is REPLY_ONE.
        XCTAssertEqual(
            OpencodeReplyCorrelation.firstCompletedAssistantTurn(messages: messages, afterCheckpoint: 1000)?.text,
            "REPLY_ONE"
        )
        // Instruction 2 checkpoint = REPLY_ONE's time (2000) -> REPLY_TWO.
        XCTAssertEqual(
            OpencodeReplyCorrelation.firstCompletedAssistantTurn(messages: messages, afterCheckpoint: 2000)?.text,
            "REPLY_TWO"
        )
    }

    func testCorrelationReturnsNilWhenReplyHasNotLandedYet() {
        let messages = [
            assistantDone("m1", at: 1000, "prior"),
            user("m2", at: 2000, "do the thing")
        ]
        XCTAssertNil(OpencodeReplyCorrelation.firstCompletedAssistantTurn(messages: messages, afterCheckpoint: 1000))
    }

    // MARK: - Snapshot loader against a fixture database

    func testSnapshotLoadReadsDirectoryAndOrderedMessages() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-opencode-twoway-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = try makeDatabase(
            in: home,
            session: (id: "ses_1", directory: "/Users/tester/proj", timeUpdated: 4000),
            messages: [
                (id: "m1", role: "user", finish: nil, time: 1000, parts: [("text", "reply exactly PONG")]),
                (id: "m2", role: "assistant", finish: "stop", time: 2000, parts: [("text", "PONG")])
            ]
        )

        let snapshot = try XCTUnwrap(OpencodeSessionSnapshot.load(sessionID: "ses_1", databaseURL: dbURL))
        XCTAssertEqual(snapshot.directory, "/Users/tester/proj")
        XCTAssertEqual(snapshot.messages.count, 2)
        XCTAssertTrue(OpencodeDeliveryReadiness.isReady(messages: snapshot.messages))
        let reply = OpencodeReplyCorrelation.firstCompletedAssistantTurn(messages: snapshot.messages, afterCheckpoint: 1000)
        XCTAssertEqual(reply?.text, "PONG")
    }

    func testSnapshotLoadReturnsNilForMissingSession() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-opencode-twoway-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = try makeDatabase(
            in: home,
            session: (id: "ses_1", directory: "/tmp/p", timeUpdated: 1000),
            messages: []
        )
        XCTAssertNil(OpencodeSessionSnapshot.load(sessionID: "does-not-exist", databaseURL: dbURL))
    }

    // MARK: - Fixture DB helper (observed schema, no real content)

    @discardableResult
    private func makeDatabase(
        in dataHome: URL,
        session: (id: String, directory: String, timeUpdated: Double),
        messages: [(id: String, role: String, finish: String?, time: Double, parts: [(type: String, text: String?)])]
    ) throws -> URL {
        try FileManager.default.createDirectory(at: dataHome, withIntermediateDirectories: true)
        let dbURL = dataHome.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        func exec(_ sql: String) {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, "exec failed: \(sql)")
        }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }

        exec("CREATE TABLE session (id text PRIMARY KEY, directory text, title text, parent_id text, time_updated integer, time_archived integer)")
        exec("CREATE TABLE message (id text PRIMARY KEY, session_id text, data text, time_created integer)")
        exec("CREATE TABLE part (id text PRIMARY KEY, message_id text, session_id text, data text)")

        exec("""
            INSERT INTO session (id, directory, title, parent_id, time_updated, time_archived)
            VALUES (\(quote(session.id)), \(quote(session.directory)), 'Title', NULL, \(Int64(session.timeUpdated)), NULL)
            """)
        for message in messages {
            var data: [String: Any] = ["role": message.role]
            if let finish = message.finish { data["finish"] = finish }
            let dataText = String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self)
            exec("""
                INSERT INTO message (id, session_id, data, time_created)
                VALUES (\(quote(message.id)), \(quote(session.id)), \(quote(dataText)), \(Int64(message.time)))
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
        return dbURL
    }
}
