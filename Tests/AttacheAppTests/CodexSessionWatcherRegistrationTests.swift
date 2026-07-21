import XCTest
import AttacheCore
@testable import AttacheApp

/// The live file-tailing watcher (`CodexSessionWatcher`, used by Codex, Claude
/// Code, and Grok Build) checkpoints at the transcript's CURRENT END when a
/// session FIRST becomes watched or focused, so only turns appended AFTER
/// registration are ever narrated or filed. A finished session focused later,
/// enabling a source with existing sessions, and a relaunch whose persisted
/// offset lags a file that grew while the app was closed all take the same
/// EOF-seek path rather than replaying backlog, matching OpencodeLiveWatcher's
/// "no backlog narration" (INF-397).
final class CodexSessionWatcherRegistrationTests: XCTestCase {
    private func makeProjectsDir() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-watcher-registration-\(UUID().uuidString)", isDirectory: true)
        let projectsDir = root.appendingPathComponent("projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        return projectsDir
    }

    private func stamp(_ offsetSeconds: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: 1_800_000_000 + offsetSeconds))
    }

    private func userLine(_ text: String, at offset: Double) -> String {
        #"{"type":"user","cwd":"/proj","timestamp":"\#(stamp(offset))","message":{"role":"user","content":"\#(text)"}}"# + "\n"
    }

    private func assistantLine(_ text: String, at offset: Double) -> String {
        #"{"type":"assistant","cwd":"/proj","timestamp":"\#(stamp(offset))","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"# + "\n"
    }

    /// `<projectsDir>/proj/<sessionID>.jsonl` with the given initial content.
    private func writeSession(projectsDir: URL, sessionID: String, contents: String) throws -> URL {
        let projectDir = projectsDir.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let url = projectDir.appendingPathComponent("\(sessionID).jsonl")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func makeWatcher(projectsDir: URL, suite: String) -> (CodexSessionWatcher, UserDefaults) {
        let registry = SessionSourceRegistry.production(claudeProjectsDirectory: projectsDir)
        let defaults = UserDefaults(suiteName: suite)!
        let watcher = CodexSessionWatcher(sourceRegistry: registry, defaults: defaults)
        watcher.quietPolls = 1
        return (watcher, defaults)
    }

    private func target(_ sessionID: String) -> CodexSessionTarget {
        CodexSessionTarget(id: sessionID, title: "Watched session", updatedAt: Date(), category: .activeSession)
    }

    // MARK: - Registration files nothing for existing content

    func testRegistrationAtEOFFilesNothingForExistingCompletedTurns() throws {
        let projectsDir = makeProjectsDir()
        defer { try? FileManager.default.removeItem(at: projectsDir.deletingLastPathComponent()) }
        let sessionID = "aaaaaaaa-0000-0000-0000-000000000001"
        // A finished session: two completed assistant turns already on disk.
        let backlog = userLine("do the work", at: 0)
            + assistantLine("Did the first thing.", at: 1)
            + userLine("keep going", at: 2)
            + assistantLine("Did the second thing.", at: 3)
            + userLine("done", at: 4)
        _ = try writeSession(projectsDir: projectsDir, sessionID: sessionID, contents: backlog)

        let suite = "attache-registration-\(UUID().uuidString)"
        let (watcher, defaults) = makeWatcher(projectsDir: projectsDir, suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var events: [NormalizedEvent] = []
        watcher.onEvent = { events.append($0) }

        watcher.watch([target(sessionID)])   // first poll: register at EOF
        watcher.watch([target(sessionID)])   // an extra idle poll must still narrate nothing
        watcher.stop()

        XCTAssertTrue(events.isEmpty, "a finished session focused later must produce no voicemail for its past turns")
    }

    // MARK: - Content appended after registration narrates

    func testContentAppendedAfterRegistrationNarrates() throws {
        let projectsDir = makeProjectsDir()
        defer { try? FileManager.default.removeItem(at: projectsDir.deletingLastPathComponent()) }
        let sessionID = "aaaaaaaa-0000-0000-0000-000000000002"
        let url = try writeSession(
            projectsDir: projectsDir, sessionID: sessionID,
            contents: userLine("start", at: 0) + assistantLine("Old backlog turn.", at: 1) + userLine("ok", at: 2)
        )

        let suite = "attache-registration-\(UUID().uuidString)"
        let (watcher, defaults) = makeWatcher(projectsDir: projectsDir, suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var events: [NormalizedEvent] = []
        watcher.onEvent = { events.append($0) }

        watcher.watch([target(sessionID)])   // register at EOF
        XCTAssertTrue(events.isEmpty, "backlog must not narrate on registration")

        // A brand-new turn arrives after registration, closed by a user line.
        try append(assistantLine("Fresh work after watching.", at: 10) + userLine("thanks", at: 11), to: url)
        watcher.watch([target(sessionID)])
        watcher.stop()

        XCTAssertEqual(events.count, 1, "only the turn appended after registration should narrate")
        XCTAssertEqual(events.first?.text, "Fresh work after watching.")
    }

    // MARK: - Relaunch with a stale persisted offset jumps to EOF

    func testRelaunchWithStalePersistedOffsetOnIdleSessionJumpsToEOFWithoutFiling() throws {
        let projectsDir = makeProjectsDir()
        defer { try? FileManager.default.removeItem(at: projectsDir.deletingLastPathComponent()) }
        let sessionID = "aaaaaaaa-0000-0000-0000-000000000003"
        // The file grew (completed turns) while the app was closed.
        let grown = userLine("start", at: 0)
            + assistantLine("Work done while the app was closed.", at: 1)
            + userLine("more", at: 2)
            + assistantLine("Second turn while closed.", at: 3)
            + userLine("done", at: 4)
        _ = try writeSession(projectsDir: projectsDir, sessionID: sessionID, contents: grown)

        let suite = "attache-registration-\(UUID().uuidString)"
        let (watcher, defaults) = makeWatcher(projectsDir: projectsDir, suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        // Simulate a relaunch: a persisted offset lags far behind EOF, and the
        // session was polled but never emitted before close (no lastSeen), which
        // is exactly the state that used to replay the gap as backlog.
        defaults.set("5", forKey: "attache.codexSessionWatcher.fileOffset.\(sessionID)")

        var events: [NormalizedEvent] = []
        watcher.onEvent = { events.append($0) }

        watcher.watch([target(sessionID)])
        watcher.watch([target(sessionID)])
        watcher.stop()

        XCTAssertTrue(events.isEmpty, "a relaunch must jump to EOF, not replay the gap the stale offset covers")
    }

    // MARK: - Actively-growing session keeps tailing

    func testActivelyGrowingSessionKeepsTailingAcrossTheFix() throws {
        let projectsDir = makeProjectsDir()
        defer { try? FileManager.default.removeItem(at: projectsDir.deletingLastPathComponent()) }
        let sessionID = "aaaaaaaa-0000-0000-0000-000000000004"
        let url = try writeSession(
            projectsDir: projectsDir, sessionID: sessionID,
            contents: userLine("start", at: 0)
        )

        let suite = "attache-registration-\(UUID().uuidString)"
        let (watcher, defaults) = makeWatcher(projectsDir: projectsDir, suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var events: [NormalizedEvent] = []
        watcher.onEvent = { events.append($0) }

        watcher.watch([target(sessionID)])   // register at EOF (only a user line so far)
        XCTAssertTrue(events.isEmpty)

        try append(assistantLine("First live turn.", at: 10) + userLine("next", at: 11), to: url)
        watcher.watch([target(sessionID)])
        XCTAssertEqual(events.count, 1, "the first appended turn must narrate")

        try append(assistantLine("Second live turn.", at: 20) + userLine("more", at: 21), to: url)
        watcher.watch([target(sessionID)])
        watcher.stop()

        XCTAssertEqual(events.count, 2, "a session that keeps growing keeps being tailed and narrated")
        XCTAssertEqual(events.map(\.text), ["First live turn.", "Second live turn."])
    }
}
