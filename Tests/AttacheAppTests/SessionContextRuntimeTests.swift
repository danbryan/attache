import AttacheCore
@testable import AttacheApp
import Foundation
import XCTest

final class SessionContextRuntimeTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let runtime: SessionContextRuntime
        let records: [SessionRecord]
    }

    private func makeFixture(
        sessions: [(id: String, title: String, turns: [String])],
        readHooks: SessionContextReadHooks = SessionContextReadHooks()
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-session-runtime-\(UUID().uuidString)", isDirectory: true)
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
        let runtime = SessionContextRuntime(
            databaseURL: directory.appendingPathComponent("SessionFTS.sqlite"),
            readHooks: readHooks
        )
        runtime.reconcile(records: records)
        return Fixture(directory: directory, runtime: runtime, records: records)
    }

    private func writeTranscript(_ turns: [String], to url: URL) throws {
        try transcriptData(turns).write(to: url)
    }

    private func transcriptData(_ turns: [String]) throws -> Data {
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
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func writeClaudeTranscript(_ turns: [String], cwd: String, to url: URL) throws {
        let lines = try turns.enumerated().map { offset, text -> String in
            let role = offset.isMultiple(of: 2) ? "user" : "assistant"
            let object: [String: Any] = [
                "type": role,
                "cwd": cwd,
                "message": ["role": role, "content": text]
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return try XCTUnwrap(String(data: data, encoding: .utf8))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func commandKGrant(
        _ runtime: SessionContextRuntime,
        query: String
    ) throws -> AttacheFocusGrant {
        let row = try XCTUnwrap(runtime.commandKSearch(
            query,
            includeArchived: true,
            now: Date(timeIntervalSince1970: 10_000)
        ).first)
        return try runtime.grantCommandKSelection(row)
    }

    private func assertTranscriptOperationFails(
        _ operation: String,
        tools: SessionContextToolRuntime,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let failed: Bool
        switch operation {
        case "inspect":
            if case .failure = tools.inspectTranscript() { failed = true } else { failed = false }
        case "search":
            if case .failure = tools.searchTranscript(query: "authorized") { failed = true } else { failed = false }
        case "read":
            if case .failure = tools.readTranscript(turnOrdinal: 1) { failed = true } else { failed = false }
        default:
            XCTFail("Unknown transcript test operation \(operation)", file: file, line: line)
            return
        }
        XCTAssertTrue(failed, message, file: file, line: line)
    }

    func testCommandKSearchNeverGrantsFocus() throws {
        let fixture = try makeFixture(sessions: [
            ("alpha", "Alpha router", ["alpha router dns marker"])
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let before = fixture.runtime.authoritySnapshot()
        let rows = fixture.runtime.commandKSearch("router", includeArchived: true)
        let after = fixture.runtime.authoritySnapshot()

        XCTAssertEqual(rows.map(\.record.id), ["alpha"])
        XCTAssertNil(before.session)
        XCTAssertNil(after.session)
        XCTAssertEqual(after.epoch, before.epoch)
    }

    func testAppOwnedFocusRequiresAnExactIndexedRecord() throws {
        let fixture = try makeFixture(sessions: [
            ("indexed", "Indexed title", ["indexed focus marker"])
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let before = fixture.runtime.authoritySnapshot()

        XCTAssertNil(fixture.runtime.grantAppOwnedFocus(
            sessionID: "model-invented-id",
            sourceKind: SourceKind.codex.rawValue,
            displayTitle: "Caller supplied title",
            workingDirectory: "/tmp/caller-supplied"
        ))
        XCTAssertNil(fixture.runtime.grantAppOwnedFocus(
            sessionID: "indexed",
            sourceKind: SourceKind.claudeCode.rawValue,
            displayTitle: "Caller supplied title",
            workingDirectory: "/tmp/caller-supplied"
        ))

        let after = fixture.runtime.authoritySnapshot()
        XCTAssertNil(after.session)
        XCTAssertEqual(after.epoch, before.epoch)

        let grant = try XCTUnwrap(fixture.runtime.grantAppOwnedFocus(
            sessionID: "indexed",
            sourceKind: SourceKind.codex.rawValue,
            displayTitle: "Forged title",
            workingDirectory: "/tmp/forged"
        ))
        XCTAssertEqual(grant.session.displayTitle, "Indexed title")
        XCTAssertEqual(grant.session.workingDirectory, fixture.directory.path)
    }

    func testCommandKAndModelDiscoveryShareStableOrdering() throws {
        let fixture = try makeFixture(sessions: [
            ("aaa", "Shared needle", ["needle common marker"]),
            ("bbb", "Shared needle", ["needle common marker"]),
            ("ccc", "Other", ["needle common marker"])
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now = Date(timeIntervalSince1970: 10_000)

        let commandK = fixture.runtime.commandKSearch(
            "needle",
            includeArchived: true,
            now: now
        )
        let discovery = try fixture.runtime.beginDiscovery(
            AttacheSessionDiscoveryRequest(
                query: AttacheSessionDiscoveryQuery(text: "needle"),
                triggeringUserTurn: "Remember the needle session?"
            ),
            now: now
        )

        XCTAssertEqual(
            commandK.map(\.record.id),
            discovery.orderedResults.map(\.record.id)
        )
        XCTAssertNil(fixture.runtime.authoritySnapshot().session)
    }

    func testDiscoveryIgnoresForgedMetadataAndRejectsForgedID() throws {
        let fixture = try makeFixture(sessions: [
            ("real", "Real app title", ["forgery marker"])
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let discovery = try fixture.runtime.beginDiscovery(AttacheSessionDiscoveryRequest(
            query: AttacheSessionDiscoveryQuery(text: "forgery"),
            triggeringUserTurn: "Find the forgery session"
        ))
        let forged = AttacheSessionDiscoverySelection(
            sessionID: "real",
            sourceKind: SourceKind.codex.rawValue,
            displayTitle: "Model supplied fake title",
            workingDirectory: fixture.directory.path
        )

        let grant = try fixture.runtime.grantDiscoverySelection(
            token: discovery.token,
            selection: forged
        )
        XCTAssertEqual(grant.session.sessionID, "real")
        XCTAssertEqual(grant.session.sourceKind, SourceKind.codex.rawValue)
        XCTAssertEqual(grant.session.displayTitle, "Real app title")
        XCTAssertEqual(grant.session.workingDirectory, fixture.directory.path)

        let second = try fixture.runtime.beginDiscovery(AttacheSessionDiscoveryRequest(
            query: AttacheSessionDiscoveryQuery(text: "forgery"),
            triggeringUserTurn: "Find the forgery session again"
        ))
        let fakeID = AttacheSessionDiscoverySelection(
            sessionID: "model-invented-id",
            sourceKind: SourceKind.codex.rawValue,
            displayTitle: "Forged",
            workingDirectory: fixture.directory.path
        )
        XCTAssertThrowsError(try fixture.runtime.grantDiscoverySelection(
            token: second.token,
            selection: fakeID
        ))
        XCTAssertEqual(fixture.runtime.authoritySnapshot().session, grant.session)
    }

    func testDiscoveryRejectsInvalidAndOversizedQueries() throws {
        let fixture = try makeFixture(sessions: [
            ("real", "Real", ["query marker"])
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertThrowsError(try fixture.runtime.beginDiscovery(
            AttacheSessionDiscoveryRequest(
                query: AttacheSessionDiscoveryQuery(text: "   "),
                triggeringUserTurn: "blank"
            )
        ))
        XCTAssertThrowsError(try fixture.runtime.beginDiscovery(
            AttacheSessionDiscoveryRequest(
                query: AttacheSessionDiscoveryQuery(
                    text: String(repeating: "x", count: AttacheSessionDiscoveryCoordinator.maxQueryLength + 1)
                ),
                triggeringUserTurn: "huge"
            )
        ))
    }

    func testFocusRaceRevokesFrozenTranscriptTools() throws {
        let fixture = try makeFixture(sessions: [
            ("alpha", "Alpha", ["alpha evidence"]),
            ("bravo", "Bravo", ["bravo evidence"])
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let alphaGrant = try commandKGrant(fixture.runtime, query: "alpha")
        let alphaTools = try XCTUnwrap(fixture.runtime.makeToolRuntime(
            frozenSession: alphaGrant.session,
            toolReserveTokens: 1_024
        ))
        let bravoGrant = try commandKGrant(fixture.runtime, query: "bravo")

        XCTAssertGreaterThan(bravoGrant.epoch, alphaGrant.epoch)
        switch alphaTools.readTranscript(turnOrdinal: 1) {
        case .success:
            XCTFail("A tool frozen to the prior focus epoch must not read after focus changes")
        case .failure(let error):
            XCTAssertEqual(error, .authorizationExpired)
        }
        XCTAssertEqual(
            alphaTools.readFile(path: fixture.directory.appendingPathComponent("never-open.txt").path),
            .failure(.authorizationExpired),
            "A revoked tool must reject before touching a project-file path"
        )
    }

    func testBeginningMiddleAndEndTurnsAreIndividuallyRetrievable() throws {
        let fixture = try makeFixture(sessions: [
            ("range", "Range", [
                "unique beginning fact",
                "unique middle fact",
                "unique ending fact"
            ])
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let grant = try commandKGrant(fixture.runtime, query: "range")
        let tools = try XCTUnwrap(fixture.runtime.makeToolRuntime(
            frozenSession: grant.session,
            toolReserveTokens: 4_096
        ))

        let beginning = try tools.readTranscript(turnOrdinal: 1).get()
        let middle = try tools.readTranscript(turnOrdinal: 2).get()
        let ending = try tools.readTranscript(turnOrdinal: 3).get()
        XCTAssertTrue(beginning.content.contains("unique beginning fact"))
        XCTAssertTrue(middle.content.contains("unique middle fact"))
        XCTAssertTrue(ending.content.contains("unique ending fact"))
        XCTAssertTrue(beginning.isQuotedEvidence)
        XCTAssertTrue(middle.isQuotedEvidence)
        XCTAssertTrue(ending.isQuotedEvidence)
    }

    func testLargeTranscriptRuntimeInitializationAndEarlyReadStayStreaming() throws {
        let turns = (1...10_000).map { ordinal in
            ordinal == 1
                ? "large-stream first turn"
                : "large-stream filler turn \(ordinal)"
        }
        let fixture = try makeFixture(sessions: [
            ("large-stream", "Large stream", turns)
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let grant = try commandKGrant(fixture.runtime, query: "large-stream")
        let transcriptURL = URL(fileURLWithPath: fixture.records[0].filePath)

        // A whole-file UTF-8 decode fails on this tail byte. The first turn is
        // still independently valid JSONL, so a truly streaming reader can
        // initialize without touching content and stop after that first turn.
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0xFF]))
        try handle.close()

        let tools = try XCTUnwrap(fixture.runtime.makeToolRuntime(
            frozenSession: grant.session,
            toolReserveTokens: 4_096
        ))
        XCTAssertEqual(
            tools.transcriptStreamingDiagnostics,
            SessionContextToolRuntime.TranscriptStreamingDiagnostics(
                visitedTurns: 0,
                peakRetainedTurns: 0
            ),
            "initialization must freeze only cheap file identity"
        )

        let first = try tools.readTranscript(turnOrdinal: 1).get()
        XCTAssertTrue(first.content.contains("large-stream first turn"))
        XCTAssertEqual(tools.transcriptStreamingDiagnostics.visitedTurns, 1)
        XCTAssertLessThanOrEqual(
            tools.transcriptStreamingDiagnostics.peakRetainedTurns,
            1,
            "an early range read must retain only its requested turn"
        )

        let inspection = try tools.inspectTranscript().get()
        XCTAssertEqual(inspection.turnCount, turns.count)
        XCTAssertEqual(tools.transcriptStreamingDiagnostics.visitedTurns, turns.count)
        XCTAssertLessThanOrEqual(
            tools.transcriptStreamingDiagnostics.peakRetainedTurns,
            AttacheProgressiveTranscriptTools.outlineTurnCount * 2
        )

        let hits = try tools.searchTranscript(query: "filler", maxResults: 3).get()
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(tools.transcriptStreamingDiagnostics.visitedTurns, turns.count)
        XCTAssertLessThanOrEqual(
            tools.transcriptStreamingDiagnostics.peakRetainedTurns,
            3,
            "search must retain only its bounded top-k candidates"
        )
        XCTAssertTrue(hits.allSatisfy {
            $0.locator.contentVersion == inspection.contentVersion
        })
    }

    func testProductionCodexAndClaudeScannersDiscoverCompleteTranscripts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-production-search-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let codexHome = directory.appendingPathComponent("codex", isDirectory: true)
        let codexSessions = codexHome.appendingPathComponent("sessions/2026/07", isDirectory: true)
        let claudeHome = directory.appendingPathComponent("claude", isDirectory: true)
        let claudeProject = claudeHome.appendingPathComponent("projects/test", isDirectory: true)
        try FileManager.default.createDirectory(at: codexSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeProject, withIntermediateDirectories: true)

        let codexID = "11111111-1111-4111-8111-111111111111"
        let claudeID = "22222222-2222-4222-8222-222222222222"
        let filler = String(repeating: "ordinary filler words ", count: 20_000)
        try writeTranscript([
            "codex-beginning-orchid",
            filler,
            "codex-middle-saffron",
            filler,
            "codex-ending-tamarind"
        ], to: codexSessions.appendingPathComponent("rollout-2026-07-15-\(codexID).jsonl"))
        try writeClaudeTranscript([
            "claude-beginning-juniper",
            filler,
            "claude-middle-magnolia",
            filler,
            "claude-ending-persimmon"
        ], cwd: directory.path, to: claudeProject.appendingPathComponent("\(claudeID).jsonl"))

        let codexScanner = CodexSessionScanner(codexHome: codexHome)
        codexScanner.beginScan()
        let codexFile = try XCTUnwrap(codexScanner.enumerateFiles().first)
        let codexRecord = codexScanner.makeRecord(for: codexFile, priorTopicTag: nil, contentCap: 8_000)
        let claudeScanner = ClaudeCodeSessionScanner(claudeHome: claudeHome)
        claudeScanner.beginScan()
        let claudeFile = try XCTUnwrap(claudeScanner.enumerateFiles().first)
        let claudeRecord = claudeScanner.makeRecord(for: claudeFile, priorTopicTag: nil, contentCap: 8_000)

        XCTAssertFalse(codexRecord.content.contains("codex-ending-tamarind"), "precondition: legacy digest is capped")
        XCTAssertFalse(claudeRecord.content.contains("claude-ending-persimmon"), "precondition: legacy digest is capped")

        let runtime = SessionContextRuntime(databaseURL: directory.appendingPathComponent("SessionFTS.sqlite"))
        runtime.reconcile(records: [codexRecord, claudeRecord])
        let expected: [(String, String)] = [
            ("codex-beginning-orchid", codexID),
            ("codex-middle-saffron", codexID),
            ("codex-ending-tamarind", codexID),
            ("claude-beginning-juniper", claudeID),
            ("claude-middle-magnolia", claudeID),
            ("claude-ending-persimmon", claudeID)
        ]
        for (query, sessionID) in expected {
            XCTAssertEqual(
                runtime.commandKSearch(query, includeArchived: true).first?.record.id,
                sessionID,
                "production FTS must search the complete source transcript for \(query)"
            )
        }
        XCTAssertNil(runtime.authoritySnapshot().session, "search must never grant focus")
    }

    func testGiantEvidenceIsBoundedByOneCumulativeReserve() throws {
        let giant = "GIANT-BEGIN " + String(repeating: "bounded evidence ", count: 30_000) + " GIANT-END"
        let fixture = try makeFixture(sessions: [("giant", "Giant", [giant])])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let grant = try commandKGrant(fixture.runtime, query: "giant")
        let tools = try XCTUnwrap(fixture.runtime.makeToolRuntime(
            frozenSession: grant.session,
            strategy: .efficient,
            toolReserveTokens: 512
        ))

        let first = tools.execute(
            name: "read_session_transcript",
            arguments: #"{"start_turn":1,"max_chars":99999999}"#
        )
        XCTAssertLessThan(first.count, 5_000)
        XCTAssertFalse(first.contains("GIANT-END"))
        XCTAssertLessThan(tools.remainingToolTokens, 512)

        var terminal = ""
        for _ in 0..<20 {
            terminal = tools.execute(
                name: "read_session_transcript",
                arguments: #"{"start_turn":1,"max_chars":99999999}"#
            )
            if terminal.localizedCaseInsensitiveContains("budget") { break }
        }
        XCTAssertTrue(terminal.localizedCaseInsensitiveContains("budget"))
        XCTAssertLessThan(
            tools.remainingToolTokens,
            AttacheToolBudgetEnforcer.maxCharsFloor,
            "a remainder too small for the minimum bounded result is unusable and must stay fail-closed"
        )
    }

    func testPathEscapeCredentialsAndChangedFilesFailClosed() throws {
        let fixture = try makeFixture(sessions: [
            ("files", "Files", ["file safety marker"])
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let plain = fixture.directory.appendingPathComponent("notes.txt")
        let credential = fixture.directory.appendingPathComponent("credential.txt")
        try "one\ntwo\nthree".write(to: plain, atomically: true, encoding: .utf8)
        try "api_key = do-not-read".write(to: credential, atomically: true, encoding: .utf8)
        let grant = try commandKGrant(fixture.runtime, query: "files")
        let tools = try XCTUnwrap(fixture.runtime.makeToolRuntime(
            frozenSession: grant.session,
            toolReserveTokens: 4_096
        ))

        XCTAssertEqual(
            tools.readFile(path: "../outside.txt"),
            .failure(.pathEscape)
        )
        XCTAssertEqual(
            tools.readFile(path: credential.path),
            .failure(.credentialFile)
        )
        _ = try tools.readFile(path: plain.path).get()
        try "changed after first read".write(to: plain, atomically: true, encoding: .utf8)
        switch tools.readFile(path: plain.path) {
        case .success:
            XCTFail("A file changed after the request began must not be mixed into the frozen turn")
        case .failure(let error):
            guard case .staleFile = error else {
                return XCTFail("Expected staleFile, got \(error)")
            }
        }
    }

    func testProjectFileReadRejectsFinalSymlinkInstalledAfterCanonicalization() throws {
        let outsideDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-file-race-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        let outsideSecret = outsideDirectory.appendingPathComponent("secret.txt")
        try "outside secret must never be read".write(to: outsideSecret, atomically: true, encoding: .utf8)

        let hooks = SessionContextReadHooks(beforeProjectFileDescriptorOpen: { canonicalPath in
            guard canonicalPath.hasSuffix("/notes.txt") else { return }
            try? FileManager.default.removeItem(atPath: canonicalPath)
            try? FileManager.default.createSymbolicLink(
                atPath: canonicalPath,
                withDestinationPath: outsideSecret.path
            )
        })
        let fixture = try makeFixture(
            sessions: [("symlink-race", "Symlink race", ["symlink race marker"])],
            readHooks: hooks
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let note = fixture.directory.appendingPathComponent("notes.txt")
        try "authorized project note".write(to: note, atomically: true, encoding: .utf8)
        let grant = try commandKGrant(fixture.runtime, query: "symlink race")
        let tools = try XCTUnwrap(fixture.runtime.makeToolRuntime(
            frozenSession: grant.session,
            toolReserveTokens: 4_096
        ))

        XCTAssertEqual(
            tools.readFile(path: note.path),
            .failure(.pathEscape),
            "O_NOFOLLOW must reject a final symlink installed after canonicalization"
        )
    }

    func testProjectFileReadRejectsPathReplacementAfterDescriptorOpen() throws {
        let hooks = SessionContextReadHooks(afterProjectFileDescriptorOpen: { canonicalPath in
            guard canonicalPath.hasSuffix("/notes.txt") else { return }
            try? FileManager.default.removeItem(atPath: canonicalPath)
            try? "replacement bytes must never be returned".write(
                toFile: canonicalPath,
                atomically: true,
                encoding: .utf8
            )
        })
        let fixture = try makeFixture(
            sessions: [("descriptor-race", "Descriptor race", ["descriptor race marker"])],
            readHooks: hooks
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let note = fixture.directory.appendingPathComponent("notes.txt")
        try "authorized bytes on the opened inode".write(to: note, atomically: true, encoding: .utf8)
        let grant = try commandKGrant(fixture.runtime, query: "descriptor race")
        let tools = try XCTUnwrap(fixture.runtime.makeToolRuntime(
            frozenSession: grant.session,
            toolReserveTokens: 4_096
        ))

        XCTAssertEqual(
            tools.readFile(path: note.path),
            .failure(.pathEscape),
            "descriptor and pathname identity must still match after the bounded read"
        )
    }

    func testTranscriptOperationsRejectSymlinkInstalledBeforeDescriptorOpen() throws {
        let outsideDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-transcript-race-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        let outsideTranscript = outsideDirectory.appendingPathComponent("outside.jsonl")
        try writeTranscript(["outside transcript must never be parsed"], to: outsideTranscript)

        for operation in ["inspect", "search", "read"] {
            let hooks = SessionContextReadHooks(beforeTranscriptDescriptorOpen: { transcriptPath in
                try? FileManager.default.removeItem(atPath: transcriptPath)
                try? FileManager.default.createSymbolicLink(
                    atPath: transcriptPath,
                    withDestinationPath: outsideTranscript.path
                )
            })
            let fixture = try makeFixture(
                sessions: [("transcript-before-\(operation)", "Transcript before \(operation)", ["authorized transcript marker"])],
                readHooks: hooks
            )
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let grant = try commandKGrant(fixture.runtime, query: "authorized transcript")
            let tools = try XCTUnwrap(fixture.runtime.makeToolRuntime(
                frozenSession: grant.session,
                toolReserveTokens: 4_096
            ))

            assertTranscriptOperationFails(
                operation,
                tools: tools,
                message: "\(operation) followed a transcript symlink installed after authorization"
            )
        }
    }

    func testTranscriptOperationsRejectPathReplacementAfterDescriptorOpen() throws {
        let replacement = try transcriptData(["replacement transcript must never be returned"])
        for operation in ["inspect", "search", "read"] {
            let hooks = SessionContextReadHooks(afterTranscriptDescriptorOpen: { transcriptPath in
                try? FileManager.default.removeItem(atPath: transcriptPath)
                try? replacement.write(to: URL(fileURLWithPath: transcriptPath), options: .atomic)
            })
            let fixture = try makeFixture(
                sessions: [("transcript-after-\(operation)", "Transcript after \(operation)", ["authorized transcript marker"])],
                readHooks: hooks
            )
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let grant = try commandKGrant(fixture.runtime, query: "authorized transcript")
            let tools = try XCTUnwrap(fixture.runtime.makeToolRuntime(
                frozenSession: grant.session,
                toolReserveTokens: 4_096
            ))

            assertTranscriptOperationFails(
                operation,
                tools: tools,
                message: "\(operation) returned evidence after the authorized transcript pathname changed"
            )
        }
    }

    func testExhaustiveReviewFreezeRejectsTranscriptSwapsAroundDescriptorOpen() throws {
        let outsideDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-review-race-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        let outsideTranscript = outsideDirectory.appendingPathComponent("outside.jsonl")
        try writeTranscript(["outside exhaustive-review evidence"], to: outsideTranscript)
        let replacement = try transcriptData(["replacement exhaustive-review evidence"])

        for timing in ["before", "after"] {
            let hooks: SessionContextReadHooks
            if timing == "before" {
                hooks = SessionContextReadHooks(beforeTranscriptDescriptorOpen: { transcriptPath in
                    try? FileManager.default.removeItem(atPath: transcriptPath)
                    try? FileManager.default.createSymbolicLink(
                        atPath: transcriptPath,
                        withDestinationPath: outsideTranscript.path
                    )
                })
            } else {
                hooks = SessionContextReadHooks(afterTranscriptDescriptorOpen: { transcriptPath in
                    try? FileManager.default.removeItem(atPath: transcriptPath)
                    try? replacement.write(to: URL(fileURLWithPath: transcriptPath), options: .atomic)
                })
            }
            let fixture = try makeFixture(
                sessions: [("review-race-\(timing)", "Review race \(timing)", ["authorized review marker"])],
                readHooks: hooks
            )
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let grant = try commandKGrant(fixture.runtime, query: "authorized review")

            XCTAssertThrowsError(
                try fixture.runtime.freezeReviewSource(focusedSession: grant.session),
                "exhaustive review accepted a \(timing)-open transcript replacement"
            )
        }
    }

    func testDirectoryListingRejectsRootReplacementAfterDescriptorOpen() throws {
        let outsideDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-directory-race-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try "private".write(
            to: outsideDirectory.appendingPathComponent("private-name.txt"),
            atomically: true,
            encoding: .utf8
        )
        var movedRoot: URL?
        let hooks = SessionContextReadHooks(afterDirectoryDescriptorOpen: { rootPath in
            let root = URL(fileURLWithPath: rootPath)
            let backup = root.deletingLastPathComponent()
                .appendingPathComponent(root.lastPathComponent + "-authorized-root")
            try? FileManager.default.moveItem(at: root, to: backup)
            try? FileManager.default.createSymbolicLink(
                atPath: root.path,
                withDestinationPath: outsideDirectory.path
            )
            movedRoot = backup
        })
        let fixture = try makeFixture(
            sessions: [("directory-race", "Directory race", ["directory race marker"])],
            readHooks: hooks
        )
        defer {
            if let movedRoot {
                try? FileManager.default.removeItem(at: fixture.directory)
                try? FileManager.default.moveItem(at: movedRoot, to: fixture.directory)
            }
            try? FileManager.default.removeItem(at: fixture.directory)
            try? FileManager.default.removeItem(at: outsideDirectory)
        }
        try "authorized".write(
            to: fixture.directory.appendingPathComponent("authorized-name.txt"),
            atomically: true,
            encoding: .utf8
        )
        let grant = try commandKGrant(fixture.runtime, query: "directory race")
        let tools = try XCTUnwrap(fixture.runtime.makeToolRuntime(
            frozenSession: grant.session,
            toolReserveTokens: 4_096
        ))

        let listing = tools.listWorkingDirectory()
        XCTAssertFalse(listing.contains("private-name.txt"))
        XCTAssertTrue(listing.localizedCaseInsensitiveContains("no working directory"))
    }

    func testTranscriptMutationAndDeletionInvalidateFrozenEvidence() throws {
        let fixture = try makeFixture(sessions: [
            ("mutable", "Mutable", ["original transcript evidence"])
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let grant = try commandKGrant(fixture.runtime, query: "mutable")
        let tools = try XCTUnwrap(fixture.runtime.makeToolRuntime(
            frozenSession: grant.session,
            toolReserveTokens: 4_096
        ))
        let transcriptURL = URL(fileURLWithPath: fixture.records[0].filePath)
        try writeTranscript(
            ["original transcript evidence", "new turn after request capture"],
            to: transcriptURL
        )

        switch tools.readTranscript(turnOrdinal: 1) {
        case .success:
            XCTFail("A changed transcript must require a fresh request")
        case .failure(let error):
            guard case .transcriptVersionMismatch = error else {
                return XCTFail("Expected transcriptVersionMismatch, got \(error)")
            }
        }

        try FileManager.default.removeItem(at: transcriptURL)
        let before = fixture.runtime.authoritySnapshot().epoch
        let reconciliation = fixture.runtime.reconcile(records: fixture.records)
        let after = fixture.runtime.authoritySnapshot()
        XCTAssertEqual(reconciliation.removedSessionIDs, ["mutable"])
        XCTAssertEqual(reconciliation.invalidatedFocusedSessionID, "mutable")
        XCTAssertNil(after.session)
        XCTAssertGreaterThan(after.epoch, before)
        XCTAssertTrue(fixture.runtime.commandKSearch("mutable", includeArchived: true).isEmpty)
    }

    func testRestartReconciliationRemovesPersistedGhostRows() throws {
        let fixture = try makeFixture(sessions: [
            ("kept", "Kept", ["persistent kept marker"]),
            ("deleted", "Deleted", ["persistent ghost marker"])
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.removeItem(atPath: fixture.records[1].filePath)

        let reopened = SessionContextRuntime(
            databaseURL: fixture.directory.appendingPathComponent("SessionFTS.sqlite")
        )
        let result = reopened.reconcile(records: fixture.records)

        XCTAssertEqual(result.removedSessionIDs, ["deleted"])
        XCTAssertTrue(reopened.commandKSearch("ghost", includeArchived: true).isEmpty)
        XCTAssertEqual(
            reopened.commandKSearch("kept", includeArchived: true).map(\.record.id),
            ["kept"]
        )
    }

    func testMetadataChangeReindexesEvenWhenTranscriptFileIsUnchanged() throws {
        let fixture = try makeFixture(sessions: [
            ("renamed", "Old neutral title", ["content without the new keyword"])
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        XCTAssertTrue(fixture.runtime.commandKSearch("Saffron", includeArchived: true).isEmpty)

        var renamed = fixture.records[0]
        renamed.title = "Saffron launch plan"
        fixture.runtime.reconcile(records: [renamed])

        XCTAssertEqual(
            fixture.runtime.commandKSearch("Saffron", includeArchived: true).map(\.record.id),
            ["renamed"]
        )
    }
}
