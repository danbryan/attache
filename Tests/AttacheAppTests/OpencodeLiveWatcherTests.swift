import AttacheCore
import XCTest
@testable import AttacheApp

/// INF-397: `OpencodeLiveWatcher` polls opencode's shared SQLite database for
/// WATCHED sessions and narrates each newly completed assistant turn plus a
/// coarse working/idle activity state. opencode has no per-session transcript
/// file to tail, so these tests inject a snapshot loader (the same seam
/// `TwoWayCoordinator` uses for opencode) to drive the watcher tick-by-tick with
/// no real database, and drive polls synchronously via `poll()` for
/// determinism.
final class OpencodeLiveWatcherTests: XCTestCase {
    private func target(id: String, title: String = "opencode session") -> CodexSessionTarget {
        CodexSessionTarget(id: id, title: title, updatedAt: Date(), category: .activeSession, sourceKind: .opencode)
    }

    private func message(
        id: String, role: String, finish: String?, timeMillis: Double, text: String?
    ) -> OpencodeTranscriptAdapter.MessageRow {
        OpencodeTranscriptAdapter.MessageRow(
            id: id, role: role, finish: finish, timeCreated: timeMillis,
            parts: text.map { [.init(type: "text", text: $0)] } ?? []
        )
    }

    /// A watcher whose snapshot loader returns whatever the test currently has in
    /// `messages`, and whose change token is disabled (always nil) so every poll
    /// reads. Returns the watcher plus the mutable message box.
    private func makeWatcher(
        directory: String? = "/tmp/proj"
    ) -> (watcher: OpencodeLiveWatcher, setMessages: ([OpencodeTranscriptAdapter.MessageRow]) -> Void) {
        var box: [OpencodeTranscriptAdapter.MessageRow] = []
        let lock = NSLock()
        let watcher = OpencodeLiveWatcher(
            databaseURL: URL(fileURLWithPath: "/tmp/does-not-exist/opencode.db"),
            loadSnapshot: { _, _ in
                lock.lock(); defer { lock.unlock() }
                return OpencodeSessionSnapshot(directory: directory, messages: box)
            },
            changeTokenProvider: { _ in nil },
            pollInterval: 999
        )
        return (watcher, { new in lock.lock(); box = new; lock.unlock() })
    }

    // MARK: - Narration

    func testBacklogNotNarratedOnFirstWatch() {
        let (watcher, setMessages) = makeWatcher()
        setMessages([
            message(id: "u1", role: "user", finish: nil, timeMillis: 1000, text: "do the thing"),
            message(id: "a1", role: "assistant", finish: "stop", timeMillis: 2000, text: "historic reply one"),
            message(id: "u2", role: "user", finish: nil, timeMillis: 3000, text: "again"),
            message(id: "a2", role: "assistant", finish: "stop", timeMillis: 4000, text: "historic reply two")
        ])
        var events: [NormalizedEvent] = []
        watcher.onEvent = { events.append($0) }

        watcher.watch([target(id: "ses_1")])   // first registration polls immediately
        watcher.poll()                          // a second poll must still narrate nothing

        XCTAssertTrue(events.isEmpty, "the historic backlog must never be narrated on first watch")
    }

    func testNewCompletedTurnNarratesExactlyOneCardWithProvenance() {
        let (watcher, setMessages) = makeWatcher(directory: "/Users/tester/proj")
        setMessages([
            message(id: "a1", role: "assistant", finish: "stop", timeMillis: 2000, text: "historic")
        ])
        var events: [NormalizedEvent] = []
        watcher.onEvent = { events.append($0) }
        watcher.watch([target(id: "ses_1")])
        XCTAssertTrue(events.isEmpty)

        // A brand-new completed assistant turn after the checkpoint.
        setMessages([
            message(id: "a1", role: "assistant", finish: "stop", timeMillis: 2000, text: "historic"),
            message(id: "u2", role: "user", finish: nil, timeMillis: 3000, text: "next task"),
            message(id: "a2", role: "assistant", finish: "stop", timeMillis: 4000, text: "the new answer")
        ])
        watcher.poll()

        XCTAssertEqual(events.count, 1, "exactly one card for the one new completed turn")
        let event = try! XCTUnwrap(events.first)
        XCTAssertEqual(event.source, SourceKind.opencode.rawValue)
        XCTAssertEqual(event.eventType, "assistant.completed")
        XCTAssertEqual(event.externalSessionID, "ses_1")
        XCTAssertEqual(event.text, "the new answer")
        XCTAssertEqual(event.projectPath, "/Users/tester/proj")
        XCTAssertEqual(event.metadata["adapter"], "opencode-session-db")
        XCTAssertNotNil(event.metadata["source_time"])
    }

