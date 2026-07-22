import Foundation

/// Structured, deterministic derivation of a human service label from an MCP
/// tool call's IDENTITY, never from a substring of its call text (INF: the
/// watched-session activity ring showed "checking Coinbase" whenever the word
/// "coinbase" appeared anywhere in a tool call's arguments, e.g. a Slack search
/// query, even though no Coinbase tool ran). A label is emitted only for a call
/// whose namespaced identity actually resolves to a server; arguments and
/// results are never consulted.
///
/// Humanization is GENERIC: it takes the first meaningful token of the server
/// namespace, strips trivially detectable org/suffix noise
/// (bryanlabs/extended/prime/korotovsky/...), and title-cases it. There is no
/// service whitelist, so any MCP server the user adds is labeled automatically.
public enum MCPToolIdentity {
    /// Namespace tokens that are org affiliation or connector-flavor noise, not
    /// the service name. Only used to skip a LEADING noise token when scanning
    /// for the first meaningful one; taking the first token already excludes
    /// trailing noise like `coinbase-prime-bryanlabs` -> "Coinbase".
    private static let noiseTokens: Set<String> = [
        "bryanlabs", "bryanflex", "bryanrx", "bryanventures", "thebryans", "bryan",
        "extended", "prime", "korotovsky", "full", "mcp", "metamcp", "server",
        "official", "connector", "io", "com", "app", "the",
    ]

    /// The service label for a Claude-style namespaced tool name
    /// (`mcp__<server>__<tool>`). Returns nil for a non-MCP (built-in) tool
    /// name, so built-ins keep their own stable verb map.
    public static func serverLabel(fromToolName name: String) -> String? {
        guard let parsed = MCPToolNamespace.parse(name) else { return nil }
        return humanize(serverToken: parsed.server)
    }

    /// The service label from a Codex `mcp_tool_call_end` payload. Codex carries
    /// the server/tool identity structurally rather than in a `mcp__` name, so
    /// this reads (in order): `invocation.server`, a top-level `server`, or a
    /// `server__tool` / `mcp__server__tool` form in `tool` / `name` /
    /// `tool_name` (top level or nested under `invocation`). Never inspects
    /// `arguments` or `result`.
    public static func serverLabel(fromCodexPayload payload: [String: Any]) -> String? {
        let invocation = payload["invocation"] as? [String: Any]

        if let server = (invocation?["server"] as? String) ?? (payload["server"] as? String),
           let label = humanize(serverToken: server) {
            return label
        }

        for container in [invocation, payload].compactMap({ $0 }) {
            for key in ["tool", "name", "tool_name"] {
                guard let value = container[key] as? String else { continue }
                if let server = serverToken(fromCompoundName: value),
                   let label = humanize(serverToken: server) {
                    return label
                }
            }
        }
        return nil
    }

    /// Parse the server segment out of either `mcp__server__tool` or the bare
    /// `server__tool` form Codex sometimes flattens MCP calls into. Returns nil
    /// for a name with no `__` server separator (a built-in tool).
    static func serverToken(fromCompoundName name: String) -> String? {
        if let parsed = MCPToolNamespace.parse(name) { return parsed.server }
        guard let separator = name.range(of: MCPToolNamespace.separator) else { return nil }
        let server = String(name[name.startIndex..<separator.lowerBound])
        return server.isEmpty ? nil : server
    }

    /// Humanize a server namespace token into a short display label. Splits on
    /// non-alphanumerics, skips leading org/suffix noise, title-cases the first
    /// meaningful token. Returns nil only for an empty/noise-only token.
    public static func humanize(serverToken token: String) -> String? {
        let parts = token
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        guard !parts.isEmpty else { return nil }
        let meaningful = parts.first { !noiseTokens.contains($0) } ?? parts[0]
        return titleCased(meaningful)
    }

    private static func titleCased(_ token: String) -> String {
        guard let first = token.first else { return token }
        return first.uppercased() + token.dropFirst()
    }
}
