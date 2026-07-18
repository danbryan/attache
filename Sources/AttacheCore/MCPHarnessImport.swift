import Foundation

/// One of the agent harnesses Attaché can read an MCP configuration from. The
/// display name is what a Settings section labels the group with.
public enum MCPHarness: String, Codable, Sendable, CaseIterable, Equatable {
    case claudeCode
    case codex
    case opencode
    case grokBuild

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "opencode"
        case .grokBuild: return "Grok Build"
        }
    }
}

/// Whether a detected server can be imported with the credentials Attaché can
/// see. A command-based server is always importable; a remote server is
/// importable only when the harness config carries a static auth header for it.
/// A remote server with no stored header is an OAuth-ish shape whose live
/// credentials are not in the file, so it is flagged rather than imported.
public enum MCPImportability: Equatable, Sendable {
    case importable
    case needsAuth(reason: String)

    public var isImportable: Bool {
        if case .importable = self { return true }
        return false
    }

    public var reason: String? {
        if case .needsAuth(let reason) = self { return reason }
        return nil
    }
}

/// A server discovered in another harness's config, ready to be shown in the
/// "Detected in your other tools" section and, when importable, merged into
/// Attaché's own `mcp.json`. Detection is read-only; nothing here writes any
/// harness file.
public struct MCPDetectedServer: Equatable, Sendable, Identifiable {
    /// The harness this entry came from.
    public let harness: MCPHarness
    /// The on-disk file the entry was read from (shown as a caption).
    public let originPath: String
    /// The parsed, validated server, in Attaché's own config shape.
    public let config: MCPServerConfig
    public let importability: MCPImportability

    public var name: String { config.name }
    public var transport: MCPServerTransport { config.transport }

    public var id: String { "\(harness.rawValue)|\(originPath)|\(config.name)" }

    public init(
        harness: MCPHarness,
        originPath: String,
        config: MCPServerConfig,
        importability: MCPImportability
    ) {
        self.harness = harness
        self.originPath = originPath
        self.config = config
        self.importability = importability
    }

    /// A one-line description of how the server connects, e.g.
    /// "stdio: npx …" or "http: localhost:12008".
    public var transportSummary: String {
        if config.transport.isStdio {
            let command = config.command ?? ""
            let tail = config.args.first.map { " \($0)…" } ?? ""
            return "stdio: \(command)\(tail)"
        }
        let label = config.transport == .stdio ? "stdio" : config.transport.rawValue
        let where_ = config.url.map { url -> String in
            if let host = url.host {
                if let port = url.port { return "\(host):\(port)" }
                return host
            }
            return url.absoluteString
        } ?? ""
        return "\(label): \(where_)"
    }
}

/// The exact transport identity used to decide that two detected entries are the
/// SAME server. It mirrors the registry's already-configured comparison
/// (`sameConnection`): command+args+env for stdio, url+headers for remote, plus
/// the transport itself. Name is deliberately excluded, so two harnesses listing
/// the same wiring under the same or different labels collapse, while the same
/// name with any transport difference stays distinct.
public struct MCPTransportIdentity: Hashable, Sendable {
    public let transport: MCPServerTransport
    public let command: String?
    public let args: [String]
    public let env: [String: String]
    public let url: URL?
    public let headers: [String: String]

    public init(_ config: MCPServerConfig) {
        self.transport = config.transport
        self.command = config.command
        self.args = config.args
        self.env = config.env
        self.url = config.url
        self.headers = config.headers
    }
}

/// One detected server that was found under the SAME transport identity in two
/// or more harnesses, collapsed to a single row that carries every origin
/// harness. Importing it imports only the single `canonical` entry.
public struct MCPDedupedDetectedServer: Equatable, Sendable, Identifiable {
    /// The single entry that gets imported when the deduped row's Import is used.
    public let canonical: MCPDetectedServer
    /// The harnesses the identity was found in, in first-seen order.
    public let origins: [MCPHarness]

    public var id: String {
        "\(canonical.config.name)|" + origins.map(\.rawValue).joined(separator: ",")
    }

    public var isImportable: Bool { canonical.importability.isImportable }

    public init(canonical: MCPDetectedServer, origins: [MCPHarness]) {
        self.canonical = canonical
        self.origins = origins
    }
}

/// The detected servers of a single harness, with any cross-harness duplicates
/// already lifted out into the deduped list (so Import All here never
/// re-imports a server already represented above).
public struct MCPDetectedHarnessGroup: Equatable, Sendable, Identifiable {
    public let harness: MCPHarness
    public let servers: [MCPDetectedServer]

