import XCTest
@testable import AttacheApp

/// The Codex notify program is generated at runtime and shells out to bash +
/// python, so these validate the actual generated content: the shebang lands at
/// column 0, bash accepts it, the payload-mapping python turns a real Codex
/// notify payload into the compact event Attaché ingests, and the chain python
/// reconstructs the previous notify argv.
final class CodexNotifyScriptTests: XCTestCase {
    private func run(_ launchPath: String, _ args: [String], stdin: String? = nil) throws -> (out: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            try process.run()
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }

    func testScriptShebangAndBashSyntax() throws {
        let body = CodexNotifySetup.scriptBody
        XCTAssertTrue(body.hasPrefix("#!/bin/bash\n"), "the shebang must be at column 0 to be honored")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-codex-notify-\(UUID().uuidString).sh")
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (_, status) = try run("/bin/bash", ["-n", tmp.path])
        XCTAssertEqual(status, 0, "bash -n must accept the generated script")
    }

    // MARK: Payload -> event mapping

    func testBodyPythonMapsAgentTurnComplete() throws {
        let payload = #"{"type":"agent-turn-complete","thread-id":"019F765A-3D95-7C20-8497-E100AD479DC9","cwd":"/Users/x/proj","last-assistant-message":"Done."}"#
        let (out, status) = try run("/usr/bin/python3", ["-c", CodexNotifySetup.bodyPython, payload])
        XCTAssertEqual(status, 0)
        let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["source"] as? String, "codex")
        XCTAssertEqual(obj?["event_type"] as? String, "turn_complete")
        // The thread id is lowercased to match how Attaché keys Codex sessions.
        XCTAssertEqual(obj?["external_session_id"] as? String, "019f765a-3d95-7c20-8497-e100ad479dc9")
        XCTAssertEqual(obj?["project_path"] as? String, "/Users/x/proj")
        // Non-empty text is required by the event server; the message survives.
        XCTAssertEqual(obj?["text"] as? String, "Done.")
        XCTAssertEqual((obj?["metadata"] as? [String: Any])?["adapter"] as? String, "codex-notify")
    }

    func testBodyPythonFallsBackToPlaceholderTextWhenNoMessage() throws {
        let payload = #"{"type":"agent-turn-complete","thread-id":"abc","cwd":"/p"}"#
        let (out, _) = try run("/usr/bin/python3", ["-c", CodexNotifySetup.bodyPython, payload])
        let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        // Never empty: the server rejects empty text, and turn_complete makes no card.
        XCTAssertEqual(obj?["text"] as? String, "Codex finished a turn.")
    }

    func testBodyPythonEmitsNothingForOtherEventTypes() throws {
        let payload = #"{"type":"agent-turn-started","thread-id":"abc"}"#
        let (out, status) = try run("/usr/bin/python3", ["-c", CodexNotifySetup.bodyPython, payload])
        XCTAssertEqual(status, 0)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "",
                       "only agent-turn-complete maps to a status event")
    }

    func testBodyPythonEmitsNothingWithoutThreadID() throws {
        let payload = #"{"type":"agent-turn-complete"}"#
        let (out, _) = try run("/usr/bin/python3", ["-c", CodexNotifySetup.bodyPython, payload])
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    // MARK: - No-op safety when Attaché is not running (INF)
    //
    // Codex execs the notify program on every turn; it must be a silent, fast
    // no-op when Attaché is not listening, never delaying or disturbing Codex.
    // This runs the ACTUAL generated program against a throwaway HOME and a dead
    // event port and asserts exit 0, zero stdout, and completion inside its 2s
    // curl cap.

    private func runProgram(
        _ path: String, args: [String], home: URL, port: String
    ) throws -> (out: String, status: Int32, seconds: Double) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["ATTACHE_EVENT_PORT"] = port
        process.environment = env
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        let start = Date()
        try process.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus, Date().timeIntervalSince(start))
    }

    func testGeneratedNotifyIsSilentFastNoOpWhenAttacheNotRunning() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-codex-home-\(UUID().uuidString)")
        let tokenDir = home.appendingPathComponent("Library/Application Support/Attache")
        try FileManager.default.createDirectory(at: tokenDir, withIntermediateDirectories: true)
        try "not-a-real-token".write(to: tokenDir.appendingPathComponent("event-token"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }

        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-codex-notify-\(UUID().uuidString).sh")
        try CodexNotifySetup.scriptBody.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        // A real agent-turn-complete payload as the final argument, no chained
        // previous program.
        let payload = #"{"type":"agent-turn-complete","thread-id":"abc","cwd":"/tmp","last-assistant-message":"Done."}"#
        let (out, status, seconds) = try runProgram(
            script.path, args: [payload], home: home, port: "59992")
        XCTAssertEqual(status, 0, "the notify program must never fail Codex when Attaché is down")
        XCTAssertEqual(out, "", "the notify program must be silent when Attaché is down")
        // Bound sized for parallel-suite load like the Claude hook test
        // (interpreter cold-start under load); a real curl timeout hang
        // still fails it.
        XCTAssertLessThan(seconds, 15.0, "the notify program must return fast (its curl is capped at 2s)")
    }

    // MARK: Chaining reconstructs the previous notify argv

    func testChainPythonAppendsPayloadToPreviousArgv() throws {
        // Instead of exec-ing, verify the argv the chain python would run by
        // pointing it at /bin/echo as the previous program.
        let prev = #"["/bin/echo","turn-ended","--previous-notify","[\"/usr/bin/true\",\"turn-ended\"]"]"#
        let payload = #"{"type":"agent-turn-complete","thread-id":"abc"}"#
        let (out, status) = try run("/usr/bin/python3", ["-c", CodexNotifySetup.chainPython, prev, payload])
        XCTAssertEqual(status, 0)
        // /bin/echo prints its args (minus argv0): the original args then the payload.
        let printed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(printed.hasPrefix("turn-ended --previous-notify"), "original args must be preserved: \(printed)")
        XCTAssertTrue(printed.hasSuffix(payload), "the original payload must be appended last: \(printed)")
    }
}
