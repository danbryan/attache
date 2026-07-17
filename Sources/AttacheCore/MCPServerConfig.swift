import Foundation

/// How Attaché talks to an MCP server. `stdio` launches a subprocess; the
/// remote kinds POST JSON-RPC to a URL. `http` and `streamableHTTP` are the
/// same streamable-HTTP transport under two spellings a Claude-compatible
/// config may use; `sse` is accepted and routed through the same POST-based
/// transport, which already handles an `text/event-stream` response body.
public enum MCPServerTransport: String, Codable, Equatable, Sendable {
    case stdio
    case http
    case streamableHTTP = "streamable-http"
    case sse

    /// Whether this transport launches a local subprocess (as opposed to a
    /// network endpoint).
    public var isStdio: Bool { self == .stdio }
}

/// One entry from a Claude-compatible `mcp.json`. Parsing never throws for a
/// bad entry: a malformed server surfaces a `validationError` string so a
/// Settings pane can list it while its valid siblings still connect.
public struct MCPServerConfig: Equatable, Sendable {
    public let name: String
    public let transport: MCPServerTransport
    public let command: String?
    public let args: [String]
    public let env: [String: String]
    public let url: URL?
    public let headers: [String: String]
    public let isEnabled: Bool
    /// Non-nil when the entry could not be resolved into a usable server. The
    /// server is still listed so the user can see and fix it.
    public let validationError: String?

    public init(
        name: String,
        transport: MCPServerTransport,
        command: String? = nil,
        args: [String] = [],
        env: [String: String] = [:],
        url: URL? = nil,
        headers: [String: String] = [:],
        isEnabled: Bool = true,
        validationError: String? = nil
    ) {
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.isEnabled = isEnabled
        self.validationError = validationError
    }

    public var isValid: Bool { validationError == nil }
}

/// A parsed `mcp.json`. `servers` preserves both valid and invalid entries in
/// stable (name-sorted) order.
public struct MCPConfigFile: Equatable, Sendable {
    public let servers: [MCPServerConfig]

    public init(servers: [MCPServerConfig]) {
        self.servers = servers
    }

    public static let empty = MCPConfigFile(servers: [])

    public var validServers: [MCPServerConfig] { servers.filter(\.isValid) }

    /// Parse the raw bytes of an `mcp.json`. Empty or non-object input yields
    /// an empty config rather than an error, so an absent or blank file is a
    /// normal state.
    public static func parse(_ data: Data) -> MCPConfigFile {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any] else {
            return .empty
        }
        guard let serversObject = object["mcpServers"] as? [String: Any] else {
            return .empty
        }
        var parsed: [MCPServerConfig] = []
        for name in serversObject.keys.sorted() {
            parsed.append(parseServer(name: name, raw: serversObject[name]))
        }
        return MCPConfigFile(servers: parsed)
    }

    /// Read and parse a config file. A missing file is an empty config.
    public static func read(
        from url: URL,
        fileManager: FileManager = .default
    ) -> MCPConfigFile {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return .empty
        }
        return parse(data)
    }

    private static func parseServer(name: String, raw: Any?) -> MCPServerConfig {
        guard let entry = raw as? [String: Any] else {
            return MCPServerConfig(
                name: name,
                transport: .stdio,
                validationError: "Server entry is not a JSON object."
            )
        }

        let isEnabled = (entry["enabled"] as? Bool) ?? true
        let command = (entry["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandValue = (command?.isEmpty == false) ? command : nil
        let args = (entry["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        let env = stringDictionary(entry["env"])
        let urlString = (entry["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlValue = (urlString?.isEmpty == false) ? URL(string: urlString!) : nil
        let headers = stringDictionary(entry["headers"])
        let declaredType = (entry["type"] as? String)
            .flatMap { MCPServerTransport(rawValue: $0.lowercased()) }

        // Neither / both are the two hard configuration errors.
        if commandValue == nil, urlValue == nil {
            let reason = (urlString?.isEmpty == false)
                ? "The url is not a valid URL."
                : "Specify either a command (stdio) or a url (remote)."
            return MCPServerConfig(
                name: name, transport: declaredType ?? .stdio,
                command: commandValue, args: args, env: env,
                url: urlValue, headers: headers, isEnabled: isEnabled,
                validationError: reason
            )
        }
        if commandValue != nil, urlValue != nil {
            return MCPServerConfig(
                name: name, transport: declaredType ?? .stdio,
                command: commandValue, args: args, env: env,
                url: urlValue, headers: headers, isEnabled: isEnabled,
                validationError: "Specify a command or a url, not both."
            )
        }

        // Resolve the transport: an explicit, consistent type wins; otherwise
        // infer from which of command/url is present.
        if commandValue != nil {
            if let declaredType, declaredType != .stdio {
                return MCPServerConfig(
                    name: name, transport: declaredType,
                    command: commandValue, args: args, env: env,
                    url: urlValue, headers: headers, isEnabled: isEnabled,
                    validationError: "type \"\(declaredType.rawValue)\" needs a url, not a command."
                )
            }
            return MCPServerConfig(
                name: name, transport: .stdio,
                command: commandValue, args: args, env: env,
                url: nil, headers: headers, isEnabled: isEnabled
            )
        }

        // Remote entry.
        if let declaredType, declaredType == .stdio {
            return MCPServerConfig(
                name: name, transport: .stdio,
                command: commandValue, args: args, env: env,
                url: urlValue, headers: headers, isEnabled: isEnabled,
                validationError: "type \"stdio\" needs a command, not a url."
            )
        }
        return MCPServerConfig(
            name: name, transport: declaredType ?? .streamableHTTP,
            command: nil, args: args, env: env,
            url: urlValue, headers: headers, isEnabled: isEnabled
        )
    }

    private static func stringDictionary(_ raw: Any?) -> [String: String] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in dict {
            if let string = value as? String {
                result[key] = string
            }
        }
        return result
    }
}
