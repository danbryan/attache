import AttacheCore
import XCTest

final class CompanionSessionReaderTests: XCTestCase {
    func testParsesUserAndAssistantTurnsInOrder() {
        let jsonl = """
        {"type":"session_meta","payload":{"cwd":"/work"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"check the build"}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"text":"The build passed."}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"output_text":"Two warnings remain."}]}}
        """

        let turns = CompanionSessionReader.parseTurns(fromJSONL: jsonl)

        XCTAssertEqual(turns, [
            .init(role: "user", text: "check the build"),
            .init(role: "assistant", text: "The build passed."),
            .init(role: "assistant", text: "Two warnings remain.")
        ])
    }

    func testParsesClaudeCodeTurns() {
        // Claude Code: user content is a string, assistant content is a block list;
        // thinking and tool_use blocks are not part of the readable transcript.
        let jsonl = """
        {"type":"user","cwd":"/work","message":{"role":"user","content":"check the build"}}
        {"type":"assistant","cwd":"/work","message":{"role":"assistant","content":[{"type":"thinking","thinking":"let me look"},{"type":"text","text":"The build passed."}]}}
        {"type":"assistant","cwd":"/work","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"}]}}
        """

        let turns = CompanionSessionReader.parseTurns(fromJSONL: jsonl)

        XCTAssertEqual(turns, [
            .init(role: "user", text: "check the build"),
            .init(role: "assistant", text: "The build passed.")
        ])
    }

    func testIgnoresNonMessageAndEmptyContent() {
        let jsonl = """
        {"type":"turn_context","payload":{"cwd":"/work"}}
        {"type":"response_item","payload":{"type":"function_call","role":"assistant","content":[{"text":"ignored"}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"text":"   "}]}}
        {"type":"response_item","payload":{"type":"message","role":"system","content":[{"text":"system note"}]}}
        not-json
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"only real turn"}]}}
        """

        let turns = CompanionSessionReader.parseTurns(fromJSONL: jsonl)

        XCTAssertEqual(turns, [.init(role: "user", text: "only real turn")])
    }

    // MARK: - readFile containment

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-reader-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testReadFileReadsRelativePathInsideRoot() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "hello from inside".write(to: nested.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            CompanionSessionReader.readFile(path: "docs/notes.txt", within: root.path),
            "hello from inside"
        )
    }

    func testReadFileWorksWhenRootIsUnderSymlinkedTmp() throws {
        // /tmp is a symlink to /private/tmp on macOS; a root given via /tmp must
        // still allow normal relative reads.
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("attache-reader-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "tmp root works".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            CompanionSessionReader.readFile(path: "notes.txt", within: root.path),
            "tmp root works"
        )
    }

    func testReadFileRefusesSymlinkEscape() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "top secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: outside
        )

        XCTAssertNil(CompanionSessionReader.readFile(path: "link/secret.txt", within: root.path))
    }

    func testReadFileRefusesSymlinkedIntermediateDirEscape() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "escaped".write(to: base.appendingPathComponent("escape.txt"), atomically: true, encoding: .utf8)
        // Decoy at the lexical resolution of the request; a correct physical
        // resolution must not land here either.
        try "decoy".write(to: root.appendingPathComponent("sub/escape.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: sub.appendingPathComponent("link"),
            withDestinationURL: outside
        )

        XCTAssertNil(CompanionSessionReader.readFile(path: "sub/link/../escape.txt", within: root.path))
    }

    func testReadFileRefusesHomeSymlinkEscape() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("homelink"),
            withDestinationURL: FileManager.default.homeDirectoryForCurrentUser
        )

        XCTAssertNil(CompanionSessionReader.readFile(path: "homelink/.ssh/config", within: root.path))
    }

    func testReadFileRefusesAbsolutePathOutsideRoot() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(CompanionSessionReader.readFile(path: "/etc/hosts", within: root.path))
    }

    func testReadFileRefusesParentTraversal() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "outside root".write(to: base.appendingPathComponent("sibling.txt"), atomically: true, encoding: .utf8)

        XCTAssertNil(CompanionSessionReader.readFile(path: "../sibling.txt", within: root.path))
    }

    func testReadFileRefusesSiblingWithSharedPrefix() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("dir", isDirectory: true)
        let sibling = base.appendingPathComponent("dir-other", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let file = sibling.appendingPathComponent("file.txt")
        try "sibling data".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertNil(CompanionSessionReader.readFile(path: file.path, within: root.path))
    }

    func testReadFileRefusesOversizedFile() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = root.appendingPathComponent("big.txt")
        try Data(count: 5_000_001).write(to: big)

        XCTAssertNil(CompanionSessionReader.readFile(path: "big.txt", within: root.path))
    }
}
