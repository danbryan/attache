import XCTest
import AttacheCore
@testable import AttacheApp

@MainActor
final class TwoWayDeliveryAdapterTests: XCTestCase {
    private var now: Date { Date(timeIntervalSince1970: 2_000_000) }

    func testClaudeResumeArguments() {
        let args = AgentResumeDeliveryAdapter.resumeArguments(vendor: .claude, sessionID: "sid-1", instruction: "run the tests")
        XCTAssertEqual(args, ["-p", "--resume", "sid-1", "run the tests"])
        // Must NOT carry the summarizer's sandbox/deny flags: this path is meant to act.
        XCTAssertFalse(args.contains("--tools"))
        XCTAssertFalse(args.contains("--permission-mode"))
    }

    func testCodexResumeArguments() {
        let args = AgentResumeDeliveryAdapter.resumeArguments(vendor: .codex, sessionID: "sid-2", instruction: "commit it")
        XCTAssertEqual(args, ["exec", "resume", "sid-2", "commit it"])
    }

    func testMergedPathIncludesHomebrewNodeForFinderLaunchedApp() {
        let path = CLILanguageModel.mergedPATH(existing: "/usr/bin:/bin", home: "/Users/tester")
        let parts = path.split(separator: ":").map(String.init)

        XCTAssertEqual(parts.first, "/Users/tester/.local/bin")
        XCTAssertTrue(parts.contains("/opt/homebrew/bin"))
        XCTAssertTrue(parts.contains("/usr/local/bin"))
        XCTAssertEqual(parts.filter { $0 == "/usr/bin" }.count, 1)
    }

