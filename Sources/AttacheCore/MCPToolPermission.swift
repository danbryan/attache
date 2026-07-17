import Foundation

/// Per-personality permission for a single MCP tool. The default is
/// `notOffered`: the schema is never sent to the model, which is both the
/// safety boundary and the context-budget mechanism (see docs/mcp-tools.md).
public enum MCPToolPermission: String, Codable, Equatable, Sendable {
    /// Schema never sent to the model.
    case notOffered
    /// Offered; each call pauses for a one-tap confirmation.
    case askFirst
    /// Runs without a prompt. Only valid for read-only tools.
    case alwaysAllow

    public static let defaultPermission: MCPToolPermission = .notOffered
}

/// A personality's tool grants, keyed by the namespaced tool name
/// (`mcp__server__tool`). A missing key means `notOffered`.
public typealias MCPToolGrants = [String: MCPToolPermission]

/// Pure summary-line formatting for a personality's tool grants, shown in the
/// personality editor's Tools section. A grant is any entry that is not
/// `notOffered`; `notOffered` entries (which should never be stored) are
/// ignored the same way an absent key is.
public enum MCPToolGrantsSummary {
    public static func line(for grants: MCPToolGrants) -> String {
        let offered = grants.values.filter { $0 != .notOffered }
        guard !offered.isEmpty else { return "No tools" }
        let askFirst = offered.filter { $0 == .askFirst }.count
        let toolWord = offered.count == 1 ? "tool" : "tools"
        return "\(offered.count) \(toolWord) granted, \(askFirst) ask first"
    }
}
