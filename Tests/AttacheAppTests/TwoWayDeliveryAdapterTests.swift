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

    func testFakeClaudeDeliveryReportsSuccessEvenWithoutEvidenceToday() async throws {
        // Pins the exact gap the 2026-07-10 review calls out (section 1, item 1):
        // AgentResumeDeliveryAdapter.deliver() only checks the exit code, so a
        // silent no-op (exit 0, no transcript evidence) is indistinguishable from
        // a real delivery today. `ATTACHE_FAKE_CLAUDE_MODE=no_evidence` simulates
        // exactly that: the fake CLI exits 0 without touching the transcript.
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

        guard case .success = result else {
            return XCTFail("expected today's exit-code-only verdict (success), got \(result)")
        }
        XCTAssertEqual(Self.fileSize(sessionFileURL), beforeSize, "no_evidence mode must not append a turn; the adapter's success verdict rests on exit code alone")
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

    func testFakeClaudeDeliveryHangBlocksForItsFullDurationTodayNoTimeoutExists() async throws {
        // AgentResumeDeliveryAdapter.deliver() has no built-in timeout, and
        // AttacheCore.withTimeout does not actually bound a Process-based CLI call
        // that never checks Task.isCancelled: withTaskGroup awaits every child
        // task before returning even after cancelAll() and an onTimeout() value
        // have been produced (verified empirically: wrapping a 3s-hanging
        // withCheckedContinuation operation in withTimeout(seconds: 0.5) still
        // took ~3.2s wall-clock to return). So this test pins today's real
        // behavior instead of a guard that does not exist: a hung claude process
        // blocks delivery for its full duration (review section 1, item 3:
        // "waiting and expiry are invisible").
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

        XCTAssertGreaterThanOrEqual(elapsed, hangSeconds - 0.2, "a hung claude process should block delivery for its full duration; nothing in AgentResumeDeliveryAdapter bounds it")
        switch result {
        case .success:
            break // the fake CLI wakes up and completes normally; no timeout fired because none exists
        case .failure(let error):
            XCTFail("expected the hang to resolve into a normal success once the fake CLI woke up, got \(error)")
        }
    }
}
