import XCTest
@testable import AttacheCore

/// INF-361: Grok Build sessions live at
/// ~/.grok/sessions/<percent-encoded-project-path>/<session-uuid>/chat_history.jsonl,
/// verified against real sessions on this Mac. These tests build that layout
/// directly (rather than shelling out to scripts/create-fake-grok-home.py) so
/// they run fast and don't depend on Python being on PATH.
final class GrokBuildSessionScannerTests: XCTestCase {
    private func makeGrokHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-grok-scanner-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func writeSession(
        sessionsRoot: URL,
        encodedProject: String,
        sessionID: String,
        chatHistoryLines: [[String: Any]],
        planHeading: String? = nil
    ) throws {
        let sessionDir = sessionsRoot.appendingPathComponent(encodedProject, isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let lines = chatHistoryLines.map { line -> String in
            let data = try! JSONSerialization.data(withJSONObject: line)
            return String(data: data, encoding: .utf8)!
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: sessionDir.appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8
        )
        if let planHeading {
            try "# \(planHeading)\n\nSteps.\n".write(
                to: sessionDir.appendingPathComponent("plan.md"), atomically: true, encoding: .utf8
            )
        }
    }

    func testScannerDiscoversSessionsAndTitlesFromFirstUserPrompt() throws {
        let home = makeGrokHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionsRoot = home.appendingPathComponent("sessions", isDirectory: true)

        try writeSession(
            sessionsRoot: sessionsRoot,
            encodedProject: "%2FUsers%2Ftester%2Fproject",
            sessionID: "00000000-0000-0000-0000-000000000001",
            chatHistoryLines: [
                ["type": "system", "content": "You are Grok Build."],
                ["type": "user", "content": [["type": "text", "text": "Fix the flaky test"]]],
                ["type": "assistant", "content": "On it.", "tool_calls": NSNull()]
            ]
        )

        let scanner = GrokBuildSessionScanner(grokHome: home)
        scanner.beginScan()
        let files = scanner.enumerateFiles()
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.id, "00000000-0000-0000-0000-000000000001")

        let record = scanner.makeRecord(for: files[0], priorTopicTag: nil, contentCap: 4_000)
        XCTAssertEqual(record.title, "Fix the flaky test")
        XCTAssertEqual(record.project, "/Users/tester/project")
        XCTAssertEqual(record.sourceKind, .grokBuild)
    }

    func testScannerPrefersPlanMdHeadingOverFirstUserPrompt() throws {
        let home = makeGrokHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionsRoot = home.appendingPathComponent("sessions", isDirectory: true)

        try writeSession(
            sessionsRoot: sessionsRoot,
            encodedProject: "%2FUsers%2Ftester%2Fproject",
            sessionID: "00000000-0000-0000-0000-000000000002",
            chatHistoryLines: [
                ["type": "user", "content": [["type": "text", "text": "some raw prompt"]]]
            ],
            planHeading: "Ship the release"
        )

        let scanner = GrokBuildSessionScanner(grokHome: home)
        scanner.beginScan()
        let files = scanner.enumerateFiles()
        let record = scanner.makeRecord(for: files[0], priorTopicTag: nil, contentCap: 4_000)
        XCTAssertEqual(record.title, "Ship the release")
    }

    /// INF-361 acceptance: percent-decoding of project paths, including
    /// spaces and non-ASCII.
    func testDecodedProjectHandlesSpacesAndNonASCII() throws {
        let home = makeGrokHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionsRoot = home.appendingPathComponent("sessions", isDirectory: true)
        let encodedProject = "%2FUsers%2Ftester%2FGrok%20Projects%2Fcaf%C3%A9-app"

        try writeSession(
            sessionsRoot: sessionsRoot,
            encodedProject: encodedProject,
            sessionID: "00000000-0000-0000-0000-000000000003",
            chatHistoryLines: [
                ["type": "user", "content": [["type": "text", "text": "hello"]]]
            ]
        )

        let scanner = GrokBuildSessionScanner(grokHome: home)
        scanner.beginScan()
        let files = scanner.enumerateFiles()
        let record = scanner.makeRecord(for: files[0], priorTopicTag: nil, contentCap: 4_000)
        XCTAssertEqual(record.project, "/Users/tester/Grok Projects/café-app")
    }

    func testEnumerateFilesSkipsSessionDirectoriesMissingChatHistory() throws {
        let home = makeGrokHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionsRoot = home.appendingPathComponent("sessions", isDirectory: true)
        let emptySessionDir = sessionsRoot
            .appendingPathComponent("%2FUsers%2Ftester%2Fproject", isDirectory: true)
            .appendingPathComponent("00000000-0000-0000-0000-000000000099", isDirectory: true)
        try FileManager.default.createDirectory(at: emptySessionDir, withIntermediateDirectories: true)

        let scanner = GrokBuildSessionScanner(grokHome: home)
        scanner.beginScan()
        XCTAssertTrue(scanner.enumerateFiles().isEmpty)
    }
}
