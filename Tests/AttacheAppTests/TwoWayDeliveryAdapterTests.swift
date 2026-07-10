import XCTest
import AttacheCore
@testable import AttacheApp

@MainActor
final class TwoWayDeliveryAdapterTests: XCTestCase {
    private var now: Date { Date(timeIntervalSince1970: 2_000_000) }

    func testClaudeResumeArguments() {
        let args = AgentResumeDeliveryAdapter.resumeArguments(vendor: .claude, sessionID: "sid-1", instruction: "run the tests")
        XCTAssertEqual(args, ["-p", "--resume", "sid-1", "--output-format", "json", "run the tests"])
        // Must NOT carry the summarizer's sandbox/deny flags: this path is meant to act.
        XCTAssertFalse(args.contains("--tools"))
        XCTAssertFalse(args.contains("--permission-mode"))
    }

    func testCodexResumeArguments() {
        let args = AgentResumeDeliveryAdapter.resumeArguments(vendor: .codex, sessionID: "sid-2", instruction: "commit it")
        XCTAssertEqual(args, ["exec", "resume", "--skip-git-repo-check", "--json", "sid-2", "commit it"])
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
            spawn: { _, _, _ in ProcessRunResult(exitCode: 0, stdout: Self.claudeSuccessJSON(result: "DONE"), stderr: "", timedOut: false) }
        )
        let instruction = Instruction(id: "i1", sessionID: "s1", sourceKind: "claude_code", text: "go", createdAt: now)
        let result = await adapter.deliver(instruction)
        switch result {
        case .success(let receipt):
            XCTAssertEqual(receipt.mechanism, "headless-resume")
            XCTAssertEqual(receipt.transcriptCheckpoint, 10)
            XCTAssertEqual(receipt.replyText, "DONE")
        case .failure(let error): XCTFail("expected success, got \(error)")
        }
    }

    // MARK: - INF-238: delivery evidence, both vendors

    func testDeliverSuccessWithEvidenceClaude() async {
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .claude,
            locateSessionFile: { _ in URL(fileURLWithPath: "/tmp/x.jsonl") },
            locateExecutable: { _ in "/usr/local/bin/claude" },
            spawn: { _, _, _ in
                ProcessRunResult(
                    exitCode: 0,
                    stdout: Self.claudeSuccessJSON(result: "Tests pass.", sessionID: "692006d2-abf1-4780-99b2-eb0ce808ba05"),
                    stderr: "",
                    timedOut: false
                )
            }
        )
        let instruction = Instruction(id: "i-claude-ok", sessionID: "s1", sourceKind: "claude_code", text: "run the tests", createdAt: now)
        let result = await adapter.deliver(instruction)
        guard case .success(let receipt) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(receipt.replyText, "Tests pass.")
        XCTAssertEqual(receipt.replyTurnID, "692006d2-abf1-4780-99b2-eb0ce808ba05")
    }

    func testDeliverSuccessWithEvidenceCodex() async {
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .codex,
            locateSessionFile: { _ in URL(fileURLWithPath: "/tmp/x.jsonl") },
            locateExecutable: { _ in "/usr/local/bin/codex" },
            spawn: { _, _, _ in
                ProcessRunResult(exitCode: 0, stdout: Self.codexSuccessJSONL(text: "PONG", threadID: "019f4d3d-aca0-74d3-a693-e2089d62ca7d"), stderr: "", timedOut: false)
            }
        )
        let instruction = Instruction(id: "i-codex-ok", sessionID: "s1", sourceKind: "codex", text: "reply pong", createdAt: now)
        let result = await adapter.deliver(instruction)
        guard case .success(let receipt) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(receipt.replyText, "PONG")
        XCTAssertEqual(receipt.replyTurnID, "019f4d3d-aca0-74d3-a693-e2089d62ca7d")
    }

    func testDeliverFailsWhenExitZeroWithoutEvidenceClaude() async {
        // A stale/wrong session id or a rejected turn can exit 0 with empty or
        // unparseable stdout; exit code alone must never be treated as delivered.
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .claude,
            locateSessionFile: { _ in URL(fileURLWithPath: "/tmp/x.jsonl") },
            locateExecutable: { _ in "/usr/local/bin/claude" },
            spawn: { _, _, _ in ProcessRunResult(exitCode: 0, stdout: "", stderr: "", timedOut: false) }
        )
        let instruction = Instruction(id: "i-claude-noev", sessionID: "s1", sourceKind: "claude_code", text: "go", createdAt: now)
        let result = await adapter.deliver(instruction)
        guard case .failure(.deliveryFailed(let detail)) = result else {
            return XCTFail("expected deliveryFailed, got \(result)")
        }
        XCTAssertEqual(detail, "exited 0 but no assistant turn in output")
    }

    func testDeliverFailsWhenExitZeroWithoutEvidenceCodex() async {
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .codex,
            locateSessionFile: { _ in URL(fileURLWithPath: "/tmp/x.jsonl") },
            locateExecutable: { _ in "/usr/local/bin/codex" },
            // Realistic partial stream: the thread started but never produced a
            // completed agent_message (e.g. it only ran a tool call).
            spawn: { _, _, _ in
                ProcessRunResult(
                    exitCode: 0,
                    stdout: #"{"type":"thread.started","thread_id":"t1"}"# + "\n" + #"{"type":"turn.started"}"#,
                    stderr: "",
                    timedOut: false
                )
            }
        )
        let instruction = Instruction(id: "i-codex-noev", sessionID: "s1", sourceKind: "codex", text: "go", createdAt: now)
        let result = await adapter.deliver(instruction)
        guard case .failure(.deliveryFailed(let detail)) = result else {
            return XCTFail("expected deliveryFailed, got \(result)")
        }
        XCTAssertEqual(detail, "exited 0 but no assistant turn in output")
    }

    func testDeliverFailsWithStderrOnNonZeroExit() async {
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .codex,
            locateSessionFile: { _ in URL(fileURLWithPath: "/tmp/x.jsonl") },
            locateExecutable: { _ in "/usr/local/bin/codex" },
            spawn: { _, _, _ in ProcessRunResult(exitCode: 1, stdout: "", stderr: "session is busy", timedOut: false) }
        )
        let instruction = Instruction(id: "i2", sessionID: "s1", sourceKind: "codex", text: "go", createdAt: now)
        let result = await adapter.deliver(instruction)
        if case .failure(.deliveryFailed(let detail)) = result {
            XCTAssertEqual(detail, "session is busy")
        } else {
            XCTFail("expected deliveryFailed")
        }
    }

    func testDeliverFailsWithStderrOnNonZeroExitClaude() async {
        // Verified real contract: an invalid/stale session id exits 1 with a
        // plain-text stderr message and empty stdout.
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .claude,
            locateSessionFile: { _ in URL(fileURLWithPath: "/tmp/x.jsonl") },
            locateExecutable: { _ in "/usr/local/bin/claude" },
            spawn: { _, _, _ in
                ProcessRunResult(
                    exitCode: 1,
                    stdout: "",
                    stderr: "No conversation found with session ID: 00000000-0000-0000-0000-000000000000",
                    timedOut: false
                )
            }
        )
        let instruction = Instruction(id: "i-claude-fail", sessionID: "s1", sourceKind: "claude_code", text: "go", createdAt: now)
        let result = await adapter.deliver(instruction)
        guard case .failure(.deliveryFailed(let detail)) = result else {
            return XCTFail("expected deliveryFailed, got \(result)")
        }
        XCTAssertEqual(detail, "No conversation found with session ID: 00000000-0000-0000-0000-000000000000")
    }

    func testDeliverFailsOnTimeoutClaude() async {
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .claude,
            locateSessionFile: { _ in URL(fileURLWithPath: "/tmp/x.jsonl") },
            locateExecutable: { _ in "/usr/local/bin/claude" },
            processTimeout: 5,
            spawn: { _, _, _ in ProcessRunResult(exitCode: -1, stdout: "", stderr: "", timedOut: true) }
        )
        let instruction = Instruction(id: "i-claude-timeout", sessionID: "s1", sourceKind: "claude_code", text: "go", createdAt: now)
        let result = await adapter.deliver(instruction)
        guard case .failure(.deliveryFailed(let detail)) = result else {
            return XCTFail("expected deliveryFailed, got \(result)")
        }
        XCTAssertTrue(detail.lowercased().contains("timed out"), "expected a timeout message, got: \(detail)")
    }

    func testDeliverFailsOnTimeoutCodex() async {
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .codex,
            locateSessionFile: { _ in URL(fileURLWithPath: "/tmp/x.jsonl") },
            locateExecutable: { _ in "/usr/local/bin/codex" },
            processTimeout: 5,
            spawn: { _, _, _ in ProcessRunResult(exitCode: -1, stdout: "", stderr: "", timedOut: true) }
        )
        let instruction = Instruction(id: "i-codex-timeout", sessionID: "s1", sourceKind: "codex", text: "go", createdAt: now)
        let result = await adapter.deliver(instruction)
        guard case .failure(.deliveryFailed(let detail)) = result else {
            return XCTFail("expected deliveryFailed, got \(result)")
        }
        XCTAssertTrue(detail.lowercased().contains("timed out"), "expected a timeout message, got: \(detail)")
    }

    func testDefaultSpawnEnforcesRealHardTimeout() async {
        // Exercises the real `defaultSpawn` (not an injected stub): a process
        // that outlives the (short, test-only) timeout must be cut off and
        // reported as timed out, rather than hanging the caller.
        let start = Date()
        let result = await AgentResumeDeliveryAdapter.defaultSpawn("/bin/sleep", ["10"], timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 8, "the hard timeout should cut the subprocess off well before it exits on its own")
    }

    private nonisolated static func claudeSuccessJSON(result: String, sessionID: String = "692006d2-abf1-4780-99b2-eb0ce808ba05") -> String {
        let payload: [String: Any] = [
            "type": "result",
            "subtype": "success",
            "is_error": false,
            "result": result,
            "session_id": sessionID
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func codexSuccessJSONL(text: String, threadID: String = "019f4d3d-aca0-74d3-a693-e2089d62ca7d") -> String {
        [
            #"{"type":"thread.started","thread_id":"\#(threadID)"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"\#(text)"}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}"#
        ].joined(separator: "\n")
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
            spawn: { _, _, _ in
                spawnCount += 1
                return ProcessRunResult(exitCode: 0, stdout: Self.claudeSuccessJSON(result: "done"), stderr: "", timedOut: false)
            }
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
