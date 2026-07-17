import XCTest
@testable import AttacheCore

final class MCPServerConfigTests: XCTestCase {
    private func parse(_ json: String) -> MCPConfigFile {
        MCPConfigFile.parse(Data(json.utf8))
    }

    func testValidStdioEntry() {
        let config = parse(#"""
        { "mcpServers": {
            "notes": { "command": "npx", "args": ["-y", "server"], "env": { "TOKEN": "abc" } }
        } }
        """#)
        XCTAssertEqual(config.servers.count, 1)
        let server = config.servers[0]
        XCTAssertEqual(server.name, "notes")
        XCTAssertTrue(server.isValid)
        XCTAssertEqual(server.transport, .stdio)
        XCTAssertEqual(server.command, "npx")
        XCTAssertEqual(server.args, ["-y", "server"])
        XCTAssertEqual(server.env, ["TOKEN": "abc"])
        XCTAssertNil(server.url)
        XCTAssertTrue(server.isEnabled)
    }

    func testValidHTTPEntryWithHeaders() {
        let config = parse(#"""
        { "mcpServers": {
            "gateway": {
                "url": "http://localhost:12008/metamcp/full/mcp",
                "headers": { "Authorization": "Bearer tok" }
            }
        } }
        """#)
        let server = config.servers[0]
        XCTAssertTrue(server.isValid)
        XCTAssertEqual(server.transport, .streamableHTTP)
        XCTAssertEqual(server.url?.absoluteString, "http://localhost:12008/metamcp/full/mcp")
        XCTAssertEqual(server.headers, ["Authorization": "Bearer tok"])
        XCTAssertNil(server.command)
    }

    func testExplicitTypeIsHonored() {
        let config = parse(#"""
        { "mcpServers": {
            "sse": { "type": "sse", "url": "http://localhost:9/sse" }
        } }
        """#)
        XCTAssertEqual(config.servers[0].transport, .sse)
        XCTAssertTrue(config.servers[0].isValid)
    }

    func testDisabledEntryParsesButIsFlagged() {
        let config = parse(#"""
        { "mcpServers": {
            "off": { "command": "run", "enabled": false }
        } }
        """#)
        let server = config.servers[0]
        XCTAssertTrue(server.isValid)
        XCTAssertFalse(server.isEnabled)
    }

    func testMalformedEntrySurfacesErrorWhileSiblingsParse() {
        let config = parse(#"""
        { "mcpServers": {
            "good": { "command": "run" },
            "neither": { "args": ["x"] },
            "both": { "command": "run", "url": "http://localhost/mcp" }
        } }
        """#)
        // Sorted by name: both, good, neither.
        let byName = Dictionary(uniqueKeysWithValues: config.servers.map { ($0.name, $0) })
        XCTAssertTrue(byName["good"]!.isValid)
        XCTAssertNotNil(byName["neither"]!.validationError)
        XCTAssertFalse(byName["neither"]!.isValid)
        XCTAssertNotNil(byName["both"]!.validationError)
        XCTAssertEqual(config.validServers.map(\.name), ["good"])
    }

    func testUnknownKeysAreIgnored() {
        let config = parse(#"""
        { "mcpServers": {
            "srv": { "command": "run", "surpriseKey": 42, "timeout": "10s" }
        }, "otherTopLevel": true }
        """#)
        XCTAssertEqual(config.servers.count, 1)
        XCTAssertTrue(config.servers[0].isValid)
    }

    func testEmptyAndAbsentFileYieldEmptyConfig() {
        XCTAssertEqual(MCPConfigFile.parse(Data()), .empty)
        XCTAssertEqual(parse("{}"), .empty)
        XCTAssertEqual(parse(#"{ "mcpServers": {} }"#).servers.count, 0)
        XCTAssertEqual(parse("not json at all"), .empty)
    }

    func testReadMissingFileIsEmpty() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        XCTAssertEqual(MCPConfigFile.read(from: url), .empty)
    }
}
