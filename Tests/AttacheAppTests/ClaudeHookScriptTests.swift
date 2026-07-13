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
}
