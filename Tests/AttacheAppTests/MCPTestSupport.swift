import AttacheCore
import Foundation
import XCTest

/// Shared helpers for the MCP client/registry tests. The mock server needs
/// python3; tests skip gracefully when it is absent.
enum MCPTestSupport {
    /// The first python3 interpreter found, or nil if none is available.
    static func pythonExecutable() -> String? {
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Absolute path to `scripts/mock-mcp-server.py`, resolved from this source
    /// file's location so it works regardless of the working directory.
    static func mockServerScriptPath(file: StaticString = #filePath) -> String {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent() // AttacheAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
            .appendingPathComponent("scripts/mock-mcp-server.py")
            .path
    }

    /// A stdio server config that launches the mock server, or nil to skip.
    static func mockServerConfig(name: String = "mock", noteFile: URL? = nil) -> MCPServerConfig? {
        guard let python = pythonExecutable() else { return nil }
        var env: [String: String] = [:]
        if let noteFile { env["MOCK_MCP_NOTE_FILE"] = noteFile.path }
        return MCPServerConfig(
            name: name,
            transport: .stdio,
            command: python,
            args: [mockServerScriptPath()],
            env: env
        )
    }
}
