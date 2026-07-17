import AttacheCore
@testable import AttacheApp
import Foundation
import XCTest

/// Covers INF-357's FTS-index side: a "do not record" session is excluded
/// from indexing (mirroring the filter `AppModel.refreshSessionIndex` applies
/// before calling `reconcile`), and `forgetSession` retroactively purges an
/// already-indexed session's rows, verifying zero remain.
final class SessionContextRuntimeSessionPrivacyTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let runtime: SessionContextRuntime
    }

    private func makeFixture(sessions: [(id: String, title: String, turns: [String])]) throws -> (Fixture, [SessionRecord]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-session-privacy-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var records: [SessionRecord] = []
        for (offset, session) in sessions.enumerated() {
            let transcript = directory.appendingPathComponent("\(session.id).jsonl")
            try writeTranscript(session.turns, to: transcript)
            let content = session.turns.joined(separator: "\n").lowercased()
            records.append(SessionRecord(
                id: session.id,
                title: session.title,
                project: directory.path,
                threadName: nil,
                updatedAt: Date(timeIntervalSince1970: Double(1_000 + offset)),
                archived: false,
                filePath: transcript.path,
                fileMtime: Double(1_000 + offset),
                content: content,
                sourceKind: .codex
            ))
        }
        let runtime = SessionContextRuntime(databaseURL: directory.appendingPathComponent("SessionFTS.sqlite"))
        return (Fixture(directory: directory, runtime: runtime), records)
    }

    private func writeTranscript(_ turns: [String], to url: URL) throws {
        let lines = try turns.enumerated().map { offset, text -> String in
            let object: [String: Any] = [
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": offset.isMultiple(of: 2) ? "user" : "assistant",
                    "content": [["type": "input_text", "text": text]]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return try XCTUnwrap(String(data: data, encoding: .utf8))
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    // MARK: - Excluding a "do not record" session from indexing

    func testDoNotRecordSessionIsNeverIndexedWhileOtherSessionsStillAre() throws {
        let (fixture, records) = try makeFixture(sessions: [
            ("recorded", "Recorded session", ["a marker phrase for the recorded session"]),
            ("not-recorded", "Not recorded session", ["a marker phrase for the excluded session"])
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        var registry = SessionPrivacyRegistry(
            fileURL: fixture.directory.appendingPathComponent("SessionPrivacyRegistry.json")
        )
        XCTAssertTrue(registry.setRecordingDisabled(sessionID: "not-recorded"))

        // Mirrors AppModel.refreshSessionIndex's filter: excluded records
        // never reach `reconcile`, so the FTS indexer never indexes them and
        // the session never enters the in-memory catalog `freezeReviewSource`
        // (session-map building) reads from.
        let indexable = records.filter { !registry.isRecordingDisabled(sessionID: $0.id) }
        _ = fixture.runtime.reconcile(records: indexable)

        XCTAssertGreaterThan(fixture.runtime.ftsChunkCount(forSessionID: "recorded"), 0)
        XCTAssertEqual(fixture.runtime.ftsChunkCount(forSessionID: "not-recorded"), 0)

        let hits = fixture.runtime.commandKSearch("marker", includeArchived: true)
        XCTAssertTrue(hits.contains { $0.record.id == "recorded" })
        XCTAssertFalse(hits.contains { $0.record.id == "not-recorded" })
    }

    func testExistingIndexedRowsAreRemovedOnTheReconcileAfterBeingMarkedDoNotRecord() throws {
        let (fixture, records) = try makeFixture(sessions: [
            ("was-recorded", "Was recorded", ["content indexed before opting out"])
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        // First reconcile: indexed normally, before any privacy toggle.
        _ = fixture.runtime.reconcile(records: records)
        XCTAssertGreaterThan(fixture.runtime.ftsChunkCount(forSessionID: "was-recorded"), 0)

        // Now marked "do not record"; the next reconcile (the one
        // `refreshSessionIndex` would run on its next timer tick) must drop
        // the already-indexed rows since the session no longer appears in the
        // indexable set.
        var registry = SessionPrivacyRegistry(
            fileURL: fixture.directory.appendingPathComponent("SessionPrivacyRegistry.json")
        )
        XCTAssertTrue(registry.setRecordingDisabled(sessionID: "was-recorded"))
        let indexable = records.filter { !registry.isRecordingDisabled(sessionID: $0.id) }
        _ = fixture.runtime.reconcile(records: indexable)

        XCTAssertEqual(fixture.runtime.ftsChunkCount(forSessionID: "was-recorded"), 0)
    }

    // MARK: - Forget Session: retroactive scrub

    func testForgetSessionPurgesFTSRowsAndVerifiesZeroRemain() throws {
        let (fixture, records) = try makeFixture(sessions: [
            ("forget-me", "Forget me", ["some content that should be scrubbed entirely"]),
            ("keep-me", "Keep me", ["unrelated content that survives"])
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = fixture.runtime.reconcile(records: records)
        XCTAssertGreaterThan(fixture.runtime.ftsChunkCount(forSessionID: "forget-me"), 0)
        XCTAssertGreaterThan(fixture.runtime.ftsChunkCount(forSessionID: "keep-me"), 0)

        let remaining = fixture.runtime.forgetSession(sessionID: "forget-me")

        XCTAssertEqual(remaining, 0, "forgetSession must verify and report zero rows remain")
        XCTAssertEqual(fixture.runtime.ftsChunkCount(forSessionID: "forget-me"), 0)
        XCTAssertGreaterThan(fixture.runtime.ftsChunkCount(forSessionID: "keep-me"), 0, "an unrelated session must survive")

        let hits = fixture.runtime.commandKSearch("content", includeArchived: true)
        XCTAssertFalse(hits.contains { $0.record.id == "forget-me" })
    }
}
