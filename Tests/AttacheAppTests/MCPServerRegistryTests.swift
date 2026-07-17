import AttacheCore
import XCTest
@testable import AttacheApp

final class MCPServerRegistryTests: XCTestCase {
    private func writeConfig(_ json: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-\(UUID().uuidString).json")
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: url)
        return url
    }

    @MainActor
    private func makeRegistry(configURL: URL) -> MCPServerRegistry {
        MCPServerRegistry(configURL: configURL, watchesFile: false)
    }

    func testRegistryParsesConfigAndSurfacesStatuses() async throws {
        let url = try writeConfig([
            "mcpServers": [
                "good": ["command": "run"],
                "off": ["command": "run", "enabled": false],
                "bad": ["args": ["x"]]
            ]
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let registry = await makeRegistry(configURL: url)
        let (statuses, errors, configured) = await MainActor.run {
            (registry.statuses, registry.validationErrors, registry.configuredServers)
        }
        XCTAssertEqual(configured.count, 3)
        XCTAssertEqual(statuses["good"], .idle)
        XCTAssertEqual(statuses["off"], .disabled)
        XCTAssertEqual(statuses["bad"], .disabled)
        XCTAssertNotNil(errors["bad"])
    }

    func testRegistryConnectsLazilyAndExposesNamespacedDescriptors() async throws {
        guard let python = MCPTestSupport.pythonExecutable() else {
            throw XCTSkip("python3 not available")
        }
        let url = try writeConfig([
            "mcpServers": [
                "mock": ["command": python, "args": [MCPTestSupport.mockServerScriptPath()]]
            ]
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let registry = await makeRegistry(configURL: url)

        // Not connected until a tool schema is needed.
        let before = await MainActor.run { registry.availableTools() }
        XCTAssertTrue(before.isEmpty)

        await registry.prepareTools(forNamespacedNames: ["mcp__mock__echo"])

        let tools = await MainActor.run { registry.availableTools() }
        XCTAssertEqual(Set(tools.map(\.namespacedName)), Set(["mcp__mock__echo", "mcp__mock__write_note"]))
        let status = await MainActor.run { registry.statuses["mock"] }
        XCTAssertEqual(status, .connected(toolCount: 2))

        let result = try await registry.callTool(
            namespacedName: "mcp__mock__echo",
            argumentsJSON: #"{"text":"registry works"}"#
        )
        XCTAssertEqual(result, "registry works")
    }

    func testTruncationAddsTrailingNote() {
        let long = String(repeating: "x", count: MCPServerRegistry.maxResultCharacters + 500)
        let truncated = MCPServerRegistry.truncate(long)
        XCTAssertLessThan(truncated.count, long.count)
        XCTAssertTrue(truncated.contains("truncated by Attaché"))
        XCTAssertEqual(MCPServerRegistry.truncate("short"), "short")
    }

    // MARK: Offered-schema filtering (pure, no live model)

    func testOfferedToolObjectsRespectGrantsAndPrivateClamp() {
        let readOnly = MCPToolDescriptor(
            serverName: "mock", toolName: "echo", description: "d",
            schemaJSON: #"{"type":"object","properties":{"text":{"type":"string"}}}"#,
            isReadOnly: true
        )
        let effectful = MCPToolDescriptor(
            serverName: "mock", toolName: "write_note", description: "d",
            schemaJSON: "", isReadOnly: false
        )
        let grants: MCPToolGrants = [
            readOnly.namespacedName: .alwaysAllow,
            effectful.namespacedName: .askFirst
        ]

        let normal = MCPToolPolicy.offeredTools(available: [readOnly, effectful], grants: grants, isPrivateCall: false)
        let normalObjects = MCPToolOffering.toolObjects(descriptors: normal)
        let normalNames = normalObjects.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(Set(normalNames), Set(["mcp__mock__echo", "mcp__mock__write_note"]))

        // A tool object embeds the tool's JSON schema as its parameters.
        if let echoObject = normalObjects.first(where: {
            (($0["function"] as? [String: Any])?["name"] as? String) == "mcp__mock__echo"
        }) {
            let params = (echoObject["function"] as? [String: Any])?["parameters"] as? [String: Any]
            XCTAssertEqual(params?["type"] as? String, "object")
        } else {
            XCTFail("expected echo tool object")
        }

        // Private call drops the effectful tool entirely.
        let priv = MCPToolPolicy.offeredTools(available: [readOnly, effectful], grants: grants, isPrivateCall: true)
        XCTAssertEqual(priv.map(\.namespacedName), ["mcp__mock__echo"])
    }
}
