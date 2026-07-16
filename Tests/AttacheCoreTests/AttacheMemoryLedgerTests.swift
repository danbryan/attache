import AttacheCore
import SQLite3
import XCTest

final class AttacheMemoryLedgerTests: XCTestCase {

    private func tempDBURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("attache-memory-test-\(UUID().uuidString).sqlite")
    }

    private func makeRecord(id: String = "rec-\(UUID().uuidString.prefix(6))", statement: String = "A durable fact") -> AttacheMemoryRecord {
        AttacheMemoryRecord(id: id, statement: statement, type: .userFact)
    }

    // Acceptance 1: migration preserves meaning and is idempotent.
    func testMarkdownMigrationPreservesMeaningAndIsIdempotent() {
        let ledger = AttacheMemoryLedger(databaseURL: tempDBURL())
        let markdown = """
        # Attaché Memory
        - Prefers concise summaries
        - Works on the Attaché project
        """
        let created = ledger.migrate(fromMarkdown: markdown)
        XCTAssertEqual(created, 2)
        XCTAssertTrue(ledger.isMigrated)
        // Second migration is idempotent.
        XCTAssertEqual(ledger.migrate(fromMarkdown: markdown), 0)
        let records = ledger.list()
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.contains { $0.statement == "Prefers concise summaries" })
        XCTAssertTrue(records.contains { $0.statement == "Works on the Attaché project" })
        XCTAssertTrue(records.allSatisfy { $0.sourceKind == .imported && $0.egress == .localOnly },
                      "Migration must not grant remote-disclosure authority")
    }

    // Acceptance 2: supersession creates an auditable update without duplicate active facts.
    func testSupersessionMarksOldAndAddsNew() {
        let ledger = AttacheMemoryLedger(databaseURL: tempDBURL())
        let old = makeRecord(id: "old", statement: "Original fact")
        XCTAssertTrue(ledger.add(old))
        let new = makeRecord(id: "new", statement: "Corrected fact")
        XCTAssertTrue(ledger.supersede(oldID: "old", with: new))
        let active = ledger.list(activeOnly: true)
        XCTAssertEqual(active.count, 1, "No duplicate active facts after supersession.")
        XCTAssertEqual(active.first?.id, "new")
        let all = ledger.list(activeOnly: false)
        XCTAssertTrue(all.contains { $0.id == "old" && $0.status == .superseded })
    }

    // Acceptance 3: forget removes from active retrieval; deleteAll clears everything.
    func testForgetRemovesFromActiveAndDeleteAllClears() throws {
        let databaseURL = tempDBURL()
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
            }
        }
        let ledger = AttacheMemoryLedger(databaseURL: databaseURL)
        let rec = makeRecord(id: "forget-me", statement: "Ephemeral detail")
        XCTAssertTrue(ledger.add(rec))
        XCTAssertEqual(ledger.list().count, 1)
        XCTAssertTrue(ledger.forget("forget-me"))
        XCTAssertFalse(ledger.forget("forget-me"), "A second forget must not report a persisted transition")
        XCTAssertEqual(ledger.list().count, 0, "Forgotten records leave active retrieval.")
        XCTAssertEqual(ledger.list(activeOnly: false).count, 1, "The audit trail is preserved.")
        XCTAssertTrue(ledger.deleteAll())
        XCTAssertEqual(ledger.list(activeOnly: false).count, 0)
        XCTAssertTrue(ledger.isMigrated, "delete-all must retain a migration tombstone so legacy memory cannot be resurrected")

        let deletedBytes = Data("Ephemeral detail".utf8)
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            XCTAssertNil(data.range(of: deletedBytes), "Deleted memory remained in SQLite artifact \(url.lastPathComponent)")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
            XCTAssertEqual(permissions & 0o777, 0o600)
        }
    }

    // Acceptance 4: scopes prevent cross-personality visibility.
    func testPersonalityScopePreventsCrossVisibility() {
        let ledger = AttacheMemoryLedger(databaseURL: tempDBURL())
        let scoped = AttacheMemoryRecord(id: "scoped", statement: "Colt-specific fact", type: .preference, scope: .personality("builtin.cowboy"))
        XCTAssertTrue(ledger.add(scoped))
        XCTAssertTrue(ledger.list(forPersonality: "builtin.cowboy").contains { $0.id == "scoped" })
        XCTAssertFalse(ledger.list(forPersonality: "builtin.bigPicture").contains { $0.id == "scoped" },
                       "A personality-scoped record must not be visible to another personality.")
    }

    func testGlobalScopeIsVisibleToAll() {
        let ledger = AttacheMemoryLedger(databaseURL: tempDBURL())
        let global = makeRecord(id: "global", statement: "Everyone sees this")
        XCTAssertTrue(ledger.add(global))
        XCTAssertTrue(ledger.list(forPersonality: "any-personality").contains { $0.id == "global" })
    }

    func testTopicScopeRequiresExactExplicitTopic() {
        let ledger = AttacheMemoryLedger(databaseURL: tempDBURL())
        let scoped = AttacheMemoryRecord(
            id: "topic", statement: "Attaché release detail", type: .projectTopic,
            scope: .topic("attache-release")
        )
        XCTAssertTrue(ledger.add(scoped))
        XCTAssertTrue(ledger.list(forPersonality: nil, topic: "attache-release").contains { $0.id == "topic" })
        XCTAssertFalse(ledger.list(forPersonality: nil, topic: "other").contains { $0.id == "topic" })
        XCTAssertFalse(ledger.list(forPersonality: nil).contains { $0.id == "topic" })
    }

    func testFailedSupersessionRollsBackOldRecord() {
        let ledger = AttacheMemoryLedger(databaseURL: tempDBURL())
        XCTAssertTrue(ledger.add(makeRecord(id: "old", statement: "Original fact")))
        let rejected = makeRecord(id: "new", statement: "api_key=sk-secret")
        XCTAssertFalse(ledger.supersede(oldID: "old", with: rejected))
        XCTAssertEqual(ledger.list().map(\.id), ["old"])
        XCTAssertEqual(ledger.list(activeOnly: false).first?.status, .active)
    }

    // Acceptance 5: local-only records cannot be selected for a remote request.
    func testLocalOnlyEgressExcludesFromRemote() {
        let ledger = AttacheMemoryLedger(databaseURL: tempDBURL())
        let local = AttacheMemoryRecord(id: "local", statement: "Local-only fact", type: .userFact, egress: .localOnly)
        let remote = AttacheMemoryRecord(id: "remote", statement: "Remote-safe fact", type: .userFact, egress: .allowedRemote)
        XCTAssertTrue(ledger.add(local))
        XCTAssertTrue(ledger.add(remote))
        let forRemote = ledger.list(forPersonality: nil, egress: .allowedRemote)
        XCTAssertTrue(forRemote.contains { $0.id == "remote" })
        XCTAssertFalse(forRemote.contains { $0.id == "local" }, "Local-only records must not be selected for a remote request.")
        XCTAssertFalse(local.mayEgressToRemote)
        XCTAssertTrue(remote.mayEgressToRemote)
    }

    // Acceptance 6: source locators do not grant session focus.
    func testSourceLocatorDoesNotGrantFocus() {
        let rec = AttacheMemoryRecord(id: "cite", statement: "A fact from a session", type: .userFact, sourceLocator: "session-abc:turn-42")
        // The record carries a locator but has no focus-granting mechanism.
        XCTAssertEqual(rec.sourceLocator, "session-abc:turn-42")
        // The ledger does not expose a focus or session-authorization API.
        // A locator is metadata, not authority.
    }

    // Acceptance 7: secrets and private reasoning are rejected.
    func testSecretsAreRejected() {
        let ledger = AttacheMemoryLedger(databaseURL: tempDBURL())
        let secret = AttacheMemoryRecord(id: "secret", statement: "api_key=sk-live-secret-value", type: .userFact)
        XCTAssertFalse(ledger.add(secret), "Secrets must be rejected from the ledger.")
        let reasoning = AttacheMemoryRecord(id: "reasoning", statement: "reasoning_content: private thought", type: .userFact)
        XCTAssertFalse(ledger.add(reasoning), "Private reasoning must be rejected.")
        XCTAssertEqual(ledger.list().count, 0)
    }

    func testStructurallySensitiveValuesAreRejectedAcrossWritePaths() throws {
        let ledger = AttacheMemoryLedger(databaseURL: tempDBURL())
        let sensitiveStatements = [
            "My SSN is 078-05-1120.",
            "Use card 4111 1111 1111 1111 for purchases.",
            "The routing number is 021000021.",
            "Send it to IBAN GB82 WEST 1234 5698 7654 32.",
            "Credential eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signaturepart"
        ]
        for (index, statement) in sensitiveStatements.enumerated() {
            XCTAssertFalse(ledger.add(makeRecord(id: "sensitive-\(index)", statement: statement)))
        }

        XCTAssertTrue(ledger.add(makeRecord(id: "safe", statement: "Prefers concise summaries.")))
        XCTAssertFalse(ledger.supersede(
            oldID: "safe",
            with: makeRecord(id: "replacement", statement: sensitiveStatements[1])
        ))
        XCTAssertEqual(ledger.list().map(\.id), ["safe"])

        let imported = try JSONEncoder().encode([
            makeRecord(id: "external", statement: sensitiveStatements[2])
        ])
        XCTAssertEqual(
            ledger.importRecords(from: imported),
            AttacheMemoryImportResult(imported: 0, rejected: 1)
        )
    }

    func testImportDowngradesRequestedRemoteEgressToLocalOnly() throws {
        let ledger = AttacheMemoryLedger(databaseURL: tempDBURL())
        let imported = AttacheMemoryRecord(
            id: "external",
            statement: "I prefer concise summaries.",
            type: .preference,
            egress: .allowedRemote
        )

        XCTAssertEqual(
            ledger.importRecords(from: try JSONEncoder().encode([imported])),
            AttacheMemoryImportResult(imported: 1, rejected: 0)
        )
        XCTAssertEqual(ledger.list().first?.egress, .localOnly)
    }

    func testOpenRepairsLegacyImportedRemoteEgress() throws {
        let url = tempDBURL()
        var ledger: AttacheMemoryLedger? = AttacheMemoryLedger(databaseURL: url)
        XCTAssertTrue(ledger?.add(AttacheMemoryRecord(
            id: "legacy-import",
            statement: "I prefer concise summaries.",
            type: .preference,
            sourceKind: .imported,
            egress: .allowedRemote
        )) == true)
        ledger = nil

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "UPDATE memories SET egress = 'allowedRemote' WHERE id = 'legacy-import';",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)

        let reopened = AttacheMemoryLedger(databaseURL: url)
        XCTAssertEqual(reopened.list().first?.egress, .localOnly)
    }

    func testRestoreReactivatesForgottenRowWithoutDuplicate() {
        let ledger = AttacheMemoryLedger(databaseURL: tempDBURL())
        XCTAssertTrue(ledger.add(makeRecord(id: "undo", statement: "Remember this.")))
        ledger.forget("undo")
        XCTAssertTrue(ledger.list().isEmpty)
        XCTAssertTrue(ledger.restore("undo"))
        XCTAssertEqual(ledger.list().map(\.id), ["undo"])
        XCTAssertEqual(ledger.list(activeOnly: false).count, 1)
        XCTAssertFalse(ledger.restore("undo"), "Only a forgotten row may be restored once.")
    }

    // Acceptance 8: export produces inspectable JSON.
    func testExportProducesJSON() {
        let ledger = AttacheMemoryLedger(databaseURL: tempDBURL())
        XCTAssertTrue(ledger.add(makeRecord(id: "exp", statement: "Exportable fact")))
        let data = ledger.export()
        XCTAssertNotNil(data)
        let json = String(data: data ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("Exportable fact"))
    }

    func testImportRoundTripRevalidatesAndRemovesExternalAuthority() throws {
        let source = AttacheMemoryLedger(databaseURL: tempDBURL())
        XCTAssertTrue(source.add(AttacheMemoryRecord(
            id: "external-id",
            statement: "Use short release notes.",
            type: .preference,
            scope: .personality("colt"),
            sourceKind: .userConfirmed,
            sourceLocator: "session-secret:turn-9",
            confidence: .authoritative,
            sensitivity: .medium,
            egress: .localOnly,
            status: .forgotten,
            supersededByID: "external-next"
        )))
        let exported = try XCTUnwrap(source.export())
        let destination = AttacheMemoryLedger(databaseURL: tempDBURL())

        let result = try XCTUnwrap(destination.importRecords(from: exported))
        XCTAssertEqual(result, AttacheMemoryImportResult(imported: 1, rejected: 0))
        let imported = try XCTUnwrap(destination.list().first)
        XCTAssertNotEqual(imported.id, "external-id")
        XCTAssertEqual(imported.statement, "Use short release notes.")
        XCTAssertEqual(imported.scope, .personality("colt"))
        XCTAssertEqual(imported.sourceKind, .imported)
        XCTAssertNil(imported.sourceLocator)
        XCTAssertEqual(imported.status, .active)
        XCTAssertNil(imported.supersededByID)
        XCTAssertEqual(imported.egress, .localOnly)
    }

    func testImportRejectsSecretsAndDuplicatesWithoutPartialAuthority() throws {
        let records = [
            AttacheMemoryRecord(id: "one", statement: "Prefer concise answers.", type: .preference),
            AttacheMemoryRecord(id: "two", statement: "Prefer concise answers.", type: .preference),
            AttacheMemoryRecord(id: "secret", statement: "api_key=sk-live-secret", type: .userFact)
        ]
        let data = try JSONEncoder().encode(records)
        let ledger = AttacheMemoryLedger(databaseURL: tempDBURL())

        let result = try XCTUnwrap(ledger.importRecords(from: data))
        XCTAssertEqual(result, AttacheMemoryImportResult(imported: 1, rejected: 2))
        XCTAssertEqual(ledger.list().map(\.statement), ["Prefer concise answers."])
    }

    // Acceptance 9: diagnostics are content-free.
    func testDiagnosticsAreContentFree() {
        let ledger = AttacheMemoryLedger(databaseURL: tempDBURL())
        ledger.add(makeRecord(id: "d1", statement: "First fact"))
        ledger.add(AttacheMemoryRecord(id: "d2", statement: "Second", type: .preference))
        let diag = ledger.diagnostics()
        XCTAssertEqual(diag.totalRecords, 2)
        XCTAssertEqual(diag.activeRecords, 2)
        XCTAssertEqual(diag.byType["userFact"], 1)
        XCTAssertEqual(diag.byType["preference"], 1)
        XCTAssertGreaterThan(diag.migrationVersion, -1)
    }

    // Permissions: the DB file has restrictive permissions.
    func testDatabaseFileHasRestrictivePermissions() throws {
        let url = tempDBURL()
        let ledger = AttacheMemoryLedger(databaseURL: url)
        ledger.add(makeRecord(statement: "Permission test"))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attrs[.posixPermissions] as? NSNumber
        XCTAssertNotNil(permissions)
        XCTAssertEqual(permissions?.int16Value ?? 0, 0o600, "The memory DB must have restrictive 0600 permissions.")
    }
}
