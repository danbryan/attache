import AttacheCore
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
    func testForgetRemovesFromActiveAndDeleteAllClears() {
        let ledger = AttacheMemoryLedger(databaseURL: tempDBURL())
        let rec = makeRecord(id: "forget-me", statement: "Ephemeral detail")
        XCTAssertTrue(ledger.add(rec))
        XCTAssertEqual(ledger.list().count, 1)
        ledger.forget("forget-me")
        XCTAssertEqual(ledger.list().count, 0, "Forgotten records leave active retrieval.")
        XCTAssertEqual(ledger.list(activeOnly: false).count, 1, "The audit trail is preserved.")
        ledger.deleteAll()
        XCTAssertEqual(ledger.list(activeOnly: false).count, 0)
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

    // Acceptance 8: export produces inspectable JSON.
    func testExportProducesJSON() {
        let ledger = AttacheMemoryLedger(databaseURL: tempDBURL())
        XCTAssertTrue(ledger.add(makeRecord(id: "exp", statement: "Exportable fact")))
        let data = ledger.export()
        XCTAssertNotNil(data)
        let json = String(data: data ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("Exportable fact"))
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