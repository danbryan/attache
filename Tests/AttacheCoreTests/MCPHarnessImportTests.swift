import XCTest
@testable import AttacheCore

final class MCPHarnessImportTests: XCTestCase {
    private func data(_ string: String) -> Data { Data(string.utf8) }

    // MARK: Claude Code

    func testParseClaudeStdioAndRemote() {
        let json = """
        {
          "mcpServers": {
            "local-tool": { "command": "npx", "args": ["-y", "server"], "env": { "K": "v" } },
            "remote-static": { "url": "https://api.example/mcp", "headers": { "Authorization": "Bearer t" } },
            "remote-oauth": { "url": "https://oauth.example/mcp" }
          }
        }
        """
        let detected = MCPHarnessImport.parseClaudeConfig(data(json), originPath: "/home/.claude.json")
        XCTAssertEqual(detected.count, 3)

        let local = detected.first { $0.name == "local-tool" }
        XCTAssertEqual(local?.harness, .claudeCode)
        XCTAssertEqual(local?.originPath, "/home/.claude.json")
        XCTAssertEqual(local?.config.command, "npx")
        XCTAssertEqual(local?.config.args, ["-y", "server"])
        XCTAssertEqual(local?.config.env, ["K": "v"])
        XCTAssertEqual(local?.importability, .importable)

        let staticRemote = detected.first { $0.name == "remote-static" }
        XCTAssertEqual(staticRemote?.config.transport, .streamableHTTP)
        XCTAssertEqual(staticRemote?.importability, .importable)

        let oauth = detected.first { $0.name == "remote-oauth" }
        if case .needsAuth = oauth?.importability {} else {
            XCTFail("bare remote should need auth")
        }
    }

    func testParseClaudeMissingMCPServersIsEmpty() {
        XCTAssertTrue(MCPHarnessImport.parseClaudeConfig(data("{}"), originPath: "/x").isEmpty)
        XCTAssertTrue(MCPHarnessImport.parseClaudeConfig(Data(), originPath: "/x").isEmpty)
    }

    func testParseClaudeSkipsInvalidEntries() {
        // Neither command nor url: invalid, so not offered for import.
        let json = """
        { "mcpServers": { "broken": { "args": ["x"] }, "ok": { "command": "run" } } }
        """
        let detected = MCPHarnessImport.parseClaudeConfig(data(json), originPath: "/x")
        XCTAssertEqual(detected.map(\.name), ["ok"])
    }

    // MARK: Codex

    func testParseCodexTables() {
        let toml = """
        [mcp_servers.obsidian]
        command = "mcp-obsidian"
        args = ["--vault", "/vault"]

        [mcp_servers.fantastical]
        command = "node"
        args = ["/path/index.js"]

        [mcp_servers.fantastical.env]
        EXCLUDED = "Work, Personal"

        [mcp_servers.remote]
        url = "https://example.com/mcp"

        [mcp_servers.remote.http_headers]
        Authorization = "Bearer secret"
        """
        let detected = MCPHarnessImport.parseCodexConfig(toml, originPath: "/home/.codex/config.toml")
        XCTAssertEqual(Set(detected.map(\.name)), ["obsidian", "fantastical", "remote"])

        let fantastical = detected.first { $0.name == "fantastical" }
        XCTAssertEqual(fantastical?.harness, .codex)
        XCTAssertEqual(fantastical?.config.command, "node")
        XCTAssertEqual(fantastical?.config.args, ["/path/index.js"])
        XCTAssertEqual(fantastical?.config.env, ["EXCLUDED": "Work, Personal"])
        XCTAssertEqual(fantastical?.importability, .importable)

        let remote = detected.first { $0.name == "remote" }
        XCTAssertEqual(remote?.config.url?.absoluteString, "https://example.com/mcp")
        XCTAssertEqual(remote?.config.headers, ["Authorization": "Bearer secret"])
        XCTAssertEqual(remote?.importability, .importable)
    }