    public var id: MCPHarness { harness }

    public init(harness: MCPHarness, servers: [MCPDetectedServer]) {
        self.harness = harness
        self.servers = servers
    }
}

/// The full grouped shape the Settings pane renders: cross-harness duplicates in
/// `shared`, then the remaining per-harness groups in first-seen order.
public struct MCPDetectedGrouping: Equatable, Sendable {
    /// Servers found under the same transport identity in more than one harness.
    public let shared: [MCPDedupedDetectedServer]
    /// The per-harness groups, with shared identities removed.
    public let harnessGroups: [MCPDetectedHarnessGroup]

    public init(shared: [MCPDedupedDetectedServer], harnessGroups: [MCPDetectedHarnessGroup]) {
        self.shared = shared
        self.harnessGroups = harnessGroups
    }
}

/// Pure, fixture-testable readers for the MCP configs written by other
/// harnesses. Each parser takes file CONTENT (never a path) so it unit-tests on
/// bytes; a thin App-side prober reads the real files and hands the content in.
///
/// Every parser normalizes an entry into Attaché's own `mcp.json` server shape
/// and runs it back through `MCPConfigFile.parse`, so transport resolution and
/// validation stay identical to a hand-written `mcp.json`. Malformed input is
/// skipped, not thrown: a bad entry simply does not appear.
public enum MCPHarnessImport {
    private static let oauthReason =
        "This remote server has no stored auth header, so it likely uses an interactive OAuth login. Attaché cannot import working credentials for it."

    /// Classify a resolved config: stdio is always importable; a remote server
    /// is importable only when it carries a static header, otherwise it is
    /// flagged as needing auth.
    public static func classify(_ config: MCPServerConfig) -> MCPImportability {
        if config.transport.isStdio { return .importable }
        if !config.headers.isEmpty { return .importable }
        return .needsAuth(reason: oauthReason)
    }

    /// Group already-filtered detected servers (the registry has already removed
    /// anything matching a configured server) into the deduped + per-harness
    /// structure the pane renders.
    ///
    /// A transport identity found in two or more DISTINCT harnesses becomes one
    /// deduped row carrying every origin harness; those identities are then
    /// removed from the per-harness groups, so an Import All on a group never
    /// re-imports a server already offered as a shared row. Everything else stays
    /// in its own harness group. Harness and identity order follow first
    /// appearance in the input.
    public static func group(_ detected: [MCPDetectedServer]) -> MCPDetectedGrouping {
        var identityOrder: [MCPTransportIdentity] = []
        var byIdentity: [MCPTransportIdentity: [MCPDetectedServer]] = [:]
        for server in detected {
            let identity = MCPTransportIdentity(server.config)
            if byIdentity[identity] == nil { identityOrder.append(identity) }
            byIdentity[identity, default: []].append(server)
        }

        var sharedIdentities = Set<MCPTransportIdentity>()
        var shared: [MCPDedupedDetectedServer] = []
        for identity in identityOrder {
            let entries = byIdentity[identity] ?? []
            var seenHarnesses = Set<MCPHarness>()
            var origins: [MCPHarness] = []
            for entry in entries where seenHarnesses.insert(entry.harness).inserted {
                origins.append(entry.harness)
            }
            guard origins.count >= 2 else { continue }
            sharedIdentities.insert(identity)
            let canonical = entries.first { $0.importability.isImportable } ?? entries[0]
            shared.append(MCPDedupedDetectedServer(canonical: canonical, origins: origins))
        }

        var harnessOrder: [MCPHarness] = []
        var byHarness: [MCPHarness: [MCPDetectedServer]] = [:]
        for server in detected {
            if sharedIdentities.contains(MCPTransportIdentity(server.config)) { continue }
            if byHarness[server.harness] == nil { harnessOrder.append(server.harness) }
            byHarness[server.harness, default: []].append(server)
        }
        let harnessGroups = harnessOrder.map {
            MCPDetectedHarnessGroup(harness: $0, servers: byHarness[$0] ?? [])
        }

        return MCPDetectedGrouping(shared: shared, harnessGroups: harnessGroups)
    }

    // MARK: Claude Code (~/.claude.json and project .mcp.json)

    /// Parse a Claude-shaped config (`{"mcpServers": {…}}`), the same object
    /// used by `~/.claude.json` and a project's `.mcp.json`.
    public static func parseClaudeConfig(
        _ data: Data,
        originPath: String,
        harness: MCPHarness = .claudeCode
    ) -> [MCPDetectedServer] {
        MCPConfigFile.parse(data).servers.compactMap {
            detected(from: $0, harness: harness, originPath: originPath)
        }
    }

