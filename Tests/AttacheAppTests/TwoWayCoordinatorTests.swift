import XCTest
import AttacheCore
@testable import AttacheApp

private final class StubAdapter: InstructionDeliveryAdapter, @unchecked Sendable {
    let sourceKind = "codex"
    var result: Result<DeliveryReceipt, InstructionDeliveryError> = .success(
        DeliveryReceipt(mechanism: "headless-resume", transcriptCheckpoint: 0)
    )

    init(result: Result<DeliveryReceipt, InstructionDeliveryError> = .success(
        DeliveryReceipt(mechanism: "headless-resume", transcriptCheckpoint: 0)
    )) {
        self.result = result
    }

    func capability(forSessionID sessionID: String) -> DeliveryCapability {
        DeliveryCapability(canDeliver: true, requiresIdle: true)
    }
    func deliver(_ instruction: Instruction) async -> Result<DeliveryReceipt, InstructionDeliveryError> {
        result
    }
}

@MainActor
final class TwoWayCoordinatorTests: XCTestCase {
    private func makeStore() throws -> CardStore {
        try CardStore(databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-coord-\(UUID().uuidString).sqlite"))
    }

    func testPrepareShowsInLogAndDeliversWhenIdle() async throws {
        let store = try makeStore()
        let sessionFile = FileManager.default.temporaryDirectory.appendingPathComponent("sess-\(UUID().uuidString).jsonl")
        try writeReadyCodexSession(to: sessionFile)
        let coordinator = TwoWayCoordinator(
            store: store,
            locateSessionFile: { _ in sessionFile },
            quietWindow: 0,
            adapters: [StubAdapter()]
        )
        coordinator.setEnabled(true, sessionID: "s1")
        let instruction = try coordinator.prepare(text: "run the suite", sessionID: "s1", sourceKind: "codex")
        XCTAssertEqual(coordinator.log.first?.id, instruction.id)
        XCTAssertEqual(coordinator.log.first?.state, .pending)

        // Confirm+deliver with an idle session (quietWindow default 6, file mtime is old).
        try await coordinator.confirmAndDeliver(id: instruction.id)
        XCTAssertEqual(coordinator.log.first?.state, .delivered)
    }

    func testConfirmAndDeliverReturnsFailureForVisibleStatus() async throws {
        let store = try makeStore()
        let sessionFile = FileManager.default.temporaryDirectory.appendingPathComponent("sess-\(UUID().uuidString).jsonl")
        try writeReadyCodexSession(to: sessionFile)
        let coordinator = TwoWayCoordinator(
            store: store,
            locateSessionFile: { _ in sessionFile },
            quietWindow: 0,
            adapters: [StubAdapter(result: .failure(.deliveryFailed("env: node: No such file or directory")))]
        )
        coordinator.setEnabled(true, sessionID: "s1")
        let instruction = try coordinator.prepare(text: "run the suite", sessionID: "s1", sourceKind: "codex")

        let changed = try await coordinator.confirmAndDeliver(id: instruction.id)

        XCTAssertEqual(changed.first?.id, instruction.id)
        XCTAssertEqual(changed.first?.state, .failed)
        XCTAssertEqual(changed.first?.error, "Delivery failed: env: node: No such file or directory")
        XCTAssertEqual(coordinator.log.first?.state, .failed)
    }

    /// INF-245 (B2): correlation is positional, not exact-text. An offset that
    /// doesn't yet extend past the checkpoint must not link (the reply hasn't
    /// landed), and once it does, a personality's paraphrase of the reply must
    /// still link - the dedicated positional/FIFO coverage lives in
    /// SessionReplyCorrelationTests.swift.
    func testLinkResponseCardTiesReplyToInstruction() async throws {
        let store = try makeStore()
        let sessionFile = FileManager.default.temporaryDirectory.appendingPathComponent("sess-\(UUID().uuidString).jsonl")
        try writeReadyCodexSession(to: sessionFile)
        let coordinator = TwoWayCoordinator(
            store: store,
            locateSessionFile: { _ in sessionFile },
            quietWindow: 0,
            adapters: [StubAdapter()]
        )
        coordinator.setEnabled(true, sessionID: "s1")
        let instruction = try coordinator.prepare(text: "make a change", sessionID: "s1", sourceKind: "codex")
        try await coordinator.confirmAndDeliver(id: instruction.id)

        // Before the reply has landed in the transcript, an event whose offset
        // doesn't extend past the checkpoint (the stub adapter reports 0) must
        // not link.
        coordinator.linkResponseCard(
            cardID: "too-early",
            sessionID: "s1",
            eventText: "irrelevant",
            transcriptEndOffset: 0
        )
        XCTAssertNil(coordinator.log.first(where: { $0.id == instruction.id })?.resultingCardID)

        let reply = "Finished the requested change."
        try append(
            """
            {"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"make a change"}]}}
            {"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"text":"\(reply)"}]}}

            """,
            to: sessionFile
        )
        let endOffset = Int64(try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: sessionFile.path)[.size] as? NSNumber
        ).int64Value)

