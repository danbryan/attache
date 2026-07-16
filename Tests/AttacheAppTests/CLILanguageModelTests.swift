import AttacheCore
import Darwin
import XCTest
@testable import AttacheApp

final class CLILanguageModelTests: XCTestCase {
    func testCodexInferenceFailsClosedBeforeExecutableDiscovery() async {
        XCTAssertFalse(CLILanguageModel.supportsSafeToolIsolation(.codex))
        XCTAssertTrue(CLILanguageModel.supportsSafeToolIsolation(.claude))

        do {
            _ = try await CLILanguageModel(tool: .codex, model: "default")
                .complete(prompt: "untrusted prompt")
            XCTFail("Codex inference unexpectedly launched")
        } catch let error as CLILanguageModelError {
            guard case .unsafeToolIsolation(let tool) = error else {
                XCTFail("unexpected error: \(error)")
                return
            }
            XCTAssertEqual(tool, "Codex")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSubprocessEnvironmentDropsAmbientSecrets() {
        let environment = CLILanguageModel.subprocessEnvironment(
            processEnvironment: [
                "PATH": "/custom/bin",
                "LANG": "en_US.UTF-8",
                "CLAUDE_CONFIG_DIR": "/tmp/claude-login",
                "ANTHROPIC_API_KEY": "secret-anthropic",
                "OPENAI_API_KEY": "secret-openai",
                "AWS_SECRET_ACCESS_KEY": "secret-aws"
            ],
            home: "/Users/test",
            extraEnv: ["ATTACHE_EXPLICIT_TEST": "allowed"]
        )

        XCTAssertEqual(environment["HOME"], "/Users/test")
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/tmp/claude-login")
        XCTAssertEqual(environment["ATTACHE_EXPLICIT_TEST"], "allowed")
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
    }

    func testClaudeArgumentsDenyToolsAndUserConfig() {
        let args = CLILanguageModel.claudeArguments(model: "default", reasoningEffort: nil)
        XCTAssertTrue(args.contains("-p"))
        XCTAssertTrue(args.contains("--safe-mode"))
        assertFlag(args, "--output-format", value: "json")
        // The prompt is untrusted transcript text: no tools, no permission prompts.
        assertFlag(args, "--tools", value: "")
        assertFlag(args, "--permission-mode", value: "dontAsk")
        XCTAssertFalse(args.contains("bypassPermissions"))
        XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(args.contains("--allow-dangerously-skip-permissions"))
        // No user config, MCP servers, skills, or persisted session.
        assertFlag(args, "--setting-sources", value: "")
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertTrue(args.contains("--disable-slash-commands"))
        XCTAssertTrue(args.contains("--no-session-persistence"))
        // "default" means don't override the CLI's model.
        XCTAssertFalse(args.contains("--model"))
        XCTAssertFalse(args.contains("--effort"))
    }

    func testClaudeArgumentsKeepSandboxWithModelAndEffort() {
        let args = CLILanguageModel.claudeArguments(model: "claude-sonnet-4-5", reasoningEffort: "High")
        assertFlag(args, "--model", value: "claude-sonnet-4-5")
        assertFlag(args, "--effort", value: "high")
        XCTAssertTrue(args.contains("--safe-mode"))
        assertFlag(args, "--tools", value: "")
        assertFlag(args, "--permission-mode", value: "dontAsk")
        assertFlag(args, "--setting-sources", value: "")
    }

    func testMakeScratchDirectoryIsFreshTempDir() throws {
        let first = try CLILanguageModel.makeScratchDirectory()
        let second = try CLILanguageModel.makeScratchDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: first.path), [])
    }

    func testCodexFailurePrefersStructuredStdoutErrorOverStderrWarning() {
        let stdout = """
        {"type":"thread.started","thread_id":"test"}
        {"type":"error","message":"The selected model is unavailable."}
        """
        let stderr = "WARN codex_core_skills::loader: ignoring interface.icon_large"

        let message = CLILanguageModel.processFailureMessage(
            executable: "/opt/homebrew/bin/codex",
            code: 1,
            stdout: stdout,
            stderr: stderr
        )

        XCTAssertTrue(message.contains("The selected model is unavailable."))
        XCTAssertFalse(message.contains("interface.icon_large"))
    }