    func testInFlightTurnIsNotNarratedUntilItCompletes() {
        let (watcher, setMessages) = makeWatcher()
        setMessages([message(id: "a1", role: "assistant", finish: "stop", timeMillis: 2000, text: "historic")])
        var events: [NormalizedEvent] = []
        watcher.onEvent = { events.append($0) }
        watcher.watch([target(id: "ses_1")])

        // A user turn plus an in-flight assistant (finish nil): nothing to narrate.
        setMessages([
            message(id: "a1", role: "assistant", finish: "stop", timeMillis: 2000, text: "historic"),
            message(id: "u2", role: "user", finish: nil, timeMillis: 3000, text: "go"),
            message(id: "a2", role: "assistant", finish: nil, timeMillis: 4000, text: "working on it")
        ])
        watcher.poll()
        XCTAssertTrue(events.isEmpty, "an in-flight turn (finish == nil) is not narrated")

        // Now it completes.
        setMessages([
            message(id: "a1", role: "assistant", finish: "stop", timeMillis: 2000, text: "historic"),
            message(id: "u2", role: "user", finish: nil, timeMillis: 3000, text: "go"),
            message(id: "a2", role: "assistant", finish: "stop", timeMillis: 4000, text: "done at last")
        ])
        watcher.poll()
        XCTAssertEqual(events.map(\.text), ["done at last"])
    }

    func testCheckpointAdvancesSoATurnIsNarratedOnce() {
        let (watcher, setMessages) = makeWatcher()
        setMessages([message(id: "a1", role: "assistant", finish: "stop", timeMillis: 1000, text: "historic")])
        var events: [NormalizedEvent] = []
        watcher.onEvent = { events.append($0) }
        watcher.watch([target(id: "ses_1")])

        setMessages([
            message(id: "a1", role: "assistant", finish: "stop", timeMillis: 1000, text: "historic"),
            message(id: "a2", role: "assistant", finish: "stop", timeMillis: 2000, text: "fresh")
        ])
        watcher.poll()
        watcher.poll()   // re-poll with no change: the checkpoint must have advanced
        watcher.poll()
        XCTAssertEqual(events.count, 1, "a completed turn narrates exactly once, not on every poll")
    }

    // MARK: - Activity

    func testInFlightYieldsWorkingThenTurnComplete() {
        let (watcher, setMessages) = makeWatcher()
        setMessages([message(id: "a0", role: "assistant", finish: "stop", timeMillis: 500, text: "prior")])
        var attention: [(String, SessionAttentionState)] = []
        watcher.onAttention = { id, state, _ in attention.append((id, state)) }
        watcher.watch([target(id: "ses_1")])
        // First registration publishes the initial state (turnComplete: latest is
        // a finished assistant turn).
        XCTAssertEqual(attention.map(\.1), [.turnComplete])

        // Assistant starts working.
        setMessages([
            message(id: "a0", role: "assistant", finish: "stop", timeMillis: 500, text: "prior"),
            message(id: "u1", role: "user", finish: nil, timeMillis: 1000, text: "go"),
            message(id: "a1", role: "assistant", finish: nil, timeMillis: 2000, text: "thinking")
        ])
        watcher.poll()
        XCTAssertEqual(attention.last?.1, .active, "an in-flight turn publishes working/active")

        // Turn completes.
        setMessages([
            message(id: "a0", role: "assistant", finish: "stop", timeMillis: 500, text: "prior"),
            message(id: "u1", role: "user", finish: nil, timeMillis: 1000, text: "go"),
            message(id: "a1", role: "assistant", finish: "stop", timeMillis: 2000, text: "thinking done")
        ])
        watcher.poll()
        XCTAssertEqual(attention.last?.1, .turnComplete, "completion publishes turnComplete")
    }

