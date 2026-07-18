import XCTest
import SQLite3
import AttacheCore
@testable import AttacheApp

/// INF-386: the onboarding "Connect your agents" step lists all four watchable
/// sources. `OnboardingSourceRows` is the pure model (name/detail/found/count)
/// built from raw probe counts, and `OnboardingSourceProbe` counts each source
/// the same way its live scanner does. These tests exercise the row builder
/// against fabricated counts and the Grok Build / opencode probes against
/// fabricated home layouts.
final class OnboardingSourceRowsTests: XCTestCase {

    // MARK: - Pure four-row model

    func testAllFourSourcesAppearInOrder() {
        let rows = OnboardingSourceRows.make(codexCount: 0, claudeCount: 0, grokBuildCount: 0, opencodeCount: 0)
        XCTAssertEqual(rows.map(\.id), ["codex", "claude", "grok", "opencode"])
        XCTAssertEqual(rows.map(\.name), ["Codex CLI", "Claude Code", "Grok Build", "opencode"])
    }

    func testZeroCountsShowInstallPointers() {
        let rows = OnboardingSourceRows.make(codexCount: 0, claudeCount: 0, grokBuildCount: 0, opencodeCount: 0)
        for row in rows {
            XCTAssertFalse(row.found)
            XCTAssertEqual(row.count, 0)
            XCTAssertTrue(row.detail.contains("Not found (install:"), "\(row.name) should point at an installer when absent")
        }
        XCTAssertTrue(rows[2].detail.contains("grok.com"))
        XCTAssertTrue(rows[3].detail.contains("opencode.ai"))
    }

    func testPositiveCountsShowSessionsAndLocation() {
        let rows = OnboardingSourceRows.make(codexCount: 3, claudeCount: 12, grokBuildCount: 1, opencodeCount: 7)
        XCTAssertTrue(rows[0].found)
        XCTAssertEqual(rows[0].detail, "3 sessions in ~/.codex")
        XCTAssertEqual(rows[1].detail, "12 sessions in ~/.claude")
        XCTAssertEqual(rows[2].detail, "1 sessions in ~/.grok")
        XCTAssertEqual(rows[3].detail, "7 sessions in ~/.local/share/opencode")
    }

    func testTwoHundredCapRendersPlus() {
        let rows = OnboardingSourceRows.make(codexCount: 200, claudeCount: 199, grokBuildCount: 0, opencodeCount: 0)
        XCTAssertEqual(rows[0].detail, "200+ sessions in ~/.codex")
        XCTAssertEqual(rows[1].detail, "199 sessions in ~/.claude")
    }

    // MARK: - Grok Build probe

    func testGrokBuildProbeCountsSessionDirectories() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-grok-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try makeGrokSessions(home: home, count: 2)

        XCTAssertEqual(OnboardingSourceProbe.grokBuildSessionCount(grokHome: home), 2)
    }

    func testGrokBuildProbeIsZeroWhenAbsent() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-grok-missing-\(UUID().uuidString)", isDirectory: true)
        XCTAssertEqual(OnboardingSourceProbe.grokBuildSessionCount(grokHome: missing), 0)
    }

    // MARK: - opencode probe

    func testOpencodeProbeCountsSessionRows() throws {
        let dataHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-opencode-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataHome) }
        try makeOpencodeDatabase(dataHome: dataHome, sessionIDs: ["a", "b", "c"])

        XCTAssertEqual(OnboardingSourceProbe.opencodeSessionCount(opencodeDataHome: dataHome), 3)
    }

    func testOpencodeProbeIsZeroWhenAbsent() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-opencode-missing-\(UUID().uuidString)", isDirectory: true)
        XCTAssertEqual(OnboardingSourceProbe.opencodeSessionCount(opencodeDataHome: missing), 0)
    }

    // MARK: - Fixtures

    private func makeGrokSessions(home: URL, count: Int) throws {
        let sessions = home.appendingPathComponent("sessions/%2FUsers%2Fdanb", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        for _ in 0..<count {
            let dir = sessions.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: dir.appendingPathComponent("chat_history.jsonl"))
        }
    }

    private func makeOpencodeDatabase(dataHome: URL, sessionIDs: [String]) throws {
        try FileManager.default.createDirectory(at: dataHome, withIntermediateDirectories: true)
        let dbURL = dataHome.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        func exec(_ sql: String) {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, "SQL failed: \(sql)")
        }
        exec("""
            CREATE TABLE session (
                id text PRIMARY KEY, directory text, title text, parent_id text,
                time_updated integer, time_archived integer
            )
            """)
        for id in sessionIDs {
            exec("INSERT INTO session (id, directory, title, parent_id, time_updated, time_archived) VALUES ('\(id)', '/tmp', 'Title', NULL, 1000, NULL)")
        }
    }
}
