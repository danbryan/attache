import Foundation

/// One MCP tool discovered from a server's `tools/list`, with everything the
/// app needs to offer it, gate it, and label its results. `isReadOnly` comes
/// from the MCP `annotations.readOnlyHint == true`; an absent annotation is
/// treated as NOT read-only, so effectful tools never slip into always-allow.
public struct MCPToolDescriptor: Equatable, Sendable, Identifiable {
    /// `mcp__<server>__<tool>`, the Claude Code convention.
    public let namespacedName: String
    /// The server this tool belongs to (the raw configured name).
    public let serverName: String
    /// The bare tool name as the server reports it.
    public let toolName: String
    public let description: String
    /// The tool's JSON input schema, as a JSON string. Empty when the server
    /// reported none.
    public let schemaJSON: String
    public let isReadOnly: Bool

    public var id: String { namespacedName }

    public init(
        serverName: String,
        toolName: String,
        description: String,
        schemaJSON: String,
        isReadOnly: Bool
    ) {
        self.serverName = serverName
        self.toolName = toolName
        self.description = description
        self.schemaJSON = schemaJSON
        self.isReadOnly = isReadOnly
        self.namespacedName = MCPToolNamespace.namespacedName(server: serverName, tool: toolName)
    }
}

/// Deterministic namespacing between a configured server name plus a bare tool
/// name and the `mcp__server__tool` string the model sees. Server names are
/// sanitized the way Claude Code sanitizes them: every character that is not an
/// ASCII letter or digit becomes `-`. Because a sanitized server name can never
/// contain `_`, the first `__` after the `mcp__` prefix is always the
/// server/tool separator, so parsing is unambiguous even for tool names that
/// contain single underscores.
public enum MCPToolNamespace {
    public static let prefix = "mcp__"
    public static let separator = "__"

    /// Sanitize a configured server name into the token used inside a
    /// namespaced tool name. Non-alphanumeric characters collapse to `-`.
    public static func sanitize(serverName: String) -> String {
        let scalars = serverName.unicodeScalars.map { scalar -> Character in
            let isAlphanumeric = (scalar >= "a" && scalar <= "z")
                || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9")
            return isAlphanumeric ? Character(scalar) : "-"
        }
        return String(scalars)
    }

    public static func namespacedName(server: String, tool: String) -> String {
        "\(prefix)\(sanitize(serverName: server))\(separator)\(tool)"
    }

    /// Parse a namespaced name back into (sanitized server token, bare tool).
    /// Returns nil if the string is not an `mcp__server__tool` name. The
    /// returned server is the sanitized token, not the original configured
    /// name; callers resolve the concrete server by matching sanitized tokens.
    public static func parse(_ namespaced: String) -> (server: String, tool: String)? {
        guard namespaced.hasPrefix(prefix) else { return nil }
        let remainder = String(namespaced.dropFirst(prefix.count))
        guard let separatorRange = remainder.range(of: separator) else { return nil }
        let server = String(remainder[remainder.startIndex..<separatorRange.lowerBound])
        let tool = String(remainder[separatorRange.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server, tool)
    }

    /// Whether a tool name is an MCP-namespaced name (versus a built-in tool).
    public static func isNamespaced(_ name: String) -> Bool {
        parse(name) != nil
    }
}
