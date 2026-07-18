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

    // MARK: Grok Build fixture

    func testParseGrokConfigWithMCPServersProducesGrokGroup() {
        // Grok Build reuses the Codex TOML shape; a config WITH an mcp_servers
        // table must yield entries tagged as the Grok Build harness.
        let toml = """
        [mcp_servers.linear]
        command = "npx"
        args = ["-y", "linear-mcp"]
        """
        let detected = MCPHarnessImport.parseCodexConfig(
            toml, originPath: "/home/.grok/config.toml", harness: .grokBuild
        )
        XCTAssertEqual(detected.map(\.name), ["linear"])
        XCTAssertEqual(detected.first?.harness, .grokBuild)

        let grouping = MCPHarnessImport.group(detected)
        XCTAssertTrue(grouping.shared.isEmpty)
        XCTAssertEqual(grouping.harnessGroups.map(\.harness), [.grokBuild])
        XCTAssertEqual(grouping.harnessGroups.first?.servers.map(\.name), ["linear"])
    }

    // MARK: grouping

    private func stdio(_ name: String, harness: MCPHarness, command: String, args: [String] = []) -> MCPDetectedServer {
        MCPDetectedServer(
            harness: harness, originPath: "/x",
            config: MCPServerConfig(name: name, transport: .stdio, command: command, args: args),
            importability: .importable
        )
    }

    private func remote(_ name: String, harness: MCPHarness, url: String) -> MCPDetectedServer {
        MCPDetectedServer(
            harness: harness, originPath: "/x",
            config: MCPServerConfig(name: name, transport: .streamableHTTP, url: URL(string: url)),
            importability: MCPHarnessImport.classify(
                MCPServerConfig(name: name, transport: .streamableHTTP, url: URL(string: url))
            )
        )
    }

    func testGroupIdenticalInFourHarnessesCollapsesToOneRowWithFourOrigins() {
        let detected = [
            stdio("obsidian", harness: .claudeCode, command: "mcp-obsidian", args: ["--vault", "/v"]),
            stdio("obsidian", harness: .codex, command: "mcp-obsidian", args: ["--vault", "/v"]),
            stdio("obsidian", harness: .opencode, command: "mcp-obsidian", args: ["--vault", "/v"]),
            stdio("obsidian", harness: .grokBuild, command: "mcp-obsidian", args: ["--vault", "/v"]),
        ]
        let grouping = MCPHarnessImport.group(detected)

        XCTAssertEqual(grouping.shared.count, 1)
        let row = grouping.shared.first
        XCTAssertEqual(row?.canonical.name, "obsidian")
        XCTAssertEqual(row?.origins, [.claudeCode, .codex, .opencode, .grokBuild])
        XCTAssertEqual(row?.isImportable, true)
        // Every harness group's rows are lifted into the shared row, so no
        // per-harness group remains.
        XCTAssertTrue(grouping.harnessGroups.isEmpty)
    }

    func testGroupSameNameDifferentURLStaysSeparate() {
        let detected = [
            remote("gateway", harness: .claudeCode, url: "https://a.example/mcp"),
            remote("gateway", harness: .codex, url: "https://b.example/mcp"),
        ]
        let grouping = MCPHarnessImport.group(detected)

        XCTAssertTrue(grouping.shared.isEmpty, "different url is not an exact transport identity match")
        XCTAssertEqual(grouping.harnessGroups.map(\.harness), [.claudeCode, .codex])
        XCTAssertEqual(grouping.harnessGroups.map { $0.servers.count }, [1, 1])
    }

    func testGroupImportAllSkipsSharedEntries() {
        // "obsidian" is shared across two harnesses; each harness also has a
        // unique server. The per-harness groups must exclude the shared entry so
        // Import All on a group cannot double-import it.
        let detected = [
            stdio("obsidian", harness: .claudeCode, command: "mcp-obsidian"),
            stdio("only-claude", harness: .claudeCode, command: "c"),
            stdio("obsidian", harness: .codex, command: "mcp-obsidian"),
            stdio("only-codex", harness: .codex, command: "d"),
        ]
        let grouping = MCPHarnessImport.group(detected)

        XCTAssertEqual(grouping.shared.map(\.canonical.name), ["obsidian"])
        let claude = grouping.harnessGroups.first { $0.harness == .claudeCode }
        let codex = grouping.harnessGroups.first { $0.harness == .codex }
        XCTAssertEqual(claude?.servers.map(\.name), ["only-claude"])
        XCTAssertEqual(codex?.servers.map(\.name), ["only-codex"])
    }

    func testGroupSameHarnessTwiceIsNotShared() {
        // Same identity appearing twice within ONE harness (e.g. Claude global
        // plus a project .mcp.json) is not a cross-harness duplicate.
        let detected = [
            stdio("dup", harness: .claudeCode, command: "x"),
            stdio("dup", harness: .claudeCode, command: "x"),
        ]
        let grouping = MCPHarnessImport.group(detected)
        XCTAssertTrue(grouping.shared.isEmpty)
        XCTAssertEqual(grouping.harnessGroups.map(\.harness), [.claudeCode])
        XCTAssertEqual(grouping.harnessGroups.first?.servers.count, 2)
    }
}
