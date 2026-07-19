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

    func testGrokResumeArguments() {
        let args = AgentResumeDeliveryAdapter.resumeArguments(vendor: .grok, sessionID: "sid-3", instruction: "run it")
        // Top-level grok flags (INF-394); `grok agent --resume` is rejected by the CLI.
        XCTAssertEqual(args, ["--resume", "sid-3", "--output-format", "json", "-p", "run it"])
        XCTAssertFalse(args.contains("agent"))
        XCTAssertEqual(AgentResumeDeliveryAdapter.Vendor.grok.executableName, "grok")
        XCTAssertEqual(AgentResumeDeliveryAdapter.Vendor.grok.sourceKind, SourceKind.grokBuild.rawValue)
    }

    func testGrokCapabilityUnavailableWhenCLIMissing() {
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .grok,
            locateSessionFile: { _ in URL(fileURLWithPath: "/tmp/x/chat_history.jsonl") },
            locateExecutable: { _ in nil }
        )
        let cap = adapter.capability(forSessionID: "s")
        XCTAssertFalse(cap.canDeliver)
        XCTAssertEqual(cap.reason, "Two-way unavailable: the grok CLI was not found on PATH.")
    }

    func testGrokCapabilityRequiresIdleWhenAvailable() {
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .grok,
            locateSessionFile: { _ in URL(fileURLWithPath: "/tmp/x/chat_history.jsonl") },
            locateExecutable: { _ in "/Users/tester/.grok/bin/grok" }
        )
        let cap = adapter.capability(forSessionID: "s")
        XCTAssertTrue(cap.canDeliver)
        XCTAssertTrue(cap.requiresIdle)
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
            spawn: { _, _, _, _ in ProcessRunResult(exitCode: 0, stdout: Self.claudeSuccessJSON(result: "DONE"), stderr: "", timedOut: false) }
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

    // MARK: - INF-260: Claude resume spawns with the session's working directory

    func testClaudeDeliverySpawnsWithInstructionWorkingDirectory() async {
        actor SpawnRecorder {
            private(set) var workingDirectory: String??
            func record(_ value: String?) { workingDirectory = value }
        }
        let recorder = SpawnRecorder()
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .claude,
            locateSessionFile: { _ in URL(fileURLWithPath: "/tmp/x.jsonl") },
            locateExecutable: { _ in "/usr/local/bin/claude" },
            spawn: { _, _, _, workingDirectory in
                await recorder.record(workingDirectory)
                return ProcessRunResult(exitCode: 0, stdout: Self.claudeSuccessJSON(result: "DONE"), stderr: "", timedOut: false)
            }
        )
        let instruction = Instruction(
            id: "i1", sessionID: "s1", sourceKind: "claude_code", text: "go", createdAt: now,
            workingDirectory: "/Users/tester/code/project"
        )
        _ = await adapter.deliver(instruction)
        let captured = await recorder.workingDirectory
        XCTAssertEqual(captured, "/Users/tester/code/project")
    }

    func testCodexDeliveryNeverSpawnsWithAWorkingDirectory() async {
        actor SpawnRecorder {
            private(set) var workingDirectory: String??
            func record(_ value: String?) { workingDirectory = value }
        }
        let recorder = SpawnRecorder()
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .codex,
            locateSessionFile: { _ in URL(fileURLWithPath: "/tmp/x.jsonl") },
            locateExecutable: { _ in "/usr/local/bin/codex" },
            spawn: { _, _, _, workingDirectory in
                await recorder.record(workingDirectory)
                return ProcessRunResult(exitCode: 0, stdout: #"{"type":"item.completed","item":{"type":"agent_message","text":"done"}}"#, stderr: "", timedOut: false)
            }
        )
        // Even though the instruction carries a working directory, Codex's
        // --skip-git-repo-check is already cwd-independent, so its spawn
        // behavior must stay exactly as it was before INF-260.
        let instruction = Instruction(
            id: "i2", sessionID: "s2", sourceKind: "codex", text: "go", createdAt: now,
            workingDirectory: "/Users/tester/code/project"
        )
        _ = await adapter.deliver(instruction)
        let captured = await recorder.workingDirectory
        XCTAssertEqual(captured, .some(nil))
    }

    // MARK: - INF-238: delivery evidence, both vendors

    func testDeliverSuccessWithEvidenceClaude() async {
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .claude,
            locateSessionFile: { _ in URL(fileURLWithPath: "/tmp/x.jsonl") },
            locateExecutable: { _ in "/usr/local/bin/claude" },
            spawn: { _, _, _, _ in
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
            spawn: { _, _, _, _ in
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

    func testDeliverSuccessWithEvidenceGrokResultObject() async {
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .grok,
            locateSessionFile: { _ in URL(fileURLWithPath: "/tmp/x/chat_history.jsonl") },
            locateExecutable: { _ in "/Users/tester/.grok/bin/grok" },
            spawn: { _, _, _, _ in
                ProcessRunResult(
                    exitCode: 0,
                    stdout: Self.grokSuccessJSON(result: "PONG_GROK", sessionID: "a1b2c3d4-0000-0000-0000-000000000001"),
                    stderr: "",
                    timedOut: false
                )
            }
        )
        let instruction = Instruction(id: "i-grok-ok", sessionID: "s1", sourceKind: "grok_build", text: "reply pong", createdAt: now)
        let result = await adapter.deliver(instruction)
        guard case .success(let receipt) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(receipt.replyText, "PONG_GROK")
        XCTAssertEqual(receipt.replyTurnID, "a1b2c3d4-0000-0000-0000-000000000001")
    }

    func testDeliverGrokFailsWhenExitZeroWithoutEvidence() async {
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .grok,
            locateSessionFile: { _ in URL(fileURLWithPath: "/tmp/x/chat_history.jsonl") },
            locateExecutable: { _ in "/Users/tester/.grok/bin/grok" },
            spawn: { _, _, _, _ in ProcessRunResult(exitCode: 0, stdout: "", stderr: "", timedOut: false) }
        )
        let instruction = Instruction(id: "i-grok-noop", sessionID: "s1", sourceKind: "grok_build", text: "go", createdAt: now)
        if case .success = await adapter.deliver(instruction) {
            XCTFail("exit 0 with empty stdout must not count as a delivered Grok turn")
        }
    }

    func testGrokEvidenceParsesTheRealResultObject() {
        // Verbatim shape captured live from `grok --resume <id> --output-format
        // json -p "..."` (grok 0.1.219, INF-394 gate forensics): a single
        // pretty-printed object with `text`, `stopReason`, `sessionId`, and
        // `requestId`. No Claude-style `result` field exists.
        let stdout = """
        {
          "text": "PONG_SHAPE_2",
          "stopReason": "EndTurn",
          "sessionId": "019f77f8-4067-72d2-a12b-9bef546692fc",
          "requestId": "01c38df7-ee5e-4eef-aa8e-7076354c8588",
          "thought": "The user wants me to reply exactly.",
          "usage": { "input_tokens": 1153, "output_tokens": 31 },
          "num_turns": 2
        }
        """
        let evidence = AgentResumeDeliveryAdapter.evidence(forVendor: .grok, stdout: stdout)
        XCTAssertEqual(evidence?.replyText, "PONG_SHAPE_2")
        XCTAssertEqual(evidence?.turnID, "01c38df7-ee5e-4eef-aa8e-7076354c8588")
    }

    func testGrokEvidenceParsesStreamingFallback() {
        // streaming-json / JSONL: a trailing result line still proves the turn.
        let stream = [
            #"{"type":"assistant","content":""}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"STREAM_PONG","session_id":"sid-stream"}"#
        ].joined(separator: "\n")
        let evidence = AgentResumeDeliveryAdapter.evidence(forVendor: .grok, stdout: stream)
        XCTAssertEqual(evidence?.replyText, "STREAM_PONG")
        XCTAssertEqual(evidence?.turnID, "sid-stream")
    }

    func testDeliverFailsWhenExitZeroWithoutEvidenceClaude() async {
        // A stale/wrong session id or a rejected turn can exit 0 with empty or
        // unparseable stdout; exit code alone must never be treated as delivered.
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .claude,
            locateSessionFile: { _ in URL(fileURLWithPath: "/tmp/x.jsonl") },
            locateExecutable: { _ in "/usr/local/bin/claude" },
            spawn: { _, _, _, _ in ProcessRunResult(exitCode: 0, stdout: "", stderr: "", timedOut: false) }
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
            spawn: { _, _, _, _ in
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
            spawn: { _, _, _, _ in ProcessRunResult(exitCode: 1, stdout: "", stderr: "session is busy", timedOut: false) }
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
            spawn: { _, _, _, _ in
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
            spawn: { _, _, _, _ in ProcessRunResult(exitCode: -1, stdout: "", stderr: "", timedOut: true) }
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
            spawn: { _, _, _, _ in ProcessRunResult(exitCode: -1, stdout: "", stderr: "", timedOut: true) }
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

    func testDefaultSpawnTimeoutSurvivesAProcessThatIgnoresSigterm() async {
        // Regression for the 2026-07-11 crash: the timeout path used to read
        // `terminationStatus` right after `terminate()`, and Foundation throws
        // a fatal NSException if the child has not actually exited yet. A
        // child that ignores SIGTERM makes that race deterministic; without
        // the fix this test dies with SIGABRT instead of failing politely.
        let result = await AgentResumeDeliveryAdapter.defaultSpawn(
            "/bin/sh", ["-c", "trap '' TERM; sleep 10"], timeout: 1)
        XCTAssertTrue(result.timedOut)
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

    private nonisolated static func grokSuccessJSON(result: String, sessionID: String = "a1b2c3d4-0000-0000-0000-000000000001") -> String {
        // Grok's `--output-format json` mirrors Claude Code's headless result object (INF-394).
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
            spawn: { _, _, _, _ in
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

    // MARK: - INF-241: fake Claude home fixture, end-to-end delivery coverage
    //
    // These run scripts/create-fake-claude-home.py for real and spawn its
    // generated fake `claude` executable through AgentResumeDeliveryAdapter's
    // *real* defaultSpawn (no injected `spawn` stub), so the `claude -p --resume
    // --output-format json` branch is exercised end to end with no network and
    // no real claude CLI involved.

    private struct FakeClaudeHome {
        let home: String
        let executable: String
        let targetSessionID: String
        let targetSessionFile: String
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Runs scripts/create-fake-claude-home.py and parses its JSON summary.
    private func makeFakeClaudeHome(nonce: String) throws -> FakeClaudeHome {
        let script = Self.repoRoot.appendingPathComponent("scripts/create-fake-claude-home.py")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("attache-fake-claude-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, "--home", home.path, "--nonce", nonce]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "create-fake-claude-home.py exited nonzero")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: String])
        return FakeClaudeHome(
            home: try XCTUnwrap(json["home"]),
            executable: try XCTUnwrap(json["fake_claude_executable"]),
            targetSessionID: try XCTUnwrap(json["target_session_id"]),
            targetSessionFile: try XCTUnwrap(json["target_session_file"])
        )
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }

    private static func tailLines(of url: URL, limit: Int = 20) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.split(whereSeparator: \.isNewline).map(String.init).suffix(limit))
    }

    func testFakeClaudeDeliverySucceedsWithEvidenceEndToEnd() async throws {
        let fixture = try makeFakeClaudeHome(nonce: "success-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(atPath: fixture.home) }
        setenv("ATTACHE_FAKE_CLAUDE_HOME", fixture.home, 1)
        defer { unsetenv("ATTACHE_FAKE_CLAUDE_HOME") }

        let sessionFileURL = URL(fileURLWithPath: fixture.targetSessionFile)
        let beforeSize = Self.fileSize(sessionFileURL)
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .claude,
            locateSessionFile: { _ in sessionFileURL },
            locateExecutable: { _ in fixture.executable }
        )
        let instruction = Instruction(id: "i-success", sessionID: fixture.targetSessionID, sourceKind: "claude_code", text: "run the tests", createdAt: now)

        let result = await adapter.deliver(instruction)

        switch result {
        case .success(let receipt):
            XCTAssertEqual(receipt.mechanism, "headless-resume")
            XCTAssertEqual(receipt.transcriptCheckpoint, beforeSize)
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }

        // Evidence: the fake CLI appended a real-shaped, non-sidechain, completed
        // assistant turn (mirroring the real `--output-format json` success
        // contract), so the readiness classifier now sees a completed turn and the
        // file actually grew.
        let tail = Self.tailLines(of: sessionFileURL)
        XCTAssertTrue(SessionDeliveryReadinessClassifier.turnIsComplete(tailLines: tail, format: .claude))
        XCTAssertTrue(tail.contains { $0.contains("DONE: run the tests") })
        if let before = beforeSize, let after = Self.fileSize(sessionFileURL) {
            XCTAssertGreaterThan(after, before)
        } else {
            XCTFail("expected readable file sizes before and after delivery")
        }
    }

    func testFakeClaudeDeliveryFailsWhenExitZeroWithoutEvidence() async throws {
        // The exact gap the 2026-07-10 review called out (section 1, item 1):
        // a silent no-op (exit 0, no transcript evidence) must not be recorded
        // as a delivered turn. B1 (INF-238) fixed this by requiring parsed
        // evidence, not just exit code 0. `ATTACHE_FAKE_CLAUDE_MODE=no_evidence`
        // simulates the no-op: the fake CLI exits 0 without touching the
        // transcript or printing a result JSON object.
        let fixture = try makeFakeClaudeHome(nonce: "noevidence-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(atPath: fixture.home) }
        setenv("ATTACHE_FAKE_CLAUDE_HOME", fixture.home, 1)
        setenv("ATTACHE_FAKE_CLAUDE_MODE", "no_evidence", 1)
        defer {
            unsetenv("ATTACHE_FAKE_CLAUDE_HOME")
            unsetenv("ATTACHE_FAKE_CLAUDE_MODE")
        }

        let sessionFileURL = URL(fileURLWithPath: fixture.targetSessionFile)
        let beforeSize = Self.fileSize(sessionFileURL)
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .claude,
            locateSessionFile: { _ in sessionFileURL },
            locateExecutable: { _ in fixture.executable }
        )
        let instruction = Instruction(id: "i-noevidence", sessionID: fixture.targetSessionID, sourceKind: "claude_code", text: "run the tests", createdAt: now)

        let result = await adapter.deliver(instruction)

        if case .failure(.deliveryFailed(let detail)) = result {
            XCTAssertEqual(detail, "exited 0 but no assistant turn in output")
        } else {
            XCTFail("expected deliveryFailed for exit-0-without-evidence, got \(result)")
        }
        XCTAssertEqual(Self.fileSize(sessionFileURL), beforeSize, "no_evidence mode must not append a turn")
    }

    func testFakeClaudeDeliveryFailsWithStderrForUnknownSession() async throws {
        let fixture = try makeFakeClaudeHome(nonce: "nonzero-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(atPath: fixture.home) }
        setenv("ATTACHE_FAKE_CLAUDE_HOME", fixture.home, 1)
        defer { unsetenv("ATTACHE_FAKE_CLAUDE_HOME") }

        // A stale/rotated session id: Attaché still has a local transcript file
        // (locateSessionFile resolves fine), but it isn't in the fake CLI's
        // fixture manifest, exactly like the real CLI's verified failure mode.
        let staleSessionID = UUID().uuidString.lowercased()
        let sessionFileURL = URL(fileURLWithPath: fixture.targetSessionFile)
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .claude,
            locateSessionFile: { _ in sessionFileURL },
            locateExecutable: { _ in fixture.executable }
        )
        let instruction = Instruction(id: "i-nonzero", sessionID: staleSessionID, sourceKind: "claude_code", text: "run the tests", createdAt: now)

        let result = await adapter.deliver(instruction)

        if case .failure(.deliveryFailed(let detail)) = result {
            XCTAssertEqual(detail, "No conversation found with session ID: \(staleSessionID)")
        } else {
            XCTFail("expected deliveryFailed, got \(result)")
        }
    }

    func testFakeClaudeDeliveryShortHangStillResolvesNormally() async throws {
        // B1 (INF-238) added a hard process timeout, but it defaults to 5
        // minutes, so a brief hang well under that ceiling must still resolve
        // as a normal, evidence-backed success once the fake CLI wakes up
        // (the dedicated timeout tests in this file cover the ceiling itself,
        // e.g. testDeliverFailsOnTimeoutClaude / testDefaultSpawnEnforcesRealHardTimeout).
        let hangSeconds = 1.2
        let fixture = try makeFakeClaudeHome(nonce: "hang-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(atPath: fixture.home) }
        setenv("ATTACHE_FAKE_CLAUDE_HOME", fixture.home, 1)
        setenv("ATTACHE_FAKE_CLAUDE_MODE", "hang", 1)
        setenv("ATTACHE_FAKE_CLAUDE_HANG_SECONDS", String(hangSeconds), 1)
        defer {
            unsetenv("ATTACHE_FAKE_CLAUDE_HOME")
            unsetenv("ATTACHE_FAKE_CLAUDE_MODE")
            unsetenv("ATTACHE_FAKE_CLAUDE_HANG_SECONDS")
        }

        let sessionFileURL = URL(fileURLWithPath: fixture.targetSessionFile)
        let adapter = AgentResumeDeliveryAdapter(
            vendor: .claude,
            locateSessionFile: { _ in sessionFileURL },
            locateExecutable: { _ in fixture.executable }
        )
        let instruction = Instruction(id: "i-hang", sessionID: fixture.targetSessionID, sourceKind: "claude_code", text: "run the tests", createdAt: now)

        let start = Date()
        let result = await adapter.deliver(instruction)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThanOrEqual(elapsed, hangSeconds - 0.2, "delivery should wait out the hang rather than give up early")
        switch result {
        case .success:
            break // the fake CLI wakes up and completes normally; the hang is well under the timeout ceiling
        case .failure(let error):
            XCTFail("expected the hang to resolve into a normal success once the fake CLI woke up, got \(error)")
        }
    }

    // MARK: - INF-395: opencode two-way delivery adapter

    private typealias OMessageRow = OpencodeTranscriptAdapter.MessageRow

    // nonisolated so they can be referenced from the adapters' @Sendable closures.
    private nonisolated static func opencodeSnapshot(directory: String?, messages: [OMessageRow]) -> OpencodeSessionSnapshot {
        OpencodeSessionSnapshot(directory: directory, messages: messages)
    }

    private nonisolated static func opencodeReadyMessages() -> [OMessageRow] {
        [
            OMessageRow(id: "m1", role: "user", finish: nil, timeCreated: 1000, parts: [.init(type: "text", text: "reply pong")]),
            OMessageRow(id: "m2", role: "assistant", finish: "stop", timeCreated: 2000, parts: [.init(type: "text", text: "done")])
        ]
    }

    func testOpencodeResumeArguments() {
        // opencode run --session <id> --format json "<text>". Never -m/--model
        // (session/config decide) and never opencode's -p (that is --password).
        let args = OpencodeResumeDeliveryAdapter.resumeArguments(sessionID: "ses_1", instruction: "reply pong")
        XCTAssertEqual(args, ["run", "--session", "ses_1", "--format", "json", "reply pong"])
        XCTAssertFalse(args.contains("-m"))
        XCTAssertFalse(args.contains("--model"))
        XCTAssertFalse(args.contains("-p"))
    }

    func testOpencodeCapabilityUnavailableWhenCLIMissing() {
        let adapter = OpencodeResumeDeliveryAdapter(
            loadSnapshot: { _ in Self.opencodeSnapshot(directory: "/tmp/p", messages: Self.opencodeReadyMessages()) },
            locateExecutable: { _ in nil }
        )
        let cap = adapter.capability(forSessionID: "ses_1")
        XCTAssertFalse(cap.canDeliver)
        XCTAssertEqual(cap.reason, "Two-way unavailable: the opencode CLI was not found on PATH.")
    }

    func testOpencodeCapabilityUnavailableWhenSessionMissing() {
        let adapter = OpencodeResumeDeliveryAdapter(
            loadSnapshot: { _ in nil },
            locateExecutable: { _ in "/opt/homebrew/bin/opencode" }
        )
        let cap = adapter.capability(forSessionID: "ses_gone")
        XCTAssertFalse(cap.canDeliver)
        XCTAssertEqual(cap.reason, "Two-way unavailable: no opencode session for this session yet.")
    }

    func testOpencodeCapabilityRequiresIdleWhenAvailable() {
        let adapter = OpencodeResumeDeliveryAdapter(
            loadSnapshot: { _ in Self.opencodeSnapshot(directory: "/tmp/p", messages: Self.opencodeReadyMessages()) },
            locateExecutable: { _ in "/opt/homebrew/bin/opencode" }
        )
        let cap = adapter.capability(forSessionID: "ses_1")
        XCTAssertTrue(cap.canDeliver)
        XCTAssertTrue(cap.requiresIdle)
    }

    /// Process exits on its own before the DB poll finds a reply: today's
    /// stdout-evidence path still applies (the DB has no completed turn after
    /// the checkpoint here, so the exit wins the race).
    func testOpencodeDeliverySucceedsWithCheckpointAndEvidence() async {
        let stdout = [
            #"{"type":"message.updated","properties":{"info":{"id":"msg_a","role":"assistant","sessionID":"ses_1"}}}"#,
            #"{"type":"message.part.updated","properties":{"part":{"type":"text","text":"PONG_OPENCODE"}}}"#
        ].joined(separator: "\n")
        let adapter = OpencodeResumeDeliveryAdapter(
            loadSnapshot: { _ in Self.opencodeSnapshot(directory: "/tmp/p", messages: Self.opencodeReadyMessages()) },
            locateExecutable: { _ in "/opt/homebrew/bin/opencode" },
            startProcess: { _, _, _ in ExitingOpencodeProcess(ProcessRunResult(exitCode: 0, stdout: stdout, stderr: "", timedOut: false)) }
        )
        let instruction = Instruction(id: "i-oc", sessionID: "ses_1", sourceKind: "opencode", text: "reply pong", createdAt: now)
        guard case .success(let receipt) = await adapter.deliver(instruction) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(receipt.mechanism, "opencode-run")
        // Checkpoint = the pre-delivery latest message time (ms), not a byte offset.
        XCTAssertEqual(receipt.transcriptCheckpoint, 2000)
        XCTAssertEqual(receipt.replyText, "PONG_OPENCODE")
    }

    /// New completion path (INF-395): `opencode run` lingers (never exits) after
    /// writing the reply, so delivery must complete off the DATABASE and then
    /// terminate the lingering child - not wait for process exit (which is what
    /// timed out at 300s in the live gate).
    func testOpencodeDeliverySucceedsWhenReplyLandsWhileProcessLingers() async {
        // Snapshot flips mid-delivery: the pre-delivery state (checkpoint) has
        // only the user turn; a later poll returns the completed assistant reply.
        let initial = Self.opencodeSnapshot(directory: "/tmp/p", messages: [
            OMessageRow(id: "u1", role: "user", finish: nil, timeCreated: 1000, parts: [.init(type: "text", text: "reply pong")])
        ])
        let withReply = Self.opencodeSnapshot(directory: "/tmp/p", messages: [
            OMessageRow(id: "u1", role: "user", finish: nil, timeCreated: 1000, parts: [.init(type: "text", text: "reply pong")]),
            OMessageRow(id: "a1", role: "assistant", finish: "stop", timeCreated: 2000, parts: [.init(type: "text", text: "PONG_DB")])
        ])
        let resolver = FlippingSnapshotResolver(initial: initial, withReply: withReply, flipAfterCalls: 1)
        let process = LingeringOpencodeProcess()
        let adapter = OpencodeResumeDeliveryAdapter(
            loadSnapshot: { _ in resolver.next() },
            locateExecutable: { _ in "/opt/homebrew/bin/opencode" },
            processTimeout: 5,
            replyPollInterval: 0.02,
            startProcess: { _, _, _ in process }
        )
        let instruction = Instruction(id: "i-oc-linger", sessionID: "ses_1", sourceKind: "opencode", text: "reply pong", createdAt: now)
        guard case .success(let receipt) = await adapter.deliver(instruction) else {
            return XCTFail("expected success from the DB reply while the process lingered")
        }
        XCTAssertEqual(receipt.replyText, "PONG_DB", "the authoritative DB turn is the evidence")
        XCTAssertEqual(receipt.transcriptCheckpoint, 1000)
        XCTAssertTrue(process.terminateRequested, "the lingering child must be terminated once the reply lands")
    }

    func testOpencodeDeliverySpawnsInSessionWorkingDirectory() async {
        let recorder = WorkingDirectoryRecorder()
        let stdout = #"{"type":"message.part.updated","properties":{"part":{"type":"text","text":"ok"},"info":{"role":"assistant"}}}"#
        let adapter = OpencodeResumeDeliveryAdapter(
            loadSnapshot: { _ in Self.opencodeSnapshot(directory: "/tmp/from-db", messages: Self.opencodeReadyMessages()) },
            locateExecutable: { _ in "/opt/homebrew/bin/opencode" },
            startProcess: { _, _, workingDirectory in
                recorder.record(workingDirectory)
                return ExitingOpencodeProcess(ProcessRunResult(exitCode: 0, stdout: stdout, stderr: "", timedOut: false))
            }
        )
        // The frozen instruction working directory wins over the DB directory.
        let instruction = Instruction(
            id: "i-oc-cwd", sessionID: "ses_1", sourceKind: "opencode", text: "go", createdAt: now,
            workingDirectory: "/Users/tester/proj"
        )
        _ = await adapter.deliver(instruction)
        XCTAssertEqual(recorder.captured, "/Users/tester/proj")
    }

    func testOpencodeDeliveryFailsWhenSessionGone() async {
        let adapter = OpencodeResumeDeliveryAdapter(
            loadSnapshot: { _ in nil },
            locateExecutable: { _ in "/opt/homebrew/bin/opencode" },
            startProcess: { _, _, _ in
                XCTFail("a missing session must fail before any process is started")
                return ExitingOpencodeProcess(ProcessRunResult(exitCode: 0, stdout: "", stderr: "", timedOut: false))
            }
        )
        let instruction = Instruction(id: "i-oc-gone", sessionID: "ses_gone", sourceKind: "opencode", text: "go", createdAt: now)
        guard case .failure(.sessionGone) = await adapter.deliver(instruction) else {
            return XCTFail("expected sessionGone")
        }
    }

    func testOpencodeDeliveryFailsWhenExitZeroWithoutEvidence() async {
        // Process exits 0 with no assistant text and the DB has no reply: fail closed.
        let adapter = OpencodeResumeDeliveryAdapter(
            loadSnapshot: { _ in Self.opencodeSnapshot(directory: "/tmp/p", messages: Self.opencodeReadyMessages()) },
            locateExecutable: { _ in "/opt/homebrew/bin/opencode" },
            startProcess: { _, _, _ in ExitingOpencodeProcess(ProcessRunResult(exitCode: 0, stdout: #"{"type":"session.idle"}"#, stderr: "", timedOut: false)) }
        )
        let instruction = Instruction(id: "i-oc-noev", sessionID: "ses_1", sourceKind: "opencode", text: "go", createdAt: now)
        guard case .failure(.deliveryFailed(let detail)) = await adapter.deliver(instruction) else {
            return XCTFail("expected deliveryFailed")
        }
        XCTAssertEqual(detail, "exited 0 but no assistant turn in output")
    }

    func testOpencodeEvidenceIgnoresUserEchoWithoutAssistantMarker() {
        // A stream that only echoes the user turn (no assistant role marker
        // anywhere) is not evidence of a completed reply.
        let stdout = #"{"type":"message.part.updated","properties":{"part":{"type":"text","text":"the user instruction"},"info":{"role":"user"}}}"#
        XCTAssertNil(OpencodeResumeDeliveryAdapter.evidence(fromStdout: stdout))
    }

    /// Regression (INF-395 gate): the spawned CLI must get a nulled stdin.
    /// `/bin/cat` with no arguments reads stdin until EOF, so with an
    /// inherited never-EOF descriptor it hangs to the timeout (exactly how
    /// `opencode run` stalled for 300s in the live f24 gate), while a nulled
    /// stdin returns immediately with exit 0.
    func testDefaultSpawnNullsChildStdinSoStdinReadersExitImmediately() async {
        let result = await AgentResumeDeliveryAdapter.defaultSpawn(
            "/bin/cat", [], timeout: 10
        )
        XCTAssertFalse(result.timedOut, "cat must see EOF instantly from a nulled stdin, never hang to the timeout")
        XCTAssertEqual(result.exitCode, 0)
    }

    /// Neither a DB reply nor a process exit within the window: fail as timed
    /// out, and still terminate the lingering child so it never orphans.
    func testOpencodeDeliveryFailsOnTimeout() async {
        let process = LingeringOpencodeProcess()
        let adapter = OpencodeResumeDeliveryAdapter(
            loadSnapshot: { _ in Self.opencodeSnapshot(directory: "/tmp/p", messages: Self.opencodeReadyMessages()) },
            locateExecutable: { _ in "/opt/homebrew/bin/opencode" },
            processTimeout: 0.3,
            replyPollInterval: 0.05,
            startProcess: { _, _, _ in process }
        )
        let instruction = Instruction(id: "i-oc-timeout", sessionID: "ses_1", sourceKind: "opencode", text: "go", createdAt: now)
        guard case .failure(.deliveryFailed(let detail)) = await adapter.deliver(instruction) else {
            return XCTFail("expected deliveryFailed")
        }
        XCTAssertTrue(detail.lowercased().contains("timed out"), "expected a timeout message, got: \(detail)")
        XCTAssertTrue(process.terminateRequested, "a timed-out delivery must still terminate the lingering child")
    }
}

// MARK: - INF-395 opencode process test doubles (shared across two-way tests)

import AttacheCore

/// A fake `OpencodeRunningProcess` that exits immediately with a fixed result
/// (the "process exits on its own first" branch).
final class ExitingOpencodeProcess: OpencodeRunningProcess, @unchecked Sendable {
    private let result: ProcessRunResult
    init(_ result: ProcessRunResult) { self.result = result }
    func waitForExit() async -> ProcessRunResult { result }
    func terminate() {}
}

/// A fake `OpencodeRunningProcess` that NEVER exits on its own, mirroring the
/// real lingering `opencode run`: `waitForExit()` only resolves once
/// `terminate()` is called, and records that termination was requested.
final class LingeringOpencodeProcess: OpencodeRunningProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessRunResult, Never>?
    private var finished = false
    private var terminated = false

    var terminateRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return terminated
    }

    func waitForExit() async -> ProcessRunResult {
        await withCheckedContinuation { cont in
            lock.lock()
            if finished {
                lock.unlock()
                cont.resume(returning: ProcessRunResult(exitCode: -1, stdout: "", stderr: "", timedOut: false))
                return
            }
            continuation = cont
            lock.unlock()
        }
    }

    func terminate() {
        lock.lock()
        terminated = true
        finished = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: ProcessRunResult(exitCode: -1, stdout: "", stderr: "", timedOut: false))
    }
}

/// Returns `initial` for the first `flipAfterCalls` loads (so the delivery
/// checkpoint is captured from the pre-reply state), then `withReply`, so a
/// poll observes the completed turn appearing mid-delivery.
final class FlippingSnapshotResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let initial: OpencodeSessionSnapshot
    private let withReply: OpencodeSessionSnapshot
    private let flipAfterCalls: Int

    init(initial: OpencodeSessionSnapshot, withReply: OpencodeSessionSnapshot, flipAfterCalls: Int) {
        self.initial = initial
        self.withReply = withReply
        self.flipAfterCalls = flipAfterCalls
    }

    func next() -> OpencodeSessionSnapshot? {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return calls > flipAfterCalls ? withReply : initial
    }
}

/// Thread-safe capture of the working directory a `startProcess` was invoked
/// with (the closure is `@Sendable` and may run off the test's actor).
final class WorkingDirectoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String??
    func record(_ workingDirectory: String?) {
        lock.lock(); defer { lock.unlock() }
        value = workingDirectory
    }
    var captured: String?? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
