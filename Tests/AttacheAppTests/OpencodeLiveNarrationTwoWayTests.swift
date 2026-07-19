import AppKit
import AttacheCore
import SQLite3
import XCTest
@testable import AttacheApp

/// INF-397: the opencode live watcher (`OpencodeLiveWatcher`) and the two-way
/// delivered-reply fallback (`fileDeliveredReplyFallbackIfUnlinked`, INF-395/396)
/// must coexist: a delivered instruction whose reply the live watcher narrates
/// produces EXACTLY ONE card, linked to the instruction, and the fallback then
/// backs off because the instruction is no longer awaiting a card.
///
/// This drives the real path end to end: a fixture `opencode.db` reached through
/// `XDG_DATA_HOME` (so both the model's `OpencodeLiveWatcher` and its
/// `TwoWayCoordinator` resolve the same database), and correlation via the
/// SQLite positional path.
@MainActor
final class OpencodeLiveNarrationTwoWayTests: XCTestCase {
    /// Builds `$XDG_DATA_HOME/opencode/opencode.db` with the observed schema and
    /// inserts fixture rows. `time_created` is stored in milliseconds, the way
    /// the real DB stores it.
    @discardableResult
    private func writeDatabase(
        at dbURL: URL,
        session: (id: String, directory: String, title: String, timeUpdated: Double),
        messages: [(id: String, role: String, finish: String?, timeMillis: Int64, text: String?)]
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func exec(_ sql: String) {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, "SQL failed: \(sql)")
        }
        func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }
        exec("CREATE TABLE session (id text PRIMARY KEY, directory text, title text, parent_id text, time_updated integer, time_archived integer)")
        exec("CREATE TABLE message (id text PRIMARY KEY, session_id text, data text, time_created integer)")
        exec("CREATE TABLE part (id text PRIMARY KEY, message_id text, session_id text, data text)")
        exec("INSERT INTO session (id, directory, title, parent_id, time_updated, time_archived) VALUES (\(quote(session.id)), \(quote(session.directory)), \(quote(session.title)), NULL, \(Int64(session.timeUpdated * 1000)), NULL)")
        try insertMessages(db: db, sessionID: session.id, messages: messages, exec: exec, quote: quote)
        return dbURL
    }

    /// Appends more messages to an existing fixture database (the reply landing
    /// after the delivery checkpoint). A fresh row grows the file, so the
    /// watcher's size-based change token detects it.
    private func appendMessages(
        to dbURL: URL,
        sessionID: String,
        messages: [(id: String, role: String, finish: String?, timeMillis: Int64, text: String?)]
    ) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func exec(_ sql: String) {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, "SQL failed: \(sql)")
        }
        func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }
        try insertMessages(db: db, sessionID: sessionID, messages: messages, exec: exec, quote: quote)
    }

    private func insertMessages(
        db: OpaquePointer?,
        sessionID: String,
        messages: [(id: String, role: String, finish: String?, timeMillis: Int64, text: String?)],
        exec: (String) -> Void,
        quote: (String) -> String
    ) throws {
        for message in messages {
            var dataObject: [String: Any] = ["role": message.role]
            if let finish = message.finish { dataObject["finish"] = finish }
            let dataText = String(data: try JSONSerialization.data(withJSONObject: dataObject), encoding: .utf8)!
            exec("INSERT INTO message (id, session_id, data, time_created) VALUES (\(quote(message.id)), \(quote(sessionID)), \(quote(dataText)), \(message.timeMillis))")
            if let text = message.text {
                let partText = String(data: try JSONSerialization.data(withJSONObject: ["type": "text", "text": text]), encoding: .utf8)!
                exec("INSERT INTO part (id, message_id, session_id, data) VALUES (\(quote(message.id + "-p")), \(quote(message.id)), \(quote(sessionID)), \(quote(partText)))")
            }
        }
    }

    func testLiveWatcherNarratesDeliveredReplyExactlyOnceAndLinks() async throws {
        _ = NSApplication.shared
        setenv("ATTACHE_FORCE_PLAIN_READBACK", "1", 1)
        setenv("ATTACHE_DISABLE_TOPIC_TAGGING", "1", 1)
        defer {
            unsetenv("ATTACHE_FORCE_PLAIN_READBACK")
            unsetenv("ATTACHE_DISABLE_TOPIC_TAGGING")
        }

        let xdg = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-xdg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: xdg) }
        setenv("XDG_DATA_HOME", xdg.path, 1)
        defer { unsetenv("XDG_DATA_HOME") }
        let dbURL = OpencodePaths.databaseURL()
        XCTAssertEqual(dbURL.path, xdg.appendingPathComponent("opencode/opencode.db").path)

        let sessionID = "ses_live_\(UUID().uuidString.prefix(8).lowercased())"
        // Pre-delivery state: one completed assistant turn at T=1000ms. The
        // delivery checkpoint is captured here, before the reply lands.
        try writeDatabase(
            at: dbURL,
            session: (id: sessionID, directory: "/Users/tester/proj", title: "Live opencode", timeUpdated: 1),
            messages: [
                (id: "m1", role: "user", finish: nil, timeMillis: 500, text: "start"),
                (id: "m2", role: "assistant", finish: "stop", timeMillis: 1000, text: "prior answer")
            ]
        )

        let store = try CardStore.inMemory()
        let model = AppModel(store: store)
        model.voicemailMode = false

        // A delivered opencode instruction whose reply hasn't been filed yet.
        let delivered = Instruction(
            id: "instr-live-1",
            sessionID: sessionID,
            sourceKind: SourceKind.opencode.rawValue,
            text: "give the final answer",
            state: .delivered,
            createdAt: Date(),
            deliveredAt: Date(),
            resultingCardID: nil,
            targetDisplayName: "Live opencode",
            deliveryCheckpoint: 1000,
            deliveryReplyText: "the delivered reply",
            workingDirectory: "/Users/tester/proj"
        )
        try store.upsertInstruction(delivered)

        // Register the session with the live watcher: first registration sets its
        // checkpoint at the current latest completed turn (T=1000), so the
        // backlog is not narrated.
        let target = CodexSessionTarget(
            id: sessionID, title: "Live opencode", updatedAt: Date(),
            category: .activeSession, sourceKind: .opencode
        )
        model.watchOpencodeSessionForTesting(target)

        // The reply lands as a new completed assistant turn after the checkpoint.
        try appendMessages(
            to: dbURL,
            sessionID: sessionID,
            messages: [(id: "m3", role: "assistant", finish: "stop", timeMillis: 2000, text: "the delivered reply")]
        )

        // Drive the watcher: it narrates the reply through receive -> persist,
        // which files a card and links it via the SQLite positional path.
        model.pollOpencodeLiveWatcherForTesting()
        try await waitUntil { model.cards.contains { $0.externalSessionID == sessionID } }

        let sessionCards = model.cards.filter { $0.externalSessionID == sessionID }
        XCTAssertEqual(sessionCards.count, 1, "the live watcher files exactly one card")
        XCTAssertEqual(sessionCards.first?.sourceKind, SourceKind.opencode.rawValue)
        XCTAssertTrue(sessionCards.first?.rawText.contains("the delivered reply") ?? false)

        // The card linked to the delivered instruction, so it is no longer
        // awaiting: the delivered-reply fallback must now back off with no dupe.
        let linked = model.twoWay.log.first { $0.id == "instr-live-1" }
        XCTAssertEqual(linked?.resultingCardID, sessionCards.first?.id, "the watcher's card links to the instruction")
        XCTAssertFalse(model.twoWay.isDeliveredAwaitingCard(instructionID: "instr-live-1", sessionID: sessionID))

        model.fileDeliveredReplyFallbackIfUnlinked(delivered)
        XCTAssertEqual(
            model.cards.filter { $0.externalSessionID == sessionID }.count, 1,
            "the fallback must not double-file once the live watcher already linked a card"
        )
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("timed out waiting for the live-narration card")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
