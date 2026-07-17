import XCTest
@testable import AttacheCore

final class MCPToolPolicyTests: XCTestCase {
    private func descriptor(readOnly: Bool, server: String = "srv", tool: String = "t") -> MCPToolDescriptor {
        MCPToolDescriptor(
            serverName: server,
            toolName: tool,
            description: "",
            schemaJSON: "",
            isReadOnly: readOnly
        )
    }

    // MARK: Namespacing

    func testNamespaceBuildAndParseRoundTrip() {
        let name = MCPToolNamespace.namespacedName(server: "coinbase prime", tool: "list_wallets")
        XCTAssertEqual(name, "mcp__coinbase-prime__list_wallets")
        let parsed = MCPToolNamespace.parse(name)
        XCTAssertEqual(parsed?.server, "coinbase-prime")
        XCTAssertEqual(parsed?.tool, "list_wallets")
    }

    func testSanitizeIsDeterministic() {
        XCTAssertEqual(MCPToolNamespace.sanitize(serverName: "a.b/c:d"), "a-b-c-d")
        XCTAssertEqual(MCPToolNamespace.sanitize(serverName: "under_score"), "under-score")
        XCTAssertEqual(MCPToolNamespace.sanitize(serverName: "Alpha9"), "Alpha9")
    }

    func testParseRejectsNonNamespacedNames() {
        XCTAssertNil(MCPToolNamespace.parse("read_file"))
        XCTAssertNil(MCPToolNamespace.parse("mcp__onlyserver"))
        XCTAssertFalse(MCPToolNamespace.isNamespaced("stage_agent_instruction"))
        XCTAssertTrue(MCPToolNamespace.isNamespaced("mcp__srv__tool"))
    }

    func testToolNameWithUnderscoresParsesBackWhole() {
        let name = MCPToolNamespace.namespacedName(server: "srv", tool: "get_meeting_transcript")
        XCTAssertEqual(MCPToolNamespace.parse(name)?.tool, "get_meeting_transcript")
    }

    // MARK: effective() matrix

    func testEffectiveMatrix() {
        // Read-only tool: grant is honored in every mode.
        for isPrivate in [false, true] {
            XCTAssertEqual(MCPToolPolicy.effective(permission: .notOffered, isReadOnly: true, isPrivateCall: isPrivate), .notOffered)
            XCTAssertEqual(MCPToolPolicy.effective(permission: .askFirst, isReadOnly: true, isPrivateCall: isPrivate), .askFirst)
            XCTAssertEqual(MCPToolPolicy.effective(permission: .alwaysAllow, isReadOnly: true, isPrivateCall: isPrivate), .alwaysAllow)
        }

        // Effectful tool, non-private: alwaysAllow clamps to askFirst.
        XCTAssertEqual(MCPToolPolicy.effective(permission: .notOffered, isReadOnly: false, isPrivateCall: false), .notOffered)
        XCTAssertEqual(MCPToolPolicy.effective(permission: .askFirst, isReadOnly: false, isPrivateCall: false), .askFirst)
        XCTAssertEqual(MCPToolPolicy.effective(permission: .alwaysAllow, isReadOnly: false, isPrivateCall: false), .askFirst)

        // Effectful tool, private: absent entirely regardless of grant.
        XCTAssertEqual(MCPToolPolicy.effective(permission: .notOffered, isReadOnly: false, isPrivateCall: true), .notOffered)
        XCTAssertEqual(MCPToolPolicy.effective(permission: .askFirst, isReadOnly: false, isPrivateCall: true), .notOffered)
        XCTAssertEqual(MCPToolPolicy.effective(permission: .alwaysAllow, isReadOnly: false, isPrivateCall: true), .notOffered)
    }

    // MARK: offeredTools

    func testOfferedToolsRespectsGrantsAndPrivateClamp() {
        let readOnly = descriptor(readOnly: true, tool: "lookup")
        let effectful = descriptor(readOnly: false, tool: "write")
        let available = [readOnly, effectful]
        let grants: MCPToolGrants = [
            readOnly.namespacedName: .alwaysAllow,
            effectful.namespacedName: .askFirst
        ]

        let normal = MCPToolPolicy.offeredTools(available: available, grants: grants, isPrivateCall: false)
        XCTAssertEqual(Set(normal.map(\.namespacedName)), Set([readOnly.namespacedName, effectful.namespacedName]))

        let priv = MCPToolPolicy.offeredTools(available: available, grants: grants, isPrivateCall: true)
        XCTAssertEqual(priv.map(\.namespacedName), [readOnly.namespacedName])

        // Ungranted tools are never offered.
        let none = MCPToolPolicy.offeredTools(available: available, grants: [:], isPrivateCall: false)
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: grantToPersist clamp

    func testGrantToPersistRejectsEffectfulTools() {
        XCTAssertEqual(MCPToolPolicy.grantToPersist(afterAlwaysAllowFor: descriptor(readOnly: true)), .alwaysAllow)
        XCTAssertNil(MCPToolPolicy.grantToPersist(afterAlwaysAllowFor: descriptor(readOnly: false)))
    }

    // MARK: cyclePermission

    func testCyclePermissionReadOnlyWalksAllThreeStates() {
        XCTAssertEqual(MCPToolPolicy.cyclePermission(.notOffered, isReadOnly: true), .askFirst)
        XCTAssertEqual(MCPToolPolicy.cyclePermission(.askFirst, isReadOnly: true), .alwaysAllow)
        XCTAssertEqual(MCPToolPolicy.cyclePermission(.alwaysAllow, isReadOnly: true), .notOffered)
    }

    func testCyclePermissionEffectfulSkipsAlwaysAllow() {
        XCTAssertEqual(MCPToolPolicy.cyclePermission(.notOffered, isReadOnly: false), .askFirst)
        XCTAssertEqual(MCPToolPolicy.cyclePermission(.askFirst, isReadOnly: false), .notOffered)
        // Defensive: a stale alwaysAllow on an effectful tool still cycles home.
        XCTAssertEqual(MCPToolPolicy.cyclePermission(.alwaysAllow, isReadOnly: false), .notOffered)
    }

    // MARK: grants summary line

    func testGrantsSummaryLine() {
        XCTAssertEqual(MCPToolGrantsSummary.line(for: [:]), "No tools")
        XCTAssertEqual(
            MCPToolGrantsSummary.line(for: ["mcp__s__a": .askFirst]),
            "1 tool granted, 1 ask first"
        )
        XCTAssertEqual(
            MCPToolGrantsSummary.line(for: [
                "mcp__s__a": .askFirst,
                "mcp__s__b": .alwaysAllow
            ]),
            "2 tools granted, 1 ask first"
        )
        // notOffered entries are ignored, matching an absent key.
        XCTAssertEqual(
            MCPToolGrantsSummary.line(for: ["mcp__s__a": .notOffered]),
            "No tools"
        )
    }
}