    func testCodexFailureFallsBackToStderrWhenStdoutIsEmpty() {
        let message = CLILanguageModel.processFailureMessage(
            executable: "/opt/homebrew/bin/codex",
            code: 1,
            stdout: "",
            stderr: "Authentication required."
        )

        XCTAssertTrue(message.contains("Authentication required."))
    }

    func testCodexFailureUnwrapsNestedJSONMessage() {
        let nested = #"{"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The 'gpt-5.6-luna' model requires a newer version of Codex. Please upgrade and try again."}}"#
        let event = try! JSONSerialization.data(withJSONObject: [
            "type": "error",
            "message": nested
        ])
        let stdout = String(decoding: event, as: UTF8.self)

        let message = CLILanguageModel.processFailureMessage(
            executable: "/opt/homebrew/bin/codex",
            code: 1,
            stdout: stdout,
            stderr: "WARN codex_core_skills::loader: ignored plugin icon"
        )

        XCTAssertEqual(
            message,
            "codex exited with code 1: The 'gpt-5.6-luna' model requires a newer version of Codex. Please upgrade and try again."
        )
        XCTAssertFalse(message.contains(#"{"type""#))
    }

    func testPromptRenderingPreservesStructuredToolCallsAndBoundResults() {
        let call = AttacheChatToolCall(
            id: "call-42",
            name: "read_file",
            arguments: #"{"path":"Sources/App.swift"}"#
        )
        let prompt = CLILanguageModel.renderPrompt(messages: [
            AttacheChatMessage(role: "system", content: "System"),
            AttacheChatMessage(role: "assistant", content: "", toolCalls: [call]),
            AttacheChatMessage(role: "tool", content: "file contents", toolCallID: call.id),
            AttacheChatMessage(role: "user", content: "Continue")
        ])

        XCTAssertTrue(prompt.contains("Assistant tool calls:"))
        XCTAssertTrue(prompt.contains(#""id":"call-42""#))
        XCTAssertTrue(prompt.contains(#""name":"read_file""#))
        XCTAssertTrue(prompt.contains(#"\"path\":\"Sources/App.swift\""#))
        XCTAssertTrue(prompt.contains("Tool result for call-42: file contents"))
        XCTAssertFalse(prompt.contains("User: file contents"))
    }

    func testCancellationTerminatesExactSpawnedProcessPromptly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-cli-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-cli")
        let pidFile = directory.appendingPathComponent("pid")
        let terminatedFile = directory.appendingPathComponent("terminated")
        let script = """
        #!/bin/zsh
        pid_file="$1"
        terminated_file="$2"
        print -r -- "$$" > "$pid_file"
        trap 'print -r -- terminated > "$terminated_file"; exit 0' TERM
        while true; do
          :
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let task = Task {
            try await CLILanguageModel.run(
                executable: executable.path,
                arguments: [pidFile.path, terminatedFile.path],
                stdin: nil,
                extraEnv: [:]
            )
        }

        guard await waitForFile(pidFile, timeout: 2),
              let pidText = try? String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidText) else {
            task.cancel()
            XCTFail("fake CLI did not start")
            return
        }

        let canceledAt = Date()
        task.cancel()
        let terminated = await waitForFile(terminatedFile, timeout: 3)
        let elapsed = Date().timeIntervalSince(canceledAt)

        // Always clean up a failed implementation so this regression test never
        // leaves the fake 90-second CLI alive or makes the suite wait for timeout.
        if !terminated {
            _ = Darwin.kill(pid, SIGKILL)
        }

        let result = await task.result
        guard case .failure(let error) = result else {
            XCTFail("canceled CLI unexpectedly succeeded")
            return
        }
        XCTAssertTrue(error is CancellationError, "unexpected cancellation error: \(error)")
        XCTAssertTrue(terminated, "cancellation did not terminate the spawned process")
        XCTAssertLessThan(elapsed, 3, "cancellation waited for the 90-second process timeout")
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func assertFlag(_ args: [String], _ flag: String, value: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let index = args.firstIndex(of: flag) else {
            XCTFail("missing \(flag)", file: file, line: line)
            return
        }
        guard args.index(after: index) < args.endIndex else {
            XCTFail("\(flag) has no value", file: file, line: line)
            return
        }
        XCTAssertEqual(args[args.index(after: index)], value, "unexpected value for \(flag)", file: file, line: line)
    }
}
