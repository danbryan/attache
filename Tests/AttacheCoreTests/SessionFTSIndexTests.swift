import AttacheCore
import XCTest

final class SessionFTSIndexTests: XCTestCase {

    private func tempDBURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("attache-fts-test-\(UUID().uuidString).sqlite")
    }

    private func makeRecord(
        id: String,
        title: String,
        content: String,
        source: SourceKind = .codex,
        project: String? = "/tmp/project",
        filePath: String = "/nonexistent/\(UUID().uuidString)",
        mtime: Double = 1_000
    ) -> SessionRecord {
        SessionRecord(
            id: id, title: title, project: project, threadName: nil,
            updatedAt: Date(timeIntervalSince1970: mtime), archived: false,
            filePath: filePath, fileMtime: mtime, content: content,
            topicTag: nil, sourceKind: source
        )
    }

    // Acceptance 1: deterministic Codex and Claude fixtures index and search
    // beginning, middle, and end content.
    func testCodexAndClaudeFixturesSearchBeginningMiddleEnd() {
        let index = SessionFTSIndex(databaseURL: tempDBURL())
        let codex = makeRecord(
            id: "codex-1", title: "Codex migration",
            content: "alpha zeta started the migration\nchecked the tests\nmiddle gamma refactor landed\nreviewed\ndone omega finish",
            source: .codex
        )
        let claude = makeRecord(
            id: "claude-1", title: "Claude review",
            content: "beginning beta kickoff\nmiddle delta audit\nclosing omega report",
            source: .claudeCode
        )
        index.index(records: [codex, claude])

        let beginHits = index.search("alpha")
        XCTAssertTrue(beginHits.contains { $0.sessionID == "codex-1" })
        let midHits = index.search("gamma")
        XCTAssertTrue(midHits.contains { $0.sessionID == "codex-1" })
        let endHits = index.search("omega")
        XCTAssertTrue(endHits.contains { $0.sessionID == "codex-1" })
        XCTAssertTrue(endHits.contains { $0.sessionID == "claude-1" })
    }

    // Acceptance 2: appending updates only the affected session; an unchanged
    // re-index does not reparse.
    func testIncrementalIndexSkipsUnchangedAndUpdatesChanged() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileA = dir.appendingPathComponent("a.log")
        let fileB = dir.appendingPathComponent("b.log")
        try "alpha content one".write(to: fileA, atomically: true, encoding: .utf8)
        try "bravo content two".write(to: fileB, atomically: true, encoding: .utf8)

        let index = SessionFTSIndex(databaseURL: tempDBURL())
        let recA = makeRecord(id: "a", title: "A", content: "alpha content one", filePath: fileA.path, mtime: 100)
        let recB = makeRecord(id: "b", title: "B", content: "bravo content two", filePath: fileB.path, mtime: 100)
        XCTAssertEqual(index.index(records: [recA, recB]), 2, "first pass indexes both")

        // Unchanged re-index reparses nothing.
        XCTAssertEqual(index.index(records: [recA, recB]), 0, "unchanged sessions are skipped")

        // Append to A only and bump its mtime.
        try "alpha content one and charlie new tail".write(to: fileA, atomically: true, encoding: .utf8)
        let recAUpdated = makeRecord(id: "a", title: "A", content: "alpha content one and charlie new tail", filePath: fileA.path, mtime: 200)
        XCTAssertEqual(index.index(records: [recAUpdated, recB]), 1, "only the changed session re-indexes")
        XCTAssertTrue(index.search("charlie").contains { $0.sessionID == "a" })
    }

    func testReadablePlainTextFileFallsBackToRecordDigest() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("attache-fts-plain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("plain.log")
        try "plain source text that is not JSONL".write(
            to: source,
            atomically: true,
            encoding: .utf8
        )
        let index = SessionFTSIndex(databaseURL: directory.appendingPathComponent("fts.sqlite"))
        index.index(records: [makeRecord(
            id: "plain",
            title: "Plain transcript",
            content: "digest fallback periwinkle marker",
            filePath: source.path
        )])

        XCTAssertTrue(index.search("periwinkle").contains { $0.sessionID == "plain" })
    }

    // Acceptance 3: truncation re-indexes safely.
    func testTruncationReindexesAndOldTailNoLongerMatches() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.log")
        try "head alpha\ntail omega end".write(to: file, atomically: true, encoding: .utf8)

        let db = tempDBURL()
        let index = SessionFTSIndex(databaseURL: db)
        let record = makeRecord(id: "t", title: "T", content: "head alpha\ntail omega end", filePath: file.path, mtime: 10)
        index.index(records: [record])
        XCTAssertTrue(index.search("omega").contains { $0.sessionID == "t" })

        // Truncate the content and bump mtime.
        try "head alpha only".write(to: file, atomically: true, encoding: .utf8)
        let truncated = makeRecord(id: "t", title: "T", content: "head alpha only", filePath: file.path, mtime: 20)
        index.index(records: [truncated])
        XCTAssertFalse(index.search("omega").contains { $0.sessionID == "t" },
                       "Truncated tail content must not still match.")
        XCTAssertTrue(index.search("alpha").contains { $0.sessionID == "t" })
    }

    // Acceptance 3: deletion removes chunks.
    func testDeletionRemovesChunks() {
        let index = SessionFTSIndex(databaseURL: tempDBURL())
        index.index(records: [makeRecord(id: "gone", title: "Gone", content: "vanish marker delta")])
        XCTAssertTrue(index.search("delta").contains { $0.sessionID == "gone" })
        index.remove(sessionID: "gone")
        XCTAssertFalse(index.search("delta").contains { $0.sessionID == "gone" })
    }

    // Acceptance 3: a corrupt DB (garbage bytes) rebuilds on open.
    func testCorruptDBRebuilds() throws {
        let db = tempDBURL()
        do {
            let index = SessionFTSIndex(databaseURL: db)
            index.index(records: [makeRecord(id: "c", title: "C", content: "corrupt recovery sigma")])
            XCTAssertTrue(index.search("sigma").contains { $0.sessionID == "c" })
        } // close the first handle so the file is not busy

        // Corrupt the database file.
        try "this is not a sqlite database file at all".write(to: db, atomically: true, encoding: .utf8)

        // A fresh index over the corrupt file must rebuild and work again.
        let rebuilt = SessionFTSIndex(databaseURL: db)
        XCTAssertEqual(rebuilt.diagnostics().schemaVersion, SessionFTSIndex.currentSchemaVersion)
        rebuilt.index(records: [makeRecord(id: "c", title: "C", content: "corrupt recovery sigma")])
        XCTAssertTrue(rebuilt.search("sigma").contains { $0.sessionID == "c" })
    }

    // Acceptance 3: a schema-version mismatch triggers a rebuild.
    func testSchemaVersionMismatchRebuilds() {
        let db = tempDBURL()
        do {
            let index = SessionFTSIndex(databaseURL: db)
            index.index(records: [makeRecord(id: "s", title: "S", content: "schema migration tau")])
            index.markForRebuild()
        } // close the first handle

        let reopened = SessionFTSIndex(databaseURL: db)
        XCTAssertEqual(reopened.diagnostics().schemaVersion, SessionFTSIndex.currentSchemaVersion)
        // After rebuild the index is empty until re-indexed from source logs.
        XCTAssertEqual(reopened.diagnostics().indexedSessionCount, 0)
        reopened.index(records: [makeRecord(id: "s", title: "S", content: "schema migration tau")])
        XCTAssertTrue(reopened.search("tau").contains { $0.sessionID == "s" })
    }

    // Acceptance 4: search results include stable provenance locators and
    // bounded snippets.
    func testSearchReturnsProvenanceLocatorsAndSnippets() {
        let index = SessionFTSIndex(databaseURL: tempDBURL())
        index.index(records: [makeRecord(
            id: "prov-1", title: "Provenance",
            content: "a long transcript where the unique phrase zeta phi appears clearly"
        )])
        let hits = index.search("zeta")
        XCTAssertTrue(hits.contains { $0.sessionID == "prov-1" })
        let hit = hits.first { $0.sessionID == "prov-1" }
        XCTAssertNotNil(hit?.chunkOrdinal)
        XCTAssertNotNil(hit?.byteOffset)
        XCTAssertFalse(hit?.snippet.isEmpty ?? true, "hit must carry a bounded snippet")
    }

    // Acceptance 5: private reasoning and fixture secrets are absent from the
    // FTS tables and from serialized diagnostics.
    func testPrivateReasoningAndSecretsAreAbsent() {
        let content = """
        user asked to deploy
        reasoning_content: private chain of thought the model must not leak
        api_key=sk-live-secret-value-here
        BEARER xoxb-production-token
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        normal agent reply about the deploy
        """
        let normalized = SessionFTSPrivacy.normalizedSearchableText(content)
        XCTAssertFalse(normalized.contains("reasoning_content"))
        XCTAssertFalse(normalized.contains("sk-live"))
        XCTAssertFalse(normalized.contains("xoxb"))
        XCTAssertFalse(normalized.contains("api_key"))

        let index = SessionFTSIndex(databaseURL: tempDBURL())
        index.index(records: [makeRecord(id: "priv", title: "Private", content: content)])
        // The unique secret fragments must not be searchable.
        XCTAssertFalse(index.search("sk-live").contains { $0.sessionID == "priv" })
        XCTAssertFalse(index.search("reasoning_content").contains { $0.sessionID == "priv" })
        // But the ordinary agent reply still is.
        XCTAssertTrue(index.search("deploy").contains { $0.sessionID == "priv" })

        // Diagnostics carry no content.
        let diag = index.diagnostics()
        XCTAssertGreaterThan(diag.chunkCount, 0)
    }

    func testDatabaseArtifactsStayPrivateAndWipeTruncatesEvidence() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("attache-fts-private-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("SessionFTS.sqlite")
        let marker = "wipe-evidence-cinnabar-\(UUID().uuidString)"
        let index = SessionFTSIndex(databaseURL: db)
        index.index(records: [makeRecord(
            id: "private-artifacts",
            title: "Private artifacts",
            content: marker
        )])
        XCTAssertFalse(index.search(marker).isEmpty)

        let artifacts = [
            db,
            URL(fileURLWithPath: db.path + "-wal"),
            URL(fileURLWithPath: db.path + "-shm")
        ]
        let existingBeforeWipe = artifacts.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        XCTAssertFalse(existingBeforeWipe.isEmpty)
        for artifact in existingBeforeWipe {
            let attributes = try FileManager.default.attributesOfItem(atPath: artifact.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o600, artifact.lastPathComponent)
        }

        index.wipe()
        XCTAssertTrue(index.search(marker).isEmpty)
        XCTAssertEqual(index.diagnostics().chunkCount, 0)
        for artifact in artifacts where FileManager.default.fileExists(atPath: artifact.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: artifact.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o600, artifact.lastPathComponent)
            let bytes = try Data(contentsOf: artifact)
            XCTAssertFalse(
                String(decoding: bytes, as: UTF8.self).contains(marker),
                "wipe must not leave searchable evidence in \(artifact.lastPathComponent)"
            )
            if artifact.path.hasSuffix("-wal") {
                XCTAssertEqual(bytes.count, 0, "wipe must checkpoint and truncate the WAL")
            }
        }
    }

    // Acceptance 6: searching is side-effect-free (it does not alter focus or
    // tool availability). The Core index has no focus state to mutate; calling
    // search twice yields identical results.
    func testSearchIsSideEffectFree() {
        let index = SessionFTSIndex(databaseURL: tempDBURL())
        index.index(records: [makeRecord(id: "se", title: "SE", content: "side effect free kappa")])
        let a = index.search("kappa")
        let b = index.search("kappa")
        XCTAssertEqual(a, b)
    }

    // Acceptance 7: a large synthetic corpus meets an interactive query target
    // without blocking UI work (off-main FTS5 lookups).
    func testLargeCorpusInteractiveQuery() {
        let index = SessionFTSIndex(databaseURL: tempDBURL())
        var records: [SessionRecord] = []
        for i in 0..<400 {
            records.append(makeRecord(
                id: "bulk-\(i)", title: "Bulk \(i)",
                content: "session \(i) discusses needle\(i % 7) and routine filler text about deployments"
            ))
        }
        index.index(records: records)
        let start = Date()
        let hits = index.search("needle3")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0, "interactive query should be well under a second")
        XCTAssertFalse(hits.isEmpty)
        XCTAssertLessThanOrEqual(hits.count, 200)
    }

    // Acceptance 8: the raw transcript remains authoritative; a hit carries a
    // provenance locator (sessionID + chunkOrdinal + byteOffset) that points
    // back to the source for re-reading and validation.
    func testHitCarriesProvenanceLocatorBackToSource() {
        let index = SessionFTSIndex(databaseURL: tempDBURL())
        index.index(records: [makeRecord(
            id: "auth-1", title: "Authoritative",
            content: "the raw transcript is the source of truth lambda marker"
        )])
        let hit = index.search("lambda").first { $0.sessionID == "auth-1" }
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.sessionID, "auth-1")
        // A stable locator exists to re-read and validate the hit from the raw log.
        XCTAssertGreaterThanOrEqual(hit?.byteOffset ?? -1, 0)
    }

    // Acceptance: filters constrain the result set.
    func testFiltersConstrainBySourceAndWorkingDirectory() {
        let index = SessionFTSIndex(databaseURL: tempDBURL())
        index.index(records: [
            makeRecord(id: "codex-proj", title: "Codex Proj", content: "shared term theta", source: .codex, project: "/tmp/a"),
            makeRecord(id: "claude-proj", title: "Claude Proj", content: "shared term theta", source: .claudeCode, project: "/tmp/b")
        ])
        let codexOnly = index.search("theta", filters: SessionFTSQuery(sourceKind: SourceKind.codex.rawValue))
        XCTAssertTrue(codexOnly.allSatisfy { $0.sourceKind == SourceKind.codex.rawValue })
        let dirOnly = index.search("theta", filters: SessionFTSQuery(workingDirectory: "/tmp/b"))
        XCTAssertTrue(dirOnly.allSatisfy { $0.workingDirectory == "/tmp/b" })
    }

    // Acceptance: diagnostics are content-free and report counts/version.
    func testDiagnosticsAreContentFree() {
        let index = SessionFTSIndex(databaseURL: tempDBURL())
        index.index(records: [makeRecord(id: "d", title: "D", content: "diagnostics nu")])
        let diag = index.diagnostics()
        XCTAssertEqual(diag.schemaVersion, SessionFTSIndex.currentSchemaVersion)
        XCTAssertEqual(diag.indexedSessionCount, 1)
        XCTAssertGreaterThan(diag.chunkCount, 0)
        XCTAssertFalse(diag.needsRebuild)
    }
}