        // A personality could paraphrase the raw reply into wording that shares
        // no words with it; the link must still succeed because correlation is
        // positional, not textual.
        coordinator.linkResponseCard(
            cardID: "card-1",
            sessionID: "s1",
            eventText: "All set - the change is in.",
            transcriptEndOffset: endOffset
        )
        XCTAssertEqual(coordinator.log.first(where: { $0.id == instruction.id })?.resultingCardID, "card-1")
    }

    /// INF-248 (B3): `pump` used to discard `expireStale`'s result
    /// (`_ = engine.expireStale(now: now)` in the pre-fix code), so an
    /// instruction that expired while waiting for its session to go quiet
    /// never reached `AppModel.handleTwoWayDeliveryChanges` and the user saw
    /// nothing after the initial "Sending…" status, forever. This proves the
    /// expiry list now comes back out of `pump` alongside delivered/failed
    /// instructions, using `expiryWindow` as the fast-expiry override for
    /// tests (mirrors `AgentResumeDeliveryAdapter.processTimeout`'s override
    /// style) instead of waiting 30 real minutes. A later ticket (E4) can
    /// reuse this same `TwoWayCoordinator(expiryWindow:)` seam.
    func testPumpSurfacesExpiredInstructionsInsteadOfDiscardingThem() async throws {
        let store = try makeStore()
        // No session file ever resolves, so the confirmed instruction can
        // never be observed as ready/idle - it stays queued (like a fake
        // Codex session that never goes quiet) until it expires.
        let coordinator = TwoWayCoordinator(
            store: store,
            locateSessionFile: { _ in nil },
            expiryWindow: 1,
            adapters: [StubAdapter()]
        )
        coordinator.setEnabled(true, sessionID: "s1")
        let start = Date()
        let instruction = try coordinator.prepare(
            text: "run the suite",
            sessionID: "s1",
            sourceKind: "codex",
            targetDisplayName: "Weekly Codex Improvement Review",
            now: start
        )

        let changedAtConfirm = try await coordinator.confirmAndDeliver(id: instruction.id, now: start)
        XCTAssertTrue(changedAtConfirm.isEmpty, "not ready yet and not expired yet: still waiting")
        XCTAssertEqual(coordinator.log.first?.state, .confirmed)

        // Advance past the 1s fast-expiry window without the session ever
        // becoming observable/idle.
        let changed = await coordinator.pump(now: start.addingTimeInterval(5))

        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed.first?.id, instruction.id)
        XCTAssertEqual(changed.first?.state, .failed)
        XCTAssertEqual(
            changed.first?.error,
            "Send expired after 1 min waiting for Weekly Codex Improvement Review to go quiet."
        )
        XCTAssertEqual(coordinator.log.first?.state, .failed)
    }

    /// INF-255 (B4): the watcher's `onEvent` callback now schedules a pump
    /// (`scheduleEventDrivenPump`) instead of relying solely on the periodic
    /// refresh timer, which lives entirely in `AppModel` and is never started
    /// in this test - so any delivery below happens through the event-driven
    /// path alone. A small quiet window that hasn't elapsed yet at confirm
    /// time leaves the instruction `.confirmed`; only the later
    /// `scheduleEventDrivenPump()` call (standing in for a real watcher event)
    /// delivers it once the (test-shortened) debounce settles.
    func testEventDrivenPumpDeliversWithoutWaitingForTimer() async throws {
        let store = try makeStore()
        let sessionFile = FileManager.default.temporaryDirectory.appendingPathComponent("sess-\(UUID().uuidString).jsonl")
        try writeReadyCodexSession(to: sessionFile)
        let coordinator = TwoWayCoordinator(
            store: store,
            locateSessionFile: { _ in sessionFile },
            quietWindow: 0.05,
            eventPumpDebounceInterval: 0.05,
            adapters: [StubAdapter()]
        )
        coordinator.setEnabled(true, sessionID: "s1")
        let instruction = try coordinator.prepare(text: "run the suite", sessionID: "s1", sourceKind: "codex")

        let changedAtConfirm = try await coordinator.confirmAndDeliver(id: instruction.id)
        XCTAssertTrue(changedAtConfirm.isEmpty, "quiet window hasn't elapsed yet: still waiting")
        XCTAssertEqual(coordinator.log.first?.state, .confirmed)

        var eventPumpChanges: [Instruction] = []
        coordinator.onEventDrivenPump = { eventPumpChanges = $0 }
        coordinator.scheduleEventDrivenPump()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(eventPumpChanges.first?.id, instruction.id)
        XCTAssertEqual(eventPumpChanges.first?.state, .delivered)
        XCTAssertEqual(coordinator.log.first?.state, .delivered)
    }

    /// INF-255 (B4): a burst of watcher events must collapse to exactly one
    /// pump, not one per event, or a session writing many small transcript
    /// updates in quick succession would hammer the store once per update.
    /// Fires 8 events well within the (test-shortened) debounce window and
    /// counts pump invocations via `onEventDrivenPump`, the same counter-
    /// closure testability seam `AgentResumeDeliveryAdapter.processTimeout`
    /// and `expiryWindow` use elsewhere in this file for timing-sensitive
    /// behavior.
    func testEventDrivenPumpDebouncesRapidBurstToOnePump() async throws {
        let store = try makeStore()
        let sessionFile = FileManager.default.temporaryDirectory.appendingPathComponent("sess-\(UUID().uuidString).jsonl")
        try writeReadyCodexSession(to: sessionFile)
        let coordinator = TwoWayCoordinator(
            store: store,
            locateSessionFile: { _ in sessionFile },
            quietWindow: 0,
            eventPumpDebounceInterval: 0.05,
            adapters: [StubAdapter()]
        )
        coordinator.setEnabled(true, sessionID: "s1")
        _ = try coordinator.prepare(text: "run the suite", sessionID: "s1", sourceKind: "codex")

        var pumpCount = 0
        coordinator.onEventDrivenPump = { _ in pumpCount += 1 }

        // A burst of 8 rapid watcher events, all well inside the debounce
        // window; each call cancels the previous one's scheduled work item.
        for _ in 0..<8 {
            coordinator.scheduleEventDrivenPump()
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(pumpCount, 1, "a burst of events must collapse to exactly one pump")
    }

    func testDisabledSessionRefusesPrepare() throws {
        let store = try makeStore()
        let coordinator = TwoWayCoordinator(
            store: store,
            locateSessionFile: { _ in nil },
            adapters: [StubAdapter()]
        )
        XCTAssertThrowsError(try coordinator.prepare(text: "go", sessionID: "s1", sourceKind: "codex"))
    }

    func testStartupFailsInterruptedInstructionsClosed() throws {
        let store = try makeStore()
        let engine = InstructionReplyEngine(store: store)
        engine.setTwoWayEnabled(true, forSessionID: "s1")
        let confirmed = try engine.submit(text: "queued", sessionID: "s1", sourceKind: "codex", now: Date())
        _ = try engine.confirm(id: confirmed.id, now: Date())
        try store.upsertInstruction(Instruction(
            id: "delivering",
            sessionID: "s2",
            sourceKind: "codex",
            text: "possibly sent",
            state: .delivering,
            createdAt: Date()
        ))

        let coordinator = TwoWayCoordinator(store: store, locateSessionFile: { _ in nil }, adapters: [StubAdapter()])

        XCTAssertEqual(coordinator.log.first(where: { $0.id == confirmed.id })?.state, .failed)
        XCTAssertEqual(coordinator.log.first(where: { $0.id == "delivering" })?.state, .failed)
        XCTAssertTrue(coordinator.log.allSatisfy { $0.error?.contains("restarted") == true })
        XCTAssertTrue(coordinator.startupRecoveryMessage?.contains("Review the frozen target and resend") == true)
    }

    private func writeReadyCodexSession(to url: URL) throws {
        try Data("""
        {"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"text":"Ready."}]}}

        """.utf8).write(to: url)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
