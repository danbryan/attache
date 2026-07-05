import XCTest
@testable import AttacheCore

final class SessionTitleTests: XCTestCase {
    func testCommandMarkupBecomesCommandPlusArgs() {
        let raw = "<command-name>/goal</command-name> <command-message>goal</command-message> <command-args>Work Linear ticket INF-174 (Umbrella: execute Attaché Launch Readiness)</command-args>"
        let title = SessionDigest.title(from: raw)
        XCTAssertTrue(title.hasPrefix("/goal Work Linear ticket INF-174"), title)
        XCTAssertFalse(title.contains("<command"))
    }

    func testCommandMarkupWithoutArgsShowsCommandOnly() {
        let raw = "<command-name>/model</command-name><command-message>model</command-message>"
        XCTAssertEqual(SessionDigest.title(from: raw), "/model")
    }

    func testPlainTextPassesThrough() {
        XCTAssertEqual(SessionDigest.title(from: "Fix the login bug"), "Fix the login bug")
    }

    func testUnknownMarkupIsStrippedNotShown() {
        let raw = "<command-name></command-name><local-command-stdout>ok</local-command-stdout>"
        let title = SessionDigest.title(from: raw)
        XCTAssertFalse(title.contains("<"))
    }

    func testStrippedTranscriptMarkupKeepsSurroundingProse() {
        let raw = "before <command-name>/goal</command-name> <command-message>goal</command-message> <command-args>ship INF-174</command-args> after"
        XCTAssertEqual(SessionDigest.strippedTranscriptMarkup(raw),
                       "before /goal goal ship INF-174 after")
    }

    func testStrippedTranscriptMarkupLeavesCodeTagsAlone() {
        let raw = "renders a <div> inside Vec<T> unchanged"
        XCTAssertEqual(SessionDigest.strippedTranscriptMarkup(raw), raw)
    }

    func testSnippetNeverShowsHalfTags() {
        let padding = String(repeating: "x", count: 200)
        let content = padding + " <command-name>/goal</command-name> <command-message>goal</command-message> <command-args>work on inf-174 launch</command-args> " + padding
        let snippet = SessionSearchRanker.makeSnippet(content, terms: ["inf-174"])
        XCTAssertNotNil(snippet)
        XCTAssertFalse(snippet?.contains("command-") ?? true, snippet ?? "")
        XCTAssertTrue(snippet?.contains("inf-174") ?? false, snippet ?? "")
    }

    func testDesktopTitleIndexLoads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("desktop-titles-\(UUID().uuidString)/ws/win", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let record = ["cliSessionId": "abc-123", "title": "Attaché Launch Readiness INF-174"]
        let data = try JSONSerialization.data(withJSONObject: record)
        try data.write(to: root.appendingPathComponent("local_x.json"))
        let titles = ClaudeDesktopSessionTitles.load(root: root.deletingLastPathComponent().deletingLastPathComponent())
        XCTAssertEqual(titles["abc-123"], "Attaché Launch Readiness INF-174")
    }

    func testMissingDesktopStoreYieldsEmpty() {
        let titles = ClaudeDesktopSessionTitles.load(
            root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        XCTAssertTrue(titles.isEmpty)
    }
}