    func testParseCodexRemoteWithoutHeadersNeedsAuth() {
        let toml = """
        [mcp_servers.oauth]
        url = "https://oauth.example/mcp"
        """
        let detected = MCPHarnessImport.parseCodexConfig(toml, originPath: "/x")
        XCTAssertEqual(detected.count, 1)
        if case .needsAuth = detected.first?.importability {} else {
            XCTFail("bare remote should need auth")
        }
    }

    func testParseCodexDisabledFlagPreserved() {
        let toml = """
        [mcp_servers.off]
        url = "https://x.example/mcp"
        enabled = false

        [mcp_servers.off.http_headers]
        Authorization = "Bearer t"
        """
        let detected = MCPHarnessImport.parseCodexConfig(toml, originPath: "/x")
        XCTAssertEqual(detected.first?.config.isEnabled, false)
    }

    func testParseCodexEmptyWhenNoMCPServers() {
        let toml = """
        [cli]
        installer = "internal"
        """
        XCTAssertTrue(MCPHarnessImport.parseCodexConfig(toml, originPath: "/x").isEmpty)
    }

    // MARK: opencode

    func testParseOpencodeLocalAndRemote() {
        let json = """
        {
          "mcp": {
            "local": {
              "type": "local",
              "command": ["bun", "x", "my-mcp"],
              "environment": { "TOKEN": "abc" },
              "enabled": true
            },
            "remote-static": {
              "type": "remote",
              "url": "https://ops.example/mcp",
              "headers": { "Authorization": "Bearer t" },
              "enabled": false
            },
            "remote-oauth": {
              "type": "remote",
              "url": "https://oauth.example/mcp"
            }
          }
        }
        """
        let detected = MCPHarnessImport.parseOpencodeConfig(data(json), originPath: "/home/.config/opencode/opencode.json")
        XCTAssertEqual(Set(detected.map(\.name)), ["local", "remote-static", "remote-oauth"])

        let local = detected.first { $0.name == "local" }
        XCTAssertEqual(local?.harness, .opencode)
        XCTAssertEqual(local?.config.command, "bun")
        XCTAssertEqual(local?.config.args, ["x", "my-mcp"])
        XCTAssertEqual(local?.config.env, ["TOKEN": "abc"])
        XCTAssertEqual(local?.importability, .importable)

        let staticRemote = detected.first { $0.name == "remote-static" }
        XCTAssertEqual(staticRemote?.config.transport, .streamableHTTP)
        XCTAssertEqual(staticRemote?.config.isEnabled, false)
        XCTAssertEqual(staticRemote?.importability, .importable)

        let oauth = detected.first { $0.name == "remote-oauth" }
        if case .needsAuth = oauth?.importability {} else {
            XCTFail("bare remote should need auth")
        }
    }

    func testParseOpencodeMissingMCPIsEmpty() {
        XCTAssertTrue(MCPHarnessImport.parseOpencodeConfig(data(#"{ "model": "x" }"#), originPath: "/x").isEmpty)
    }

    // MARK: classification

    func testClassifyStdioAlwaysImportable() {
        let config = MCPServerConfig(name: "s", transport: .stdio, command: "run")
        XCTAssertEqual(MCPHarnessImport.classify(config), .importable)
    }

    func testClassifyRemoteWithHeaderImportable() {
        let config = MCPServerConfig(
            name: "s", transport: .streamableHTTP,
            url: URL(string: "https://x/mcp"), headers: ["Authorization": "Bearer t"]
        )
        XCTAssertEqual(MCPHarnessImport.classify(config), .importable)
    }

    func testClassifyRemoteWithoutHeaderNeedsAuth() {
        let config = MCPServerConfig(
            name: "s", transport: .streamableHTTP, url: URL(string: "https://x/mcp")
        )
        if case .needsAuth = MCPHarnessImport.classify(config) {} else {
            XCTFail("bare remote should need auth")
        }
    }
}