    func testUserTurnAwaitingReplyYieldsWorking() {
        let (watcher, setMessages) = makeWatcher()
        setMessages([message(id: "a0", role: "assistant", finish: "stop", timeMillis: 500, text: "prior")])
        var attention: [SessionAttentionState] = []
        watcher.onAttention = { _, state, _ in attention.append(state) }
        watcher.watch([target(id: "ses_1")])

        setMessages([
            message(id: "a0", role: "assistant", finish: "stop", timeMillis: 500, text: "prior"),
            message(id: "u1", role: "user", finish: nil, timeMillis: 1000, text: "new question")
        ])
        watcher.poll()
        XCTAssertEqual(attention.last, .active, "a fresh user turn awaiting its reply reads as working")
    }

    // MARK: - Lifecycle

    func testStopEndsNarrationAndClearsState() {
        let (watcher, setMessages) = makeWatcher()
        setMessages([message(id: "a0", role: "assistant", finish: "stop", timeMillis: 500, text: "prior")])
        var events: [NormalizedEvent] = []
        watcher.onEvent = { events.append($0) }
        watcher.watch([target(id: "ses_1")])
        watcher.stop()

        // A new completed turn arrives after stop: nothing watched, nothing narrated.
        setMessages([
            message(id: "a0", role: "assistant", finish: "stop", timeMillis: 500, text: "prior"),
            message(id: "a1", role: "assistant", finish: "stop", timeMillis: 2000, text: "after stop")
        ])
        watcher.poll()
        XCTAssertTrue(events.isEmpty, "a stopped watcher narrates nothing")
    }

    func testUnwatchedSessionIsNotPolled() {
        let (watcher, setMessages) = makeWatcher()
        setMessages([message(id: "a0", role: "assistant", finish: "stop", timeMillis: 500, text: "prior")])
        var events: [NormalizedEvent] = []
        watcher.onEvent = { events.append($0) }
        watcher.watch([])   // nothing watched
        setMessages([
            message(id: "a0", role: "assistant", finish: "stop", timeMillis: 500, text: "prior"),
            message(id: "a1", role: "assistant", finish: "stop", timeMillis: 2000, text: "unwatched")
        ])
        watcher.poll()
        XCTAssertTrue(events.isEmpty, "no watched sessions means no narration")
    }

    // MARK: - Change-signal skip (optimization correctness)

    func testUnchangedTokenSkipsQueriesButNewTokenReads() {
        var loaderCalls = 0
        var box: [OpencodeTranscriptAdapter.MessageRow] = [
            message(id: "a0", role: "assistant", finish: "stop", timeMillis: 500, text: "prior")
        ]
        var token = "v1"
        let watcher = OpencodeLiveWatcher(
            databaseURL: URL(fileURLWithPath: "/tmp/x/opencode.db"),
            loadSnapshot: { _, _ in
                loaderCalls += 1
                return OpencodeSessionSnapshot(directory: nil, messages: box)
            },
            changeTokenProvider: { _ in token },
            pollInterval: 999
        )
        var events: [NormalizedEvent] = []
        watcher.onEvent = { events.append($0) }

        watcher.watch([target(id: "ses_1")])   // first registration reads (loaderCalls == 1)
        let afterFirst = loaderCalls
        XCTAssertGreaterThanOrEqual(afterFirst, 1)

        watcher.poll()   // token unchanged and session started: skipped, no read
        XCTAssertEqual(loaderCalls, afterFirst, "an unchanged token must skip the SQLite read")

        // Token changes (a real DB write): the next poll reads and narrates.
        box.append(message(id: "a1", role: "assistant", finish: "stop", timeMillis: 2000, text: "changed"))
        token = "v2"
        watcher.poll()
        XCTAssertEqual(loaderCalls, afterFirst + 1, "a changed token must trigger a read")
        XCTAssertEqual(events.map(\.text), ["changed"])
    }
}
