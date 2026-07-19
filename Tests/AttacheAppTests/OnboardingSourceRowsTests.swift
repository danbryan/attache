import XCTest
import SQLite3
import AttacheCore
@testable import AttacheApp

/// INF-386: the onboarding "Connect your agents" step lists all four watchable
/// sources. `OnboardingSourceRows` is the pure model (name/detail/found/count)
/// built from raw probe counts, and `OnboardingSourceProbe` counts each source
/// the same way its live scanner does. These tests exercise the row builder
/// against fabricated counts and all four probes (Codex, Claude Code, Grok
/// Build, opencode) against fabricated home layouts that mirror the real
/// on-disk stores.
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

    // MARK: - Probe refresh trigger

    /// The source probes should be re-run only while the "Connect your agents"
    /// step is showing, so a session created while onboarding is open no longer
    /// stays "Not found" until relaunch. The trigger is pure so it can be tested
    /// without SwiftUI.
    func testOnlySourcesStepTriggersProbeRefresh() {
        XCTAssertTrue(OnboardingSourceRows.refreshesProbes(on: .sources))
        for step in OnboardingStep.allCases where step != .sources {
            XCTAssertFalse(OnboardingSourceRows.refreshesProbes(on: step),
                           "\(step) must not trigger a source re-probe")
        }
    }

    // MARK: - Grok Build probe

    func testGrokBuildProbeCountsSessionDirectories() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-grok-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try makeGrokSessions(home: home, count: 2)

        XCTAssertEqual(OnboardingSourceProbe.grokBuildSessionCount(grokHome: home), 2)
    }

    /// Reproduces Dan's REAL `~/.grok` layout exactly (INF-386 bug report):
    /// a multi-segment percent-encoded project directory whose decoded path
    /// contains a literal dot (`github.com`), one completed session
    /// (`<uuid>/chat_history.jsonl`), plus the noise a live `~/.grok/sessions`
    /// actually carries: a `prompt_history.jsonl` file sitting directly in the
    /// project directory, a top-level `session_search.sqlite` file, and a
    /// second, still-running session that has only a `chat_history.jsonl.lock`
    /// (no transcript yet). Only the one completed session must count; the probe
    /// must ignore the sibling files and the lock-only session. This is the
    /// exact shape the screenshot showed as "Not found"; the probe reports it
    /// correctly.
    func testGrokBuildProbeMatchesRealMultiSegmentLayout() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-grok-real-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default

        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        // Real encoded project name: /Users/danb/code/github.com/danbryan/attache
        let project = sessions.appendingPathComponent(
            "%2FUsers%2Fdanb%2Fcode%2Fgithub.com%2Fdanbryan%2Fattache", isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)

        // Completed session: has chat_history.jsonl.
        let completed = project.appendingPathComponent("019f7a6a-ff71-7cc3-bfa7-b773f572b120", isDirectory: true)
        try fm.createDirectory(at: completed, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: completed.appendingPathComponent("chat_history.jsonl"))

        // Still-running session: only a lock, no transcript. Must not count.
        let running = project.appendingPathComponent("019f7b00-0000-7000-8000-000000000000", isDirectory: true)
        try fm.createDirectory(at: running, withIntermediateDirectories: true)
        try Data("".utf8).write(to: running.appendingPathComponent("chat_history.jsonl.lock"))

        // Sibling noise that a real sessions tree carries.
        try Data("{}\n".utf8).write(to: project.appendingPathComponent("prompt_history.jsonl"))
        try Data("".utf8).write(to: sessions.appendingPathComponent("session_search.sqlite"))

        XCTAssertEqual(OnboardingSourceProbe.grokBuildSessionCount(grokHome: home), 1)
    }

    func testGrokBuildProbeIsZeroWhenAbsent() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-grok-missing-\(UUID().uuidString)", isDirectory: true)
        XCTAssertEqual(OnboardingSourceProbe.grokBuildSessionCount(grokHome: missing), 0)
    }

    // MARK: - Codex probe

    /// The Codex probe must reuse `CodexSessionScanner`'s store convention: count
    /// rollout transcripts under BOTH `sessions/` and `archived_sessions/`, and
    /// only files whose name carries a real session UUID (a stray `.jsonl` with
    /// no UUID is not a session). A recursive raw `.jsonl` sweep of `sessions/`
    /// alone would miss the archived rollouts and miscount the stray file.
    func testCodexProbeIncludesArchivedAndSkipsNonSessionFiles() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-codex-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default

        let live = home.appendingPathComponent("sessions/2026/07/19", isDirectory: true)
        try fm.createDirectory(at: live, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: live.appendingPathComponent(
            "rollout-2026-07-19T10-00-00-\(UUID().uuidString).jsonl"))
        // Not a session: no UUID in the filename.
        try Data("{}\n".utf8).write(to: live.appendingPathComponent("notes.jsonl"))

        let archived = home.appendingPathComponent("archived_sessions/2026/07/18", isDirectory: true)
        try fm.createDirectory(at: archived, withIntermediateDirectories: true)
        for _ in 0..<2 {
            try Data("{}\n".utf8).write(to: archived.appendingPathComponent(
                "rollout-2026-07-18T09-00-00-\(UUID().uuidString).jsonl"))
        }

        // 1 live rollout + 2 archived rollouts; the stray notes.jsonl is ignored.
        XCTAssertEqual(OnboardingSourceProbe.codexSessionCount(codexHome: home), 3)
    }

    func testCodexProbeIsZeroWhenAbsent() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-codex-missing-\(UUID().uuidString)", isDirectory: true)
        XCTAssertEqual(OnboardingSourceProbe.codexSessionCount(codexHome: missing), 0)
    }

    // MARK: - Claude Code probe

    /// The Claude Code probe must reuse `ClaudeCodeSessionScanner`'s store
    /// convention: one `.jsonl` per session under `projects/<encoded-cwd>/`, and
    /// it must SKIP subagent sidechain transcripts (`subagents/agent-*.jsonl`,
    /// roughly 9:1 of real Claude data, INF-168) exactly as the live scanner and
    /// index do. A raw recursive `.jsonl` sweep would count those sidechains and
    /// report a wildly inflated session count that disagrees with what Attaché
    /// actually watches.
    func testClaudeCodeProbeSkipsSubagentSidechains() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-claude-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default

        let project = home.appendingPathComponent(
            "projects/-Users-danb-code-github-com-danbryan-attache", isDirectory: true)
        let subagents = project.appendingPathComponent("subagents", isDirectory: true)
        try fm.createDirectory(at: subagents, withIntermediateDirectories: true)

        // One real, attachable session.
        try Data("{\"cwd\":\"/Users/danb\"}\n".utf8).write(
            to: project.appendingPathComponent("\(UUID().uuidString).jsonl"))
        // Three subagent sidechains that must not count.
        for i in 0..<3 {
            try Data("{}\n".utf8).write(to: subagents.appendingPathComponent("agent-\(i).jsonl"))
        }

        XCTAssertEqual(OnboardingSourceProbe.claudeCodeSessionCount(claudeHome: home), 1)
    }

    func testClaudeCodeProbeIsZeroWhenAbsent() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-claude-missing-\(UUID().uuidString)", isDirectory: true)
        XCTAssertEqual(OnboardingSourceProbe.claudeCodeSessionCount(claudeHome: missing), 0)
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
