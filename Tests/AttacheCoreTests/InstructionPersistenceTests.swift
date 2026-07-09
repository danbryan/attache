import SQLite3
import XCTest
@testable import AttacheCore

final class InstructionPersistenceTests: XCTestCase {
    func testLegacyInstructionTableMigratesAdditively() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-instruction-migration-\(UUID().uuidString).sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let legacySchema = """
        CREATE TABLE instructions (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            source_kind TEXT NOT NULL,
            text TEXT NOT NULL,
            state TEXT NOT NULL,
            created_at TEXT NOT NULL,
            confirmed_at TEXT,
            delivered_at TEXT,
            delivery_mechanism TEXT,
            error TEXT,
            resulting_card_id TEXT
        );
        """
        XCTAssertEqual(sqlite3_exec(database, legacySchema, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)

        let store = try CardStore(databaseURL: url)
        let instruction = Instruction(
            id: "i1",
            sessionID: "s1",
            sourceKind: "codex",
            text: "run tests",
            createdAt: Date(),
            origin: .personalityTool,
            sourceUtterance: "Ask Codex to run tests",
            targetDisplayName: "Migration test",
            deliveryCheckpoint: 42
        )

        try store.upsertInstruction(instruction)
        let fetched = try XCTUnwrap(store.fetchInstruction(id: instruction.id))

        XCTAssertEqual(fetched.origin, .personalityTool)
        XCTAssertEqual(fetched.sourceUtterance, instruction.sourceUtterance)
        XCTAssertEqual(fetched.targetDisplayName, instruction.targetDisplayName)
        XCTAssertEqual(fetched.deliveryCheckpoint, 42)
    }
}
