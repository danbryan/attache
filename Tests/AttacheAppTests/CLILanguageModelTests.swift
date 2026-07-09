import XCTest
@testable import AttacheApp

final class CLILanguageModelTests: XCTestCase {
    func testClaudeArgumentsDenyToolsAndUserConfig() {
        let args = CLILanguageModel.claudeArguments(model: "default", reasoningEffort: nil)
        XCTAssertTrue(args.contains("-p"))
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
