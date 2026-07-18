import XCTest
@testable import AttacheCore

final class MCPImportMergeTests: XCTestCase {
    private func data(_ string: String) -> Data { Data(string.utf8) }

    private func stdio(_ name: String, command: String, args: [String] = []) -> MCPDetectedServer {
        MCPDetectedServer(
            harness: .codex,
            originPath: "/x",
            config: MCPServerConfig(name: name, transport: .stdio, command: command, args: args),
            importability: .importable
        )
    }

    private func remote(_ name: String, url: String, headers: [String: String] = [:]) -> MCPDetectedServer {
        MCPDetectedServer(
            harness: .claudeCode,
            originPath: "/x",
            config: MCPServerConfig(
                name: name, transport: .streamableHTTP,
                url: URL(string: url), headers: headers
            ),
            importability: headers.isEmpty ? .needsAuth(reason: "x") : .importable
        )
    }

    func testFreshImportIntoEmpty() {
        let (out, map) = MCPConfigEditor.importServers([stdio("alpha", command: "a")], into: Data())
        let parsed = MCPConfigFile.parse(out)
        XCTAssertEqual(parsed.servers.map(\.name), ["alpha"])
        XCTAssertEqual(parsed.servers.first?.command, "a")
        XCTAssertEqual(map, ["alpha": "alpha"])
    }

    func testDuplicateIdenticalTransportIsSkipped() {
        let existing = """
        { "mcpServers": { "alpha": { "command": "a", "args": ["--serve"] } } }
        """
        let (out, map) = MCPConfigEditor.importServers(
            [stdio("alpha", command: "a", args: ["--serve"])],
            into: data(existing)
        )
        let parsed = MCPConfigFile.parse(out)
        // Still exactly one alpha; nothing suffixed.
        XCTAssertEqual(parsed.servers.map(\.name), ["alpha"])
        XCTAssertEqual(map, ["alpha": "alpha"])
    }

    func testNameClashDifferentTransportGetsSuffix() {
        let existing = """
        { "mcpServers": { "alpha": { "command": "original" } } }
        """
        let (out, map) = MCPConfigEditor.importServers(
            [stdio("alpha", command: "different")],
            into: data(existing)
        )
        let parsed = MCPConfigFile.parse(out)
        XCTAssertEqual(Set(parsed.servers.map(\.name)), ["alpha", "alpha-2"])
        XCTAssertEqual(parsed.servers.first { $0.name == "alpha" }?.command, "original")
        XCTAssertEqual(parsed.servers.first { $0.name == "alpha-2" }?.command, "different")
        XCTAssertEqual(map, ["alpha": "alpha-2"])
    }

    func testSuffixIncrementsPastExistingSuffixes() {
        let existing = """
        {
          "mcpServers": {
            "alpha": { "command": "one" },
            "alpha-2": { "command": "two" }
          }
        }
        """
        let (out, map) = MCPConfigEditor.importServers(
            [stdio("alpha", command: "three")],
            into: data(existing)
        )
        let parsed = MCPConfigFile.parse(out)
        XCTAssertTrue(parsed.servers.contains { $0.name == "alpha-3" && $0.command == "three" })
        XCTAssertEqual(map["alpha"], "alpha-3")
    }

    func testPreservesUnrelatedEntriesAndTopLevelKeys() {
        let existing = """
        {
          "someTopLevelKey": { "keep": true },
          "mcpServers": { "keeper": { "url": "https://keep.example/mcp" } }
        }
        """
        let (out, _) = MCPConfigEditor.importServers(
            [stdio("newbie", command: "n")],
            into: data(existing)
        )
        let parsed = MCPConfigFile.parse(out)
        XCTAssertEqual(Set(parsed.servers.map(\.name)), ["keeper", "newbie"])
        // Top-level key survives the round-trip.
        let root = try? JSONSerialization.jsonObject(with: out) as? [String: Any]
        XCTAssertNotNil(root?["someTopLevelKey"])
    }

    func testImportRemoteWithStaticHeaderWritesHeaders() {
        let (out, _) = MCPConfigEditor.importServers(
            [remote("svc", url: "https://svc.example/mcp", headers: ["Authorization": "Bearer t"])],
            into: Data()
        )
        let parsed = MCPConfigFile.parse(out)
        let svc = parsed.servers.first { $0.name == "svc" }
        XCTAssertEqual(svc?.url?.absoluteString, "https://svc.example/mcp")
        XCTAssertEqual(svc?.headers, ["Authorization": "Bearer t"])
        XCTAssertEqual(svc?.transport, .streamableHTTP)
    }

    func testBatchWithInternalNameClashSuffixesSecond() {
        // Two detected servers with the same name but different wiring.
        let a = stdio("dup", command: "a")
        let b = stdio("dup", command: "b")
        let (out, _) = MCPConfigEditor.importServers([a, b], into: Data())
        let parsed = MCPConfigFile.parse(out)
        XCTAssertEqual(Set(parsed.servers.map(\.name)), ["dup", "dup-2"])
    }

    func testDisabledImportedServerKeepsEnabledFalse() {
        let detected = MCPDetectedServer(
            harness: .opencode, originPath: "/x",
            config: MCPServerConfig(
                name: "off", transport: .streamableHTTP,
                url: URL(string: "https://x/mcp"), headers: ["Authorization": "Bearer t"],
                isEnabled: false
            ),
            importability: .importable
        )
        let (out, _) = MCPConfigEditor.importServers([detected], into: Data())
        let parsed = MCPConfigFile.parse(out)
        XCTAssertEqual(parsed.servers.first { $0.name == "off" }?.isEnabled, false)
    }
}
