import AttacheCore
@testable import AttacheApp
import Foundation
import SQLite3
import XCTest

/// INF-370: "Summarize any historic session into a voicemail card, across all
/// supported sources". Exercises `HistoricSessionSummarizer` against fixture
/// sessions for all four supported sources (claude_code, codex, grok_build,
/// opencode), the fail-closed authorization path, and the incompleteness
/// language path on a cancelled run. Mirrors the fixture/fake-stage-runner
/// pattern in `AttacheExhaustiveReviewRuntimeTests`.
final class HistoricSessionSummarizerTests: XCTestCase {
    private struct Harness {
        let root: URL
        let runtime: SessionContextRuntime
        let cardStore: CardStore
        let summarizer: HistoricSessionSummarizer
    }

    private func makeHarness() throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-historic-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runtime = SessionContextRuntime(databaseURL: root.appendingPathComponent("fts.sqlite"))
        let cardStore = try CardStore(databaseURL: root.appendingPathComponent("cards.sqlite"))
        let summarizer = HistoricSessionSummarizer(runtime: runtime, cardStore: cardStore)
        return Harness(root: root, runtime: runtime, cardStore: cardStore, summarizer: summarizer)
    }

    private func defaultOptions() -> HistoricSessionSummarizer.Options {
        HistoricSessionSummarizer.Options(
            strategy: .automatic,
            modelKey: "test-model",
            capability: .unknown,
            egressClass: "local",
            provider: "test-provider"
        )
    }

    // MARK: - Fixture builders (one per supported source)

    /// Codex's `response_item` JSONL shape.
    private func writeCodexTranscript(at url: URL) throws {
        let lines: [[String: Any]] = [
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "How do I fix the DNS forwarding bug?"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Restarted the resolver and it forwards correctly now."]]]]
        ]
        try write(lines: lines, to: url)
    }

    /// Claude Code's `user`/`assistant` + nested `message` JSONL shape.
    private func writeClaudeTranscript(at url: URL) throws {
        let lines: [[String: Any]] = [
            ["type": "user", "message": ["content": "Can you reconcile the 1120-S K-1?"]],
            ["type": "assistant", "message": ["content": "Reconciled the K-1 against the trial balance; no discrepancies."]]
        ]
        try write(lines: lines, to: url)
    }

    /// Grok Build's `chat_history.jsonl` shape: content sits directly on the
    /// record, not nested under `message` (INF-361 sampling; the case this
    /// ticket's `AttacheSessionReader.grokBuildTurn` gap-fix covers).
    private func writeGrokTranscript(at url: URL) throws {
        let lines: [[String: Any]] = [
            ["type": "user", "content": [["type": "text", "text": "Grok, add retries to the snapshot job."]]],
            ["type": "assistant", "content": "Added exponential backoff retries to the snapshot job."]
        ]
        try write(lines: lines, to: url)
    }

    private func write(lines: [[String: Any]], to url: URL) throws {
        var text = ""
        for object in lines {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            text += String(data: data, encoding: .utf8)! + "\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// opencode's shared SQLite database (INF-362 fixture pattern, mirrors
    /// `OpencodeSessionScannerTests`).
    private func writeOpencodeDatabase(at url: URL, sessionID: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
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
        exec("CREATE TABLE session (id text PRIMARY KEY, directory text, title text, parent_id text, time_updated integer, time_archived integer)")
        exec("CREATE TABLE message (id text PRIMARY KEY, session_id text, data text, time_created integer)")
        exec("CREATE TABLE part (id text PRIMARY KEY, message_id text, session_id text, data text)")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }

        exec("INSERT INTO session (id, directory, title, parent_id, time_updated, time_archived) VALUES (\(quote(sessionID)), \(quote("/tmp/opencode-proj")), \(quote("opencode fixture session")), NULL, 1000000, NULL)")

        func insertMessage(id: String, role: String, timeCreated: Double, text: String) {
            let dataText = String(data: try! JSONSerialization.data(withJSONObject: ["role": role]), encoding: .utf8)!
            exec("INSERT INTO message (id, session_id, data, time_created) VALUES (\(quote(id)), \(quote(sessionID)), \(quote(dataText)), \(Int64(timeCreated)))")
            let partText = String(data: try! JSONSerialization.data(withJSONObject: ["type": "text", "text": text]), encoding: .utf8)!
            exec("INSERT INTO part (id, message_id, session_id, data) VALUES (\(quote("\(id)-part0")), \(quote(id)), \(quote(sessionID)), \(quote(partText)))")
        }
        insertMessage(id: "msg-1", role: "user", timeCreated: 1_000_000_000, text: "opencode, clean up the retention job.")
        insertMessage(id: "msg-2", role: "assistant", timeCreated: 1_000_000_500, text: "Cleaned up the retention job and removed the stale entries.")
    }

    private func record(id: String, source: SourceKind, filePath: String, project: String) -> SessionRecord {
        SessionRecord(
            id: id, title: "\(source.displayName) fixture session", project: project, threadName: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000), archived: false, filePath: filePath,
            fileMtime: 1_000, content: "fixture", sourceKind: source
        )
    }

    // MARK: - Four-source fixture summary (four sources x correct attribution + receipt)

    func testFourSourceFixturesProduceAttributedSummaryCards() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let codexTranscript = harness.root.appendingPathComponent("codex.jsonl")
        try writeCodexTranscript(at: codexTranscript)
        let claudeTranscript = harness.root.appendingPathComponent("claude.jsonl")
        try writeClaudeTranscript(at: claudeTranscript)
        let grokTranscript = harness.root.appendingPathComponent("grok.jsonl")
        try writeGrokTranscript(at: grokTranscript)
        let opencodeDB = harness.root.appendingPathComponent("opencode.db")
        try writeOpencodeDatabase(at: opencodeDB, sessionID: "oc-sess-1")

        let records = [
            record(id: "codex-sess-1", source: .codex, filePath: codexTranscript.path, project: "/tmp/codex-proj"),
            record(id: "claude-sess-1", source: .claudeCode, filePath: claudeTranscript.path, project: "/tmp/claude-proj"),
            record(id: "grok-sess-1", source: .grokBuild, filePath: grokTranscript.path, project: "/tmp/grok-proj"),
            record(id: "oc-sess-1", source: .opencode, filePath: opencodeDB.path, project: "/tmp/opencode-proj")
        ]
        harness.runtime.reconcile(records: records)

        for rec in records {
            let request = HistoricSessionSummaryRequest(
                sessionID: rec.id, sourceKind: rec.sourceKind.rawValue,
                displayTitle: rec.title, workingDirectory: rec.project
            )
            let outcome = try runAsync {
                try await harness.summarizer.summarize(
                    request: request, options: self.defaultOptions(),
                    runStage: { evidence, _ in "Summary of \(rec.sourceKind.rawValue): \(evidence.prefix(20))" },
                    synthesize: { _ in "Spoken summary for \(rec.sourceKind.rawValue) session." }
                )
            }
            guard case .card(let card) = outcome else {
                XCTFail("\(rec.sourceKind.rawValue): expected a persisted card, got \(outcome)")
                continue
            }
            // Assertion 1: correct source attribution (badge/kind).
            XCTAssertEqual(card.sourceKind, rec.sourceKind.rawValue, "\(rec.sourceKind.rawValue): source badge mismatch")
            // Assertion 2: session provenance carried onto the card.
            XCTAssertEqual(card.externalSessionID, rec.id, "\(rec.sourceKind.rawValue): session id provenance mismatch")
            // Assertion 3: the spoken text made it through.
            XCTAssertTrue(card.spokenText.contains(rec.sourceKind.rawValue), "\(rec.sourceKind.rawValue): spoken text missing")
            // Assertion 4: a context receipt is attached.
            let stored = try harness.cardStore.fetchCard(id: card.id)
            XCTAssertTrue(
                stored.metadataJSON.contains(AttacheContextReceiptView.metadataKey),
                "\(rec.sourceKind.rawValue): context receipt not attached to the persisted card"
            )
        }
    }

    // MARK: - Fail-closed authorization (no focus grant -> no transcript read)

    func testUnknownSessionFailsClosedWithoutReadingAnyTranscript() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        // No records reconciled at all: the requested session cannot exist in
        // the index, so grantAppOwnedFocus must return nil.
        var stageCalled = false
        var synthesizeCalled = false
        let request = HistoricSessionSummaryRequest(
            sessionID: "never-indexed", sourceKind: SourceKind.codex.rawValue,
            displayTitle: "Not a real session", workingDirectory: nil
        )
        let outcome = try runAsync {
            try await harness.summarizer.summarize(
                request: request, options: self.defaultOptions(),
                runStage: { _, _ in stageCalled = true; return "should never run" },
                synthesize: { _ in synthesizeCalled = true; return "should never run" }
            )
        }
        guard case .failedClosed = outcome else {
            XCTFail("expected failedClosed, got \(outcome)")
            return
        }
        XCTAssertFalse(stageCalled, "no transcript stage may run without a focus grant")
        XCTAssertFalse(synthesizeCalled, "no synthesis may run without a focus grant")
    }

    func testMismatchedSourceKindFailsClosedEvenWhenSessionIDExists() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let codexTranscript = harness.root.appendingPathComponent("codex.jsonl")
        try writeCodexTranscript(at: codexTranscript)
        let rec = record(id: "codex-sess-1", source: .codex, filePath: codexTranscript.path, project: "/tmp/codex-proj")
        harness.runtime.reconcile(records: [rec])

        var stageCalled = false
        // Same session id, but the wrong source kind: must not be treated as
        // the codex session.
        let request = HistoricSessionSummaryRequest(
            sessionID: "codex-sess-1", sourceKind: SourceKind.claudeCode.rawValue,
            displayTitle: rec.title, workingDirectory: rec.project
        )
        let outcome = try runAsync {
            try await harness.summarizer.summarize(
                request: request, options: self.defaultOptions(),
                runStage: { _, _ in stageCalled = true; return "should never run" },
                synthesize: { _ in "should never run" }
            )
        }
        guard case .failedClosed = outcome else {
            XCTFail("expected failedClosed, got \(outcome)")
            return
        }
        XCTAssertFalse(stageCalled)
    }

    // MARK: - Ephemeral (don't-record) playback path

    func testPersistCardFalseProducesEphemeralOutcomeWithNoCardWritten() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let codexTranscript = harness.root.appendingPathComponent("codex.jsonl")
        try writeCodexTranscript(at: codexTranscript)
        let rec = record(id: "codex-sess-1", source: .codex, filePath: codexTranscript.path, project: "/tmp/codex-proj")
        harness.runtime.reconcile(records: [rec])

        var options = defaultOptions()
        options.persistCard = false
        let request = HistoricSessionSummaryRequest(
            sessionID: rec.id, sourceKind: rec.sourceKind.rawValue, displayTitle: rec.title, workingDirectory: rec.project
        )
        let outcome = try runAsync {
            try await harness.summarizer.summarize(
                request: request, options: options,
                runStage: { evidence, _ in "Stage summary: \(evidence.prefix(10))" },
                synthesize: { _ in "Ephemeral spoken summary." }
            )
        }
        guard case .ephemeral(let spokenText) = outcome else {
            XCTFail("expected ephemeral, got \(outcome)")
            return
        }
        XCTAssertTrue(spokenText.contains("Ephemeral spoken summary"))
        // Zero persisted cards: the store contains nothing at all.
        let allCards = try harness.cardStore.fetchCards(includeArchived: true, limit: nil)
        XCTAssertTrue(allCards.isEmpty, "ephemeral summaries must not persist a card")
    }

    // MARK: - Cancellation mid-run yields incomplete language

    func testCancelMidRunProducesIncompleteLanguageOnTheCard() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let codexTranscript = harness.root.appendingPathComponent("codex.jsonl")
        try writeCodexTranscript(at: codexTranscript)
        let rec = record(id: "codex-sess-1", source: .codex, filePath: codexTranscript.path, project: "/tmp/codex-proj")
        harness.runtime.reconcile(records: [rec])

        let request = HistoricSessionSummaryRequest(
            sessionID: rec.id, sourceKind: rec.sourceKind.rawValue, displayTitle: rec.title, workingDirectory: rec.project
        )
        var synthesizedSourceText = ""
        let outcome = try runAsync {
            try await harness.summarizer.summarize(
                request: request, options: self.defaultOptions(),
                cancel: { true }, // cancel before any stage completes
                runStage: { _, _ in XCTFail("a cancelled run must not execute a stage"); return "" },
                synthesize: { prompt in
                    synthesizedSourceText = prompt.messages.map(\.content).joined(separator: "\n")
                    return "Partial spoken summary."
                }
            )
        }
        guard case .card(let card) = outcome else {
            XCTFail("expected a card even for a cancelled run, got \(outcome)")
            return
        }
        XCTAssertTrue(synthesizedSourceText.lowercased().contains("canceled"), "the synthesis input must carry the incompleteness notice")
        XCTAssertEqual(card.metadataJSON.contains("canceled"), true, "the persisted card's metadata must record incomplete coverage")
    }

    // MARK: - Async helper (XCTest has no native async test wait on this toolchain path)

    private func runAsync<T>(_ operation: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
        Task {
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result!.get()
    }
}
