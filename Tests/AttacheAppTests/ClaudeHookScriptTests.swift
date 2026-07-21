import XCTest
@testable import AttacheApp

/// The hook script is generated at runtime and shells out to bash + python, so
/// these validate the actual generated content: the shebang lands at column 0,
/// bash accepts it, and the embedded python parses sessions and builds events.
final class ClaudeHookScriptTests: XCTestCase {
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
        let body = ClaudeHookSetup.scriptBody
        XCTAssertTrue(body.hasPrefix("#!/bin/bash\n"), "the shebang must be at column 0 to be honored")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-hook-\(UUID().uuidString).sh")
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (_, status) = try run("/bin/bash", ["-n", tmp.path])
        XCTAssertEqual(status, 0, "bash -n must accept the generated script")
    }

    func testSessionIDPythonPrefersSessionID() throws {
        let (out, status) = try run("/usr/bin/python3", ["-c", ClaudeHookSetup.sessionIDPython],
                                    stdin: #"{"session_id":"abc-123","transcript_path":"/x/y.jsonl"}"#)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "abc-123")
    }

    func testSessionIDPythonFallsBackToTranscriptFilename() throws {
        let (out, _) = try run("/usr/bin/python3", ["-c", ClaudeHookSetup.sessionIDPython],
                               stdin: #"{"transcript_path":"/a/b/sess-9.jsonl"}"#)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "sess-9")
    }

    func testSessionIDPythonEmptyWhenNothingIdentifies() throws {
        let (out, _) = try run("/usr/bin/python3", ["-c", ClaudeHookSetup.sessionIDPython], stdin: "{}")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testBodyPythonEmitsClaudeEvent() throws {
        let (out, status) = try run("/usr/bin/python3",
                                    ["-c", ClaudeHookSetup.bodyPython, "turn_complete", "sess-7", "/tmp/proj"])
        XCTAssertEqual(status, 0)
        let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["event_type"] as? String, "turn_complete")
        XCTAssertEqual(obj?["external_session_id"] as? String, "sess-7")
        XCTAssertEqual(obj?["source"] as? String, "claude_code")
        XCTAssertEqual(obj?["project_path"] as? String, "/tmp/proj")
    }

    // MARK: - Guarded command form (INF-369)
    //
    // Claude Code runs registered hook commands via `/bin/sh -c`, and a stray
    // "No such file or directory" from a missing Attaché script (app-support
    // moved aside by simulate-fresh-user, or the app uninstalled) used to flood
    // every session's Stop/Notification hook output. This proves the guarded
    // command form Attaché now installs is a true silent no-op for a missing
    // script, without touching any real ~/.claude/settings.json: it shells out
    // `/bin/sh -c` directly against the exact command string, pointed at a path
    // that is guaranteed not to exist.

    func testGuardedCommandIsSilentNoOpWhenScriptMissing() throws {
        let missingPath = "/tmp/attache-hook-does-not-exist-\(UUID().uuidString).sh"
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingPath))
        let command = "[ -x '\(missingPath)' ] && '\(missingPath)' turn_complete || true"
        let (out, status) = try run("/bin/sh", ["-c", command])
        XCTAssertEqual(status, 0, "a missing script must never fail the hook")
        XCTAssertEqual(out, "", "a missing script must produce zero output")
    }

    func testGuardedCommandStillRunsScriptWhenPresent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-hook-present-\(UUID().uuidString).sh")
        try "#!/bin/sh\necho ran\n".write(to: tmp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let command = "[ -x '\(tmp.path)' ] && '\(tmp.path)' turn_complete || true"
        let (out, status) = try run("/bin/sh", ["-c", command])
        XCTAssertEqual(status, 0)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "ran",
                       "the guard must not prevent the real script from running when present")
    }

    // MARK: - No-op safety when Attaché is not running (INF)
    //
    // The installed hook must be a silent, fast no-op when the Attaché app is
    // not listening: it must never emit user-visible output or a delay into the
    // host Claude turn. This runs the ACTUAL generated script against a
    // throwaway HOME (so the real token/app-support is never read) and a dead
    // event port, and asserts exit 0, zero stdout, and completion well inside
    // the script's own 2s curl cap.

    /// Runs an executable with `HOME`/`ATTACHE_EVENT_PORT` overridden, returning
    /// output, exit status, and wall-clock duration.
    private func runScript(
        _ path: String, stdin: String, home: URL, port: String
    ) throws -> (out: String, status: Int32, seconds: Double) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["ATTACHE_EVENT_PORT"] = port
        process.environment = env
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        let inPipe = Pipe()
        process.standardInput = inPipe
        let start = Date()
        try process.run()
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try? inPipe.fileHandleForWriting.close()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus, Date().timeIntervalSince(start))
    }

    func testGeneratedHookIsSilentFastNoOpWhenAttacheNotRunning() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-hook-home-\(UUID().uuidString)")
        // Token present, so the script proceeds to the POST and hits the dead
        // port (the "app installed the hook but is not running" case).
        let tokenDir = home.appendingPathComponent("Library/Application Support/Attache")
        try FileManager.default.createDirectory(at: tokenDir, withIntermediateDirectories: true)
        try "not-a-real-token".write(to: tokenDir.appendingPathComponent("event-token"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }

        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-hook-\(UUID().uuidString).sh")
        try ClaudeHookSetup.scriptBody.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let (out, status, seconds) = try runScript(
            script.path, stdin: #"{"session_id":"abc","cwd":"/tmp"}"#, home: home, port: "59991")
        XCTAssertEqual(status, 0, "the hook must never fail the Claude turn when Attaché is down")
        XCTAssertEqual(out, "", "the hook must be silent when Attaché is down")
        // The hang this guards against is curl waiting out a 30-60s default
        // timeout; the script's curl is capped at 2s. Wall clock also carries
        // python interpreter cold-start, which measured 9s under a fully
        // loaded parallel suite (2026-07-21), so the bound is sized for load
        // while still failing on any real timeout hang.
        XCTAssertLessThan(seconds, 15.0, "the hook must return fast (its curl is capped at 2s)")
    }

    func testInstalledEntriesUseGuardedForm() {
        // ClaudeHookSetup.entries is what actually ships; assert every managed
        // event's command carries the missing-script guard, not the bare form.
        for entry in ClaudeHookSetup.entries {
            XCTAssertTrue(entry.command.hasPrefix("[ -x '"), "\(entry.event) command must be guarded: \(entry.command)")
            XCTAssertTrue(entry.command.hasSuffix("|| true"), "\(entry.event) command must fall through silently: \(entry.command)")
        }
    }
}
