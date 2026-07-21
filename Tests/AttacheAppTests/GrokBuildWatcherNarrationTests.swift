import XCTest
import AttacheCore
@testable import AttacheApp

/// INF-396 root cause: the live narration watcher located a session transcript
/// only by the id appearing in the FILENAME (`lastPathComponent.contains(id)`).
/// Grok Build stores its transcript at
/// `<sessions>/<project>/<session-id>/chat_history.jsonl`, with the id on the
/// DIRECTORY and a fixed filename, so the watcher never located a Grok session
/// and never narrated its turns into cards. That left a delivered Tell Agent
/// reply un-filed (`resulting_card_id` never set) even though two-way delivery,
/// which uses `AttacheSessionReader`, could read the very same file.
///
/// This proves the watcher locates a Grok `chat_history.jsonl` by its id-named
/// parent directory AND (INF-397 parity) checkpoints at the transcript's current
/// end on first registration: the pre-existing backlog is never narrated, and
/// only a turn appended after registration becomes an event.
final class GrokBuildWatcherNarrationTests: XCTestCase {
    func testWatcherCheckpointsThenNarratesGrokTurnAppendedAfterRegistration() throws {
        let sessionsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-grok-watch-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let sessionID = "grok-watch-\(UUID().uuidString.lowercased())"
        let sessionDir = sessionsDir
            .appendingPathComponent("%2FUsers%2Ftester%2Fproject", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        // A sibling events file must never be mistaken for the transcript.
        try "{}\n".write(
            to: sessionDir.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8
        )
        let chatHistory = sessionDir.appendingPathComponent("chat_history.jsonl")
        // The pre-existing backlog: a completed user+assistant turn already on
        // disk when watching begins. Under the no-backlog rule it must never be
        // narrated. Newline-terminated, like a real append-only JSONL transcript.
        let backlog = """
        {"type":"user","content":[{"type":"text","text":"reply exactly PONG"}]}
        {"type":"assistant","content":"Pong from Grok.","tool_calls":null}

        """
        try backlog.write(to: chatHistory, atomically: true, encoding: .utf8)

        let registry = SessionSourceRegistry.production(grokSessionsDirectory: sessionsDir)
        let suiteName = "attache-grok-watch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let watcher = CodexSessionWatcher(sourceRegistry: registry, defaults: defaults)
        watcher.quietPolls = 1

        var events: [NormalizedEvent] = []
        watcher.onEvent = { events.append($0) }

        let target = CodexSessionTarget(
            id: sessionID,
            title: "Grok Build",
            updatedAt: Date(),
            category: .activeSession,
            sourceKind: .grokBuild
        )
        watcher.watch([target])   // first poll: register at EOF, narrate nothing
        XCTAssertTrue(events.isEmpty, "the pre-registration Grok backlog must never be narrated")

        // A NEW turn is appended after registration, plus a following user line
        // that closes it so the coalescer flushes it as one turn.
        let appended = """
        {"type":"assistant","content":"Fresh reply after watching.","tool_calls":null}
        {"type":"user","content":[{"type":"text","text":"thanks"}]}

        """
        let handle = try FileHandle(forWritingTo: chatHistory)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        watcher.watch([target])   // re-poll: reads only the appended turn
        watcher.stop()

        XCTAssertEqual(events.count, 1, "only the turn appended after registration should narrate")
        XCTAssertEqual(events.first?.source, SourceKind.grokBuild.rawValue)
        XCTAssertEqual(events.first?.text, "Fresh reply after watching.")
        XCTAssertNotEqual(events.first?.text, "Pong from Grok.", "the historic backlog must not resurface")
    }
}
