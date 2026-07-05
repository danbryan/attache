import XCTest
@testable import AttacheCore

final class CompanionSessionTranscriptTests: XCTestCase {
    private func tempFile(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-transcript-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func claudeUser(_ text: String) -> String {
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"\(text)\"}}"
    }
    private func claudeAssistant(_ text: String) -> String {
        "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}]}}"
    }

    func testSmallSessionRendersAllTurnsWithIndices() throws {
        let url = try tempFile([
            claudeUser("let us decide the schema"),
            claudeAssistant("proposing schema v1"),
            claudeUser("ship it")
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let text = CompanionSessionReader.transcript(fromFileURL: url)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("TURN 1/3 - USER: let us decide the schema"))
        XCTAssertTrue(text!.contains("proposing schema v1"))
        XCTAssertFalse(text!.contains("omitted"), "a small session is rendered whole")
    }

    func testTranscriptPageReturnsRequestedTurnsWithIndices() throws {
        var lines: [String] = []
        for i in 1...50 { lines.append(claudeUser("user turn \(i)")); lines.append(claudeAssistant("assistant turn \(i)")) }
        let url = try tempFile(lines)   // 100 turns
        defer { try? FileManager.default.removeItem(at: url) }

        let page = CompanionSessionReader.transcriptPage(fromFileURL: url, startTurn: 41, maxChars: 200)
        XCTAssertNotNil(page)
        XCTAssertTrue(page!.contains("TURN 41/100"))
        XCTAssertTrue(page!.contains("of 100") || page!.contains("/100"))
        // The window is bounded; it should offer to continue.
        XCTAssertTrue(page!.contains("start_turn"))
    }

    func testTranscriptPageBeyondEndExplains() throws {
        let url = try tempFile([claudeUser("only turn")])
        defer { try? FileManager.default.removeItem(at: url) }
        let page = CompanionSessionReader.transcriptPage(fromFileURL: url, startTurn: 99)
        XCTAssertNotNil(page)
        XCTAssertTrue(page!.contains("1 turns") || page!.contains("no turn 99"))
    }

    func testSearchFindsMatchingTurnByNumber() throws {
        var lines: [String] = []
        for i in 1...100 { lines.append(claudeAssistant("routine turn \(i)")) }
        lines.insert(claudeUser("the DISTINCTIVE_TOKEN decision was made here"), at: 60)  // becomes turn 61
        let url = try tempFile(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = CompanionSessionReader.searchTranscript(fromFileURL: url, query: "DISTINCTIVE_TOKEN")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("DISTINCTIVE_TOKEN"))
        XCTAssertTrue(result!.contains("TURN 61"))
    }

    func testSearchNoMatchGuidance() throws {
        let url = try tempFile([claudeUser("nothing relevant here")])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = CompanionSessionReader.searchTranscript(fromFileURL: url, query: "absent")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("No turns matched"))
    }

    func testLargeSessionKeepsOpeningAndRecentTurnsWithGap() throws {
        // The distinctive first decision must survive even when the session is far
        // larger than the whole-read cap (the "what did we decide at the start?" ask).
        var lines: [String] = [
            claudeUser("FIRST_DECISION use topolvm-ssd-xfs storage"),
            claudeAssistant("acknowledged the storage decision")
        ]
        // Pad the middle past the 512KB whole-read cap.
        let filler = String(repeating: "x", count: 400)
        for i in 0..<3000 {
            lines.append(claudeAssistant("middle turn \(i) \(filler)"))
        }
        lines.append(claudeUser("LAST_QUESTION what did we decide about storage"))
        let url = try tempFile(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size ?? 0, 512 * 1024, "fixture must exceed the whole-read cap")

        let text = CompanionSessionReader.transcript(fromFileURL: url)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("FIRST_DECISION"), "opening context must be present")
        XCTAssertTrue(text!.contains("LAST_QUESTION"), "recent context must be present")
        XCTAssertTrue(text!.contains("omitted"), "the gap must be marked so the model knows the middle is missing")
    }
}