    func testCapabilityUnavailableWhenCLIMissing() {
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .claude,
            locateSessionFile: { _ in URL(fileURLWithPath: "/tmp/x.jsonl") },
            locateExecutable: { _ in nil }
        )
        let cap = adapter.capability(forSessionID: "s")
        XCTAssertFalse(cap.canDeliver)
        XCTAssertNotNil(cap.reason)
    }

    func testCapabilityUnavailableWhenSessionMissing() {
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .codex,
            locateSessionFile: { _ in nil },
            locateExecutable: { _ in "/usr/local/bin/codex" }
        )
        XCTAssertFalse(adapter.capability(forSessionID: "s").canDeliver)
    }

    func testCapabilityRequiresIdleWhenAvailable() {
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .claude,
            locateSessionFile: { _ in URL(fileURLWithPath: "/tmp/x.jsonl") },
            locateExecutable: { _ in "/usr/local/bin/claude" }
        )
        let cap = adapter.capability(forSessionID: "s")
        XCTAssertTrue(cap.canDeliver)
        XCTAssertTrue(cap.requiresIdle)
    }

    func testDeliverSuccessOnExitZero() async {
        let sessionFile = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-checkpoint-\(UUID().uuidString).jsonl")
        try? Data("checkpoint".utf8).write(to: sessionFile)
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .claude,
            locateSessionFile: { _ in sessionFile },
            locateExecutable: { _ in "/usr/local/bin/claude" },
            spawn: { _, _ in (0, "") }
        )
        let instruction = Instruction(id: "i1", sessionID: "s1", sourceKind: "claude_code", text: "go", createdAt: now)
        let result = await adapter.deliver(instruction)
        switch result {
        case .success(let receipt):
            XCTAssertEqual(receipt.mechanism, "headless-resume")
            XCTAssertEqual(receipt.transcriptCheckpoint, 10)
        case .failure(let error): XCTFail("expected success, got \(error)")
        }
    }

    func testDeliverFailsWithStderrOnNonZeroExit() async {
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .codex,
            locateSessionFile: { _ in URL(fileURLWithPath: "/tmp/x.jsonl") },
            locateExecutable: { _ in "/usr/local/bin/codex" },
            spawn: { _, _ in (1, "session is busy") }
        )
        let instruction = Instruction(id: "i2", sessionID: "s1", sourceKind: "codex", text: "go", createdAt: now)
        let result = await adapter.deliver(instruction)
        if case .failure(.deliveryFailed(let detail)) = result {
            XCTAssertEqual(detail, "session is busy")
        } else {
            XCTFail("expected deliveryFailed")
        }
    }

    func testDeliveryReadinessRequiresStableCompletedCodexTurn() {
        let final = codexAssistant("Ready.", phase: "final_answer")
        let previous = observation(size: 100, seconds: 0, lines: [final])
        let stable = observation(size: 100, seconds: 8, lines: [final])
        let growing = observation(size: 120, seconds: 8, lines: [final])

        XCTAssertTrue(SessionDeliveryReadinessClassifier.isReady(
            previous: previous, current: stable, format: .codex,
            now: now.addingTimeInterval(10), quietWindow: 6
        ))
        XCTAssertFalse(SessionDeliveryReadinessClassifier.isReady(
            previous: previous, current: growing, format: .codex,
            now: now.addingTimeInterval(10), quietWindow: 6
        ))
    }

    func testDeliveryReadinessRejectsPendingToolTrailingUserAndPartialAssistant() {
        let pendingTool = #"{"type":"response_item","payload":{"type":"function_call","name":"shell","call_id":"c1"}}"#
        let trailingUser = codexUser("keep going")
        let partial = codexAssistant("Still working.", phase: "commentary")

        XCTAssertFalse(SessionDeliveryReadinessClassifier.turnIsComplete(tailLines: [pendingTool], format: .codex))
        XCTAssertFalse(SessionDeliveryReadinessClassifier.turnIsComplete(
            tailLines: [codexAssistant("Done.", phase: "final_answer"), trailingUser], format: .codex
        ))
        XCTAssertFalse(SessionDeliveryReadinessClassifier.turnIsComplete(tailLines: [partial], format: .codex))
    }

    func testDeliveryReadinessHandlesClaudeCompletedAndPendingTurns() {
        let completed = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Finished."}]}}"#
        let pending = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Checking."},{"type":"tool_use","name":"Bash","id":"t1"}]}}"#
        let result = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}"#

        XCTAssertTrue(SessionDeliveryReadinessClassifier.turnIsComplete(tailLines: [completed], format: .claude))
        XCTAssertFalse(SessionDeliveryReadinessClassifier.turnIsComplete(tailLines: [pending], format: .claude))
        XCTAssertFalse(SessionDeliveryReadinessClassifier.turnIsComplete(tailLines: [pending, result], format: .claude))
    }

    func testEngineNeverDeliversWhileSessionBusy() async throws {
        // End-to-end via the engine: a mid-turn (busy) session must not be written.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attache-twoway-\(UUID().uuidString).sqlite")
        let store = try CardStore(databaseURL: url)
        let engine = InstructionReplyEngine(store: store)
        var spawnCount = 0
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .claude,
            locateSessionFile: { _ in URL(fileURLWithPath: "/tmp/x.jsonl") },
            locateExecutable: { _ in "/usr/local/bin/claude" },
            spawn: { _, _ in spawnCount += 1; return (0, "") }
        )
        engine.register(adapter)
        engine.setTwoWayEnabled(true, forSessionID: "s1")
        let created = try engine.submit(text: "make the change", sessionID: "s1", sourceKind: "claude_code", now: now)
        _ = try engine.confirm(id: created.id, now: now)

        // Session is mid-turn: no spawn.
        _ = await engine.deliverReadyInstructions(sessionIsIdle: { _ in false }, now: now)
        XCTAssertEqual(spawnCount, 0)

        // Session goes quiet: delivered exactly once.
        _ = await engine.deliverReadyInstructions(sessionIsIdle: { _ in true }, now: now)
        XCTAssertEqual(spawnCount, 1)
    }

    private func observation(size: Int64, seconds: TimeInterval, lines: [String]) -> SessionFileObservation {
        SessionFileObservation(
            size: size,
            modifiedAt: now,
            observedAt: now.addingTimeInterval(seconds),
            tailLines: lines
        )
    }

    private func codexUser(_ text: String) -> String {
        #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"\#(text)"}]}}"#
    }

    private func codexAssistant(_ text: String, phase: String) -> String {
        #"{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"\#(phase)","content":[{"text":"\#(text)"}]}}"#
    }
}
