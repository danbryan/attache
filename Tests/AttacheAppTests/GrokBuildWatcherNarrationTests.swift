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
/// This proves the watcher now locates a Grok `chat_history.jsonl` by its
/// id-named parent directory and narrates the assistant turn into an event.
final class GrokBuildWatcherNarrationTests: XCTestCase {
    func testWatcherNarratesGrokChatHistoryUnderSessionIdDirectory() throws {
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
        // Newline-terminated, like a real append-only JSONL transcript: the
        // watcher's tail reader buffers a trailing partial line until its newline
        // arrives, so an unterminated last line would not parse yet.
        let transcript = """
        {"type":"user","content":[{"type":"text","text":"reply exactly PONG"}]}
        {"type":"assistant","content":"Pong from Grok.","tool_calls":null}

        """
        try transcript.write(
            to: sessionDir.appendingPathComponent("chat_history.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let registry = SessionSourceRegistry.production(grokSessionsDirectory: sessionsDir)
        let suiteName = "attache-grok-watch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let watcher = CodexSessionWatcher(sourceRegistry: registry, defaults: defaults)

        var events: [NormalizedEvent] = []
        watcher.onEvent = { events.append($0) }

        let target = CodexSessionTarget(
            id: sessionID,
            title: "Grok Build",
            updatedAt: Date(),
            category: .activeSession,
            sourceKind: .grokBuild
        )
        watcher.watch([target])   // `watch` runs the first poll synchronously
        watcher.stop()

        XCTAssertEqual(events.count, 1, "the watcher should narrate the latest Grok assistant turn as one event")
        XCTAssertEqual(events.first?.source, SourceKind.grokBuild.rawValue)
        XCTAssertEqual(events.first?.text, "Pong from Grok.")
    }
}
