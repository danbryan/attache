import AttacheCore
import XCTest
@testable import AttacheApp

final class MCPClientStdioTests: XCTestCase {
    func testStdioClientInitializesListsAndCallsEcho() async throws {
        guard let config = MCPTestSupport.mockServerConfig() else {
            throw XCTSkip("python3 not available")
        }
        let client = try MCPClient(config: config)
        defer { Task { await client.close() } }

        let tools = try await client.connect()
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.toolName, $0) })
        XCTAssertEqual(Set(byName.keys), Set(["echo", "write_note"]))

        // readOnlyHint true -> read-only; absent annotation -> NOT read-only.
        XCTAssertEqual(byName["echo"]?.isReadOnly, true)
        XCTAssertEqual(byName["write_note"]?.isReadOnly, false)
        XCTAssertEqual(byName["echo"]?.namespacedName, "mcp__mock__echo")
        XCTAssertFalse(byName["echo"]?.schemaJSON.isEmpty ?? true)

        let echoed = try await client.callTool(name: "echo", argumentsJSON: #"{"text":"hello mcp"}"#)
        XCTAssertEqual(echoed, "hello mcp")
    }

    func testStdioClientWriteNoteAppendsToFile() async throws {
        let noteFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-note-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: noteFile) }
        guard let config = MCPTestSupport.mockServerConfig(noteFile: noteFile) else {
            throw XCTSkip("python3 not available")
        }
        let client = try MCPClient(config: config)
        defer { Task { await client.close() } }

        _ = try await client.connect()
        let result = try await client.callTool(name: "write_note", argumentsJSON: #"{"text":"remember this"}"#)
        XCTAssertEqual(result, "noted")

        let contents = try String(contentsOf: noteFile, encoding: .utf8)
        XCTAssertTrue(contents.contains("remember this"))
    }
}
