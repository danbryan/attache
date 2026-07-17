import XCTest
@testable import AttacheCore

final class MCPConfigEditorTests: XCTestCase {
    private func data(_ string: String) -> Data { Data(string.utf8) }

    private let existingTwoServers = """
    {
      "mcpServers": {
        "alpha": { "command": "alpha-bin", "args": ["--serve"] },
        "beta": { "url": "https://beta.example/mcp" }
      }
    }
    """

    // MARK: scaffold

    func testScaffoldParsesToEmptyConfig() {
        let parsed = MCPConfigFile.parse(MCPConfigEditor.scaffold())
        XCTAssertTrue(parsed.servers.isEmpty)
    }

    // MARK: merge

    func testMergeInnerObjectAddsAndPreservesSiblings() throws {
        let merged = try MCPConfigEditor.merge(
            snippet: #"{ "command": "gamma-bin", "args": ["run"] }"#,
            name: "gamma",
            into: data(existingTwoServers)
        )
        let parsed = MCPConfigFile.parse(merged)
        XCTAssertEqual(Set(parsed.servers.map(\.name)), ["alpha", "beta", "gamma"])
        let gamma = parsed.servers.first { $0.name == "gamma" }
        XCTAssertEqual(gamma?.command, "gamma-bin")
        XCTAssertEqual(gamma?.transport, .stdio)
        // The untouched siblings still resolve.
        XCTAssertEqual(parsed.servers.first { $0.name == "alpha" }?.command, "alpha-bin")
        XCTAssertEqual(parsed.servers.first { $0.name == "beta" }?.url?.absoluteString, "https://beta.example/mcp")
    }

    func testMergeFullFragmentUsesFragmentNames() throws {
        let merged = try MCPConfigEditor.merge(
            snippet: #"{ "mcpServers": { "delta": { "url": "https://delta.example/mcp" } } }"#,
            name: "ignored-when-fragment",
            into: data(existingTwoServers)
        )
        let parsed = MCPConfigFile.parse(merged)
        XCTAssertEqual(Set(parsed.servers.map(\.name)), ["alpha", "beta", "delta"])
        XCTAssertNil(parsed.servers.first { $0.name == "ignored-when-fragment" })
        XCTAssertEqual(parsed.servers.first { $0.name == "delta" }?.transport, .streamableHTTP)
    }

    func testMergeIntoEmptyStartsFresh() throws {
        let merged = try MCPConfigEditor.merge(
            snippet: #"{ "command": "solo" }"#,
            name: "solo",
            into: Data()
        )
        let parsed = MCPConfigFile.parse(merged)
        XCTAssertEqual(parsed.servers.map(\.name), ["solo"])
    }

    func testMergeRejectsInvalidServer() {
        // Neither command nor url is a hard configuration error.
        XCTAssertThrowsError(
            try MCPConfigEditor.merge(
                snippet: #"{ "args": ["nothing"] }"#,
                name: "broken",
                into: data(existingTwoServers)
            )
        ) { error in
            guard case MCPConfigEditor.EditError.invalidServer(let name, _) = error else {
                return XCTFail("expected invalidServer, got \(error)")
            }
            XCTAssertEqual(name, "broken")
        }
    }

    func testMergeRejectsNonJSON() {
        XCTAssertThrowsError(
            try MCPConfigEditor.merge(snippet: "not json", name: "x", into: Data())
        ) { XCTAssertEqual($0 as? MCPConfigEditor.EditError, .notJSON) }
    }

    func testMergeInnerObjectRequiresName() {
        XCTAssertThrowsError(
            try MCPConfigEditor.merge(snippet: #"{ "command": "x" }"#, name: "  ", into: Data())
        ) { XCTAssertEqual($0 as? MCPConfigEditor.EditError, .missingName) }
    }

    // MARK: setEnabled

    func testSetEnabledRewritesOnlyTargetEntry() throws {
        let updated = try MCPConfigEditor.setEnabled(false, forServer: "alpha", in: data(existingTwoServers))
        let parsed = MCPConfigFile.parse(updated)
        XCTAssertEqual(parsed.servers.first { $0.name == "alpha" }?.isEnabled, false)
        // Sibling untouched and still enabled by default.
        XCTAssertEqual(parsed.servers.first { $0.name == "beta" }?.isEnabled, true)

        // Flipping back on works too.
        let reEnabled = try MCPConfigEditor.setEnabled(true, forServer: "alpha", in: updated)
        XCTAssertEqual(MCPConfigFile.parse(reEnabled).servers.first { $0.name == "alpha" }?.isEnabled, true)
    }

    func testSetEnabledUnknownServerThrows() {
        XCTAssertThrowsError(
            try MCPConfigEditor.setEnabled(false, forServer: "ghost", in: data(existingTwoServers))
        ) { XCTAssertEqual($0 as? MCPConfigEditor.EditError, .unknownServer(name: "ghost")) }
    }

    // MARK: removeServer

    func testRemoveServerPreservesSiblings() {
        let updated = MCPConfigEditor.removeServer("alpha", in: data(existingTwoServers))
        let parsed = MCPConfigFile.parse(updated)
        XCTAssertEqual(parsed.servers.map(\.name), ["beta"])
    }

    func testRemoveMissingServerIsNoOp() {
        let updated = MCPConfigEditor.removeServer("ghost", in: data(existingTwoServers))
        XCTAssertEqual(Set(MCPConfigFile.parse(updated).servers.map(\.name)), ["alpha", "beta"])
    }
}
