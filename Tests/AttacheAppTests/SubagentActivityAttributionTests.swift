import XCTest
import AttacheCore
@testable import AttacheApp

/// INF-368 Part B: while a watched Claude Code session delegates work to a
/// subagent, nearly all activity happens in `<session>/subagents/agent-*.jsonl`
/// (INF-168's excluded-from-index layout), so the parent transcript stays
/// quiet and Attaché narrated nothing. Both live watchers now additionally
/// tail those files for a session that is currently watched/focused,
/// attributing everything they find to the PARENT session: no separate card,
/// no separate session, no separate activity identity.
final class SubagentActivityAttributionTests: XCTestCase {
    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-subagent-attribution-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func stamp(_ offsetSeconds: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: 1_800_000_000 + offsetSeconds))
    }

    /// Lays out `<projectsDir>/<project>/<sessionID>.jsonl` (parent) and
    /// `<projectsDir>/<project>/<sessionID>/subagents/agent-*.jsonl`
    /// (subagent), matching `ClaudeCodeSessionScanner.isSubagentTranscript`'s
    /// documented shape.
    private func makeClaudeSession(
        projectsDir: URL,
        project: String = "proj",
        sessionID: String
    ) throws -> (parent: URL, subagentsDir: URL) {
        let projectDir = projectsDir.appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let parent = projectDir.appendingPathComponent("\(sessionID).jsonl")
        let subagentsDir = projectDir.appendingPathComponent(sessionID, isDirectory: true).appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)
        return (parent, subagentsDir)
    }

    // MARK: - CodexSessionWatcher: narration attribution

    func testSubagentAppendsNarrateAttributedToTheParentSessionID() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectsDir = root.appendingPathComponent("projects", isDirectory: true)
        let sessionID = "11111111-1111-1111-1111-111111111111"
        let (parentURL, subagentsDir) = try makeClaudeSession(projectsDir: projectsDir, sessionID: sessionID)

        // Parent starts quiet: just a session-opening user line, no assistant
        // prose yet, so the first attach emits nothing.
        try #"{"type":"user","cwd":"/proj","timestamp":"\#(stamp(0))","message":{"role":"user","content":"start the task"}}"#
            .appending("\n").write(to: parentURL, atomically: true, encoding: .utf8)

        let registry = SessionSourceRegistry.production(claudeProjectsDirectory: projectsDir)
        let watcher = CodexSessionWatcher(sourceRegistry: registry, defaults: UserDefaults(suiteName: "attache-subagent-narration-\(UUID().uuidString)")!)
        var events: [NormalizedEvent] = []
        watcher.onEvent = { events.append($0) }

        let target = CodexSessionTarget(id: sessionID, title: "Watched session", updatedAt: Date(), category: .activeSession)
        watcher.watch([target])   // first attach: parent quiet, nothing emitted
        XCTAssertTrue(events.isEmpty, "a quiet parent must not emit anything on first attach")

        // The subagent now does the actual work while the parent is silent.
        let subagentURL = subagentsDir.appendingPathComponent("agent-task1.jsonl")
        try #"{"type":"assistant","isSidechain":true,"timestamp":"\#(stamp(5))","message":{"role":"assistant","content":[{"type":"text","text":"Investigated the failing test and found the root cause."}]}}"#
            .appending("\n").write(to: subagentURL, atomically: true, encoding: .utf8)

        watcher.watch([target])   // second poll: reads the subagent, buffers its prose
        XCTAssertTrue(events.isEmpty, "prose is buffered in the coalescer, not yet flushed as a turn")

        // The user's next real message closes the turn, flushing whatever was
        // buffered - the subagent's prose - as the parent session's own turn.
        let appended = #"{"type":"user","cwd":"/proj","timestamp":"\#(stamp(10))","message":{"role":"user","content":"continue"}}"# + "\n"
        try appended.appendToFile(at: parentURL)

        watcher.watch([target])
        XCTAssertEqual(events.count, 1, "the subagent's prose must become exactly one narration turn on the parent session, never a separate card")
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.externalSessionID, sessionID, "narration from a subagent append must carry the PARENT session id")
        XCTAssertTrue(event.text.contains("root cause"), "the actual narrated text should be the subagent's own prose")
    }

    func testSubagentFilesAreNeverTailedForACodexClassifiedSession() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let sessionsDir = codexHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let sessionID = "22222222-2222-2222-2222-222222222222"
        let parentURL = sessionsDir.appendingPathComponent("rollout-\(sessionID).jsonl")
        try #"{"type":"session_meta","payload":{"cwd":"/proj"}}"#.appending("\n").write(to: parentURL, atomically: true, encoding: .utf8)

        // A directory that LOOKS like a subagents layout sitting next to a
        // Codex file must never be opened: subagent tailing only exists for
        // Claude Code sessions.
        let subagentsDir = sessionsDir.appendingPathComponent(sessionID, isDirectory: true).appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)
        let subagentURL = subagentsDir.appendingPathComponent("agent-task1.jsonl")
        try #"{"type":"assistant","isSidechain":true,"timestamp":"\#(stamp(5))","message":{"role":"assistant","content":[{"type":"text","text":"THIS MUST NEVER BE NARRATED"}]}}"#
            .appending("\n").write(to: subagentURL, atomically: true, encoding: .utf8)

        let registry = SessionSourceRegistry.production(codexSessionsDirectory: sessionsDir)
        let watcher = CodexSessionWatcher(sourceRegistry: registry, defaults: UserDefaults(suiteName: "attache-subagent-gating-\(UUID().uuidString)")!)
        var events: [NormalizedEvent] = []
        watcher.onEvent = { events.append($0) }

        let target = CodexSessionTarget(id: sessionID, title: "Codex session", updatedAt: Date(), category: .activeSession, sourceKind: .codex)
        watcher.watch([target])
        watcher.watch([target])
        watcher.watch([target])

        XCTAssertTrue(events.allSatisfy { !$0.text.contains("THIS MUST NEVER BE NARRATED") }, "a Codex session must never have its (non-existent, but hypothetically present) subagents directory tailed")
    }

    // MARK: - SessionActivityWatcher: activity phrase attribution

    func testSubagentToolActivityPublishesPhrasesWhileTheParentTranscriptIsQuiet() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectsDir = root.appendingPathComponent("projects", isDirectory: true)
        let sessionID = "33333333-3333-3333-3333-333333333333"
        let (parentURL, subagentsDir) = try makeClaudeSession(projectsDir: projectsDir, sessionID: sessionID)

        // Parent transcript carries no tool activity at all.
        try #"{"type":"user","cwd":"/proj","timestamp":"\#(stamp(0))","message":{"role":"user","content":"start the task"}}"#
            .appending("\n").write(to: parentURL, atomically: true, encoding: .utf8)

        // The subagent is the one actually running tools.
        let subagentURL = subagentsDir.appendingPathComponent("agent-task1.jsonl")
        try #"{"type":"assistant","isSidechain":true,"timestamp":"\#(stamp(1))","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test"}}]}}"#
            .appending("\n").write(to: subagentURL, atomically: true, encoding: .utf8)

        let registry = SessionSourceRegistry.production(claudeProjectsDirectory: projectsDir)
        let watcher = SessionActivityWatcher(sourceRegistry: registry)
        var publishedPhrases: [[AgentActivityPhrase]] = []
        watcher.onPhrases = { publishedPhrases.append($0) }

        let target = CodexSessionTarget(id: sessionID, title: "Watched session", updatedAt: Date(), category: .activeSession)
        watcher.watch([target])

        let latest = publishedPhrases.last ?? []
        XCTAssertFalse(latest.isEmpty, "tool activity in the subagent file must publish a phrase even though the parent transcript is silent")
        XCTAssertTrue(latest.allSatisfy { $0.agentKind == .claudeCode }, "phrases sourced from a subagent must be attributed to the parent's own source kind, never a distinct one")
        watcher.stop()
    }

    func testUnwatchedSessionsSubagentFilesAreNeverOpened() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectsDir = root.appendingPathComponent("projects", isDirectory: true)
        let watchedID = "44444444-4444-4444-4444-444444444444"
        let unwatchedID = "55555555-5555-5555-5555-555555555555"

        let (watchedParent, watchedSubagentsDir) = try makeClaudeSession(projectsDir: projectsDir, sessionID: watchedID)
        try #"{"type":"user","cwd":"/proj","timestamp":"\#(stamp(0))","message":{"role":"user","content":"start"}}"#
            .appending("\n").write(to: watchedParent, atomically: true, encoding: .utf8)
        let watchedSubagent = watchedSubagentsDir.appendingPathComponent("agent-a.jsonl")
        try #"{"type":"assistant","isSidechain":true,"timestamp":"\#(stamp(1))","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"echo watched"}}]}}"#
            .appending("\n").write(to: watchedSubagent, atomically: true, encoding: .utf8)

        let (unwatchedParent, unwatchedSubagentsDir) = try makeClaudeSession(projectsDir: projectsDir, sessionID: unwatchedID)
        try #"{"type":"user","cwd":"/proj","timestamp":"\#(stamp(0))","message":{"role":"user","content":"start"}}"#
            .appending("\n").write(to: unwatchedParent, atomically: true, encoding: .utf8)
        let unwatchedSubagent = unwatchedSubagentsDir.appendingPathComponent("agent-b.jsonl")
        try #"{"type":"assistant","isSidechain":true,"timestamp":"\#(stamp(1))","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"curl http://forbidden.invalid/should-never-be-fetched-or-narrated"}}]}}"#
            .appending("\n").write(to: unwatchedSubagent, atomically: true, encoding: .utf8)

        let registry = SessionSourceRegistry.production(claudeProjectsDirectory: projectsDir)
        let watcher = SessionActivityWatcher(sourceRegistry: registry)
        var publishedPhrases: [[AgentActivityPhrase]] = []
        watcher.onPhrases = { publishedPhrases.append($0) }

        // Only the watched session is ever handed to watch(); the unwatched
        // session's directory (and its subagent's) is never traversed.
        let target = CodexSessionTarget(id: watchedID, title: "Watched session", updatedAt: Date(), category: .activeSession)
        watcher.watch([target])

        let latest = publishedPhrases.last ?? []
        XCTAssertFalse(latest.isEmpty, "the watched session's own subagent activity should still be picked up")
        XCTAssertTrue(latest.allSatisfy { $0.text != "calling endpoint" }, "the UNWATCHED session's subagent activity must never surface")
        watcher.stop()
    }
}

private extension String {
    func appendToFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(self.utf8))
    }
}
