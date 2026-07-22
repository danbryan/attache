import XCTest
@testable import AttacheCore

/// INF: watched-session activity labels must come from an MCP call's STRUCTURED
/// identity, not a substring of its arguments. These pin the pure humanization
/// so any new server the user adds is labeled with no whitelist.
final class MCPToolIdentityTests: XCTestCase {
    func testClaudeNamespacedNamesHumanizeToTheirService() {
        XCTAssertEqual(
            MCPToolIdentity.serverLabel(fromToolName: "mcp__coinbase-prime-bryanlabs__get_portfolio"),
            "Coinbase"
        )
        XCTAssertEqual(
            MCPToolIdentity.serverLabel(fromToolName: "mcp__slack-bryanlabs-korotovsky__conversations_history"),
            "Slack"
        )
        XCTAssertEqual(
            MCPToolIdentity.serverLabel(fromToolName: "mcp__linear__list_issues"),
            "Linear"
        )
        XCTAssertEqual(
            MCPToolIdentity.serverLabel(fromToolName: "mcp__google-workspace-extended__search_gmail_messages"),
            "Google"
        )
        XCTAssertEqual(
            MCPToolIdentity.serverLabel(fromToolName: "mcp__quickbooks-bryanlabs__get_profit_loss"),
            "Quickbooks"
        )
    }

    func testUnknownNewServerIsLabeledGenericallyWithNoWhitelist() {
        XCTAssertEqual(
            MCPToolIdentity.serverLabel(fromToolName: "mcp__acme-widgets__do_thing"),
            "Acme"
        )
    }

    func testNonMCPNameReturnsNil() {
        XCTAssertNil(MCPToolIdentity.serverLabel(fromToolName: "Bash"))
        XCTAssertNil(MCPToolIdentity.serverLabel(fromToolName: "web_search_call"))
        XCTAssertNil(MCPToolIdentity.serverLabel(fromToolName: "apply_patch"))
        XCTAssertNil(MCPToolIdentity.serverLabel(fromToolName: "TodoWrite"))
    }

    func testCodexPayloadVariantReadsStructuredServerField() {
        // invocation.server (Codex mcp_tool_call_end shape).
        XCTAssertEqual(
            MCPToolIdentity.serverLabel(fromCodexPayload: [
                "invocation": ["server": "coinbase-prime-bryanlabs", "tool": "get_portfolio", "arguments": ["note": "slack about coinbase"]]
            ]),
            "Coinbase"
        )
        // top-level server field.
        XCTAssertEqual(
            MCPToolIdentity.serverLabel(fromCodexPayload: ["server": "linear", "tool": "list_issues"]),
            "Linear"
        )
        // server__tool flattened name form.
        XCTAssertEqual(
            MCPToolIdentity.serverLabel(fromCodexPayload: ["tool": "slack-bryanlabs-korotovsky__conversations_search_messages"]),
            "Slack"
        )
    }

    func testCodexPayloadWithNoServerIdentityReturnsNil() {
        XCTAssertNil(MCPToolIdentity.serverLabel(fromCodexPayload: ["result": "coinbase mentioned here"]))
        XCTAssertNil(MCPToolIdentity.serverLabel(fromCodexPayload: ["tool": "exec_command"]))
    }
}