    // MARK: opencode (~/.config/opencode/opencode.json)

    /// Parse an opencode config's `"mcp"` object. Entries are `type` "local"
    /// (a `command` array plus optional `environment`) or "remote" (a `url`
    /// plus optional `headers`), each with an optional `enabled`.
    public static func parseOpencodeConfig(
        _ data: Data,
        originPath: String
    ) -> [MCPDetectedServer] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mcp = root["mcp"] as? [String: Any] else {
            return []
        }
        var normalized: [String: Any] = [:]
        for (name, raw) in mcp {
            guard let entry = raw as? [String: Any] else { continue }
            normalized[name] = normalizeOpencodeEntry(entry)
        }
        return parseNormalized(normalized, harness: .opencode, originPath: originPath)
    }

    private static func normalizeOpencodeEntry(_ entry: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        let type = (entry["type"] as? String)?.lowercased()
        if type == "remote" {
            if let url = entry["url"] as? String { out["url"] = url }
            if let headers = stringDictionary(entry["headers"]) { out["headers"] = headers }
        } else {
            // "local" (or unspecified): a command array, first element is the
            // executable, the rest are args.
            if let command = entry["command"] as? [Any] {
                let parts = command.compactMap { $0 as? String }
                if let first = parts.first { out["command"] = first }
                if parts.count > 1 { out["args"] = Array(parts.dropFirst()) }
            } else if let command = entry["command"] as? String {
                out["command"] = command
            }
            if let env = stringDictionary(entry["environment"]) { out["env"] = env }
        }
        if let enabled = entry["enabled"] as? Bool { out["enabled"] = enabled }
        return out
    }

    // MARK: Codex (~/.codex/config.toml)

    /// Parse a Codex `config.toml`, pulling `[mcp_servers.<name>]` tables. stdio
    /// entries use `command`/`args`/`env`; remote entries use `url` with an
    /// optional `[mcp_servers.<name>.http_headers]` (or `headers`) subtable.
    public static func parseCodexConfig(
        _ text: String,
        originPath: String,
        harness: MCPHarness = .codex
    ) -> [MCPDetectedServer] {
        let toml = MinimalTOML.parse(text)
        guard case .table(let servers)? = toml["mcp_servers"] else { return [] }
        var normalized: [String: Any] = [:]
        for (name, value) in servers {
            guard case .table(let entry) = value else { continue }
            normalized[name] = normalizeCodexEntry(entry)
        }
        return parseNormalized(normalized, harness: harness, originPath: originPath)
    }

    private static func normalizeCodexEntry(_ entry: [String: MinimalTOML.Value]) -> [String: Any] {
        var out: [String: Any] = [:]
        if case .string(let command)? = entry["command"] { out["command"] = command }
        if case .array(let args)? = entry["args"] {
            out["args"] = args.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        if case .table(let env)? = entry["env"] { out["env"] = tomlStringTable(env) }
        if case .string(let url)? = entry["url"] { out["url"] = url }
        if case .table(let headers)? = entry["http_headers"] {
            out["headers"] = tomlStringTable(headers)
        } else if case .table(let headers)? = entry["headers"] {
            out["headers"] = tomlStringTable(headers)
        }
        if case .boolean(let enabled)? = entry["enabled"] { out["enabled"] = enabled }
        return out
    }

    // MARK: Shared

    private static func parseNormalized(
        _ normalized: [String: Any],
        harness: MCPHarness,
        originPath: String
    ) -> [MCPDetectedServer] {
        guard !normalized.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": normalized]) else {
            return []
        }
        return MCPConfigFile.parse(data).servers.compactMap {
            detected(from: $0, harness: harness, originPath: originPath)
        }
    }

    private static func detected(
        from config: MCPServerConfig,
        harness: MCPHarness,
        originPath: String
    ) -> MCPDetectedServer? {
        // A config that failed validation is not offered for import.
        guard config.isValid else { return nil }
        return MCPDetectedServer(
            harness: harness,
            originPath: originPath,
            config: config,
            importability: classify(config)
        )
    }

    private static func stringDictionary(_ raw: Any?) -> [String: String]? {
        guard let dict = raw as? [String: Any] else { return nil }
        var result: [String: String] = [:]
        for (key, value) in dict where value is String {
            result[key] = value as? String
        }
        return result.isEmpty ? nil : result
    }

    private static func tomlStringTable(_ table: [String: MinimalTOML.Value]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in table {
            if case .string(let s) = value { result[key] = s }
        }
        return result
    }
}
