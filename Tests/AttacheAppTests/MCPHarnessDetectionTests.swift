import AttacheCore
import XCTest
@testable import AttacheApp

final class MCPHarnessDetectionTests: XCTestCase {
    private func writeConfig(_ json: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-detect-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }

    private func stdio(_ name: String, harness: MCPHarness, command: String) -> MCPDetectedServer {
        MCPDetectedServer(
            harness: harness, originPath: "/x",
            config: MCPServerConfig(name: name, transport: .stdio, command: command),
            importability: .importable
        )
    }

    @MainActor
    private func makeRegistry(configURL: URL) -> MCPServerRegistry {
        MCPServerRegistry(configURL: configURL, watchesFile: false)
    }

    private func waitForDetection(_ registry: MCPServerRegistry) async -> [MCPDetectedServer] {
        for _ in 0..<50 {
            let (detecting, servers) = await MainActor.run { (registry.isDetecting, registry.detectedServers) }
            if !detecting && !servers.isEmpty { return servers }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await MainActor.run { registry.detectedServers }
    }

    func testDetectionPublishesCandidates() async throws {
        let url = try writeConfig(["mcpServers": [:]])
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = await makeRegistry(configURL: url)
        let candidates = [stdio("alpha", harness: .codex, command: "a"),
                          stdio("beta", harness: .claudeCode, command: "b")]
        registry.detectHarnessServers = { candidates }
        await MainActor.run { registry.refreshDetection() }
        let detected = await waitForDetection(registry)
        XCTAssertEqual(Set(detected.map(\.name)), ["alpha", "beta"])
    }

    func testAlreadyConfiguredCandidatesAreFilteredByConnectionIdentity() async throws {
        // "alpha" is already configured with identical wiring, so it must not
        // appear in the detected list; "beta" is new and should.
        let url = try writeConfig(["mcpServers": ["alpha": ["command": "a"]]])
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = await makeRegistry(configURL: url)
        let candidates = [stdio("alpha", harness: .codex, command: "a"),
                          stdio("beta", harness: .codex, command: "b")]
        registry.detectHarnessServers = { candidates }
        await MainActor.run { registry.refreshDetection() }
        let detected = await waitForDetection(registry)
        XCTAssertEqual(detected.map(\.name), ["beta"])
    }

    func testAlreadyConfiguredFilteringAppliesBeforeGrouping() async throws {
        // "alpha" is already configured with identical wiring in two harnesses;
        // grouping the published (already-filtered) detection must not surface it
        // in the shared list or any per-harness group. "beta" (codex-only) does.
        let url = try writeConfig(["mcpServers": ["alpha": ["command": "a"]]])
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = await makeRegistry(configURL: url)
        let candidates = [stdio("alpha", harness: .codex, command: "a"),
                          stdio("alpha", harness: .claudeCode, command: "a"),
                          stdio("beta", harness: .codex, command: "b")]
        registry.detectHarnessServers = { candidates }
        await MainActor.run { registry.refreshDetection() }
        let detected = await waitForDetection(registry)

        let grouping = MCPHarnessImport.group(detected)
        XCTAssertTrue(grouping.shared.isEmpty, "configured alpha must be filtered before it can dedup")
        let names = grouping.harnessGroups.flatMap { $0.servers.map(\.name) }
        XCTAssertEqual(names, ["beta"])
    }

    func testImportDetectedWritesAndReloads() async throws {
        let url = try writeConfig(["mcpServers": [:]])
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = await makeRegistry(configURL: url)
        let imported = try await MainActor.run {
            try registry.importDetected([self.stdio("gamma", harness: .codex, command: "g")])
        }
        XCTAssertEqual(imported["gamma"], "gamma")
        let configured = await MainActor.run { registry.configuredServers.map(\.name) }
        XCTAssertEqual(configured, ["gamma"])
    }
}
