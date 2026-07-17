import Foundation

/// Pure, testable edits to a Claude-compatible `mcp.json`. Every function takes
/// the existing file bytes and returns new bytes, round-tripping the JSON so
/// unrelated server entries and top-level keys survive an edit. Output is
/// pretty-printed with sorted keys so a hand-editable file stays stable and
/// diff-friendly; that is the "as reasonable" formatting guarantee, not a
/// byte-for-byte preservation of the user's own whitespace.
public enum MCPConfigEditor {
    public enum EditError: Error, LocalizedError, Equatable {
        case notJSON
        case notAnObject
        case emptySnippet
        case missingName
        case invalidServer(name: String, reason: String)
        case unknownServer(name: String)

        public var errorDescription: String? {
            switch self {
            case .notJSON:
                return "That is not valid JSON."
            case .notAnObject:
                return "Expected a JSON object."
            case .emptySnippet:
                return "Paste an mcp.json server entry."
            case .missingName:
                return "Enter a name for the server."
            case .invalidServer(let name, let reason):
                return "\(name): \(reason)"
            case .unknownServer(let name):
                return "No server named \(name)."
            }
        }
    }

    /// The scaffold written when creating a fresh `mcp.json`.
    public static func scaffold() -> Data {
        serialize(["mcpServers": [String: Any]()])
    }

    /// Merge a pasted snippet into `existing`. The snippet may be a full
    /// `{"mcpServers": {...}}` fragment (names come from its keys) or a single
    /// bare server object (keyed under `name`). The result is validated with
    /// `MCPConfigFile.parse`; a snippet that would produce an unusable server
    /// throws rather than writing a broken entry.
    public static func merge(snippet: String, name: String, into existing: Data) throws -> Data {
        let trimmedSnippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSnippet.isEmpty else { throw EditError.emptySnippet }
        guard let snippetData = trimmedSnippet.data(using: .utf8),
              let snippetRoot = try? JSONSerialization.jsonObject(with: snippetData) else {
            throw EditError.notJSON
        }
        guard let snippetObject = snippetRoot as? [String: Any] else {
            throw EditError.notAnObject
        }

        // Entries to add: from an mcpServers wrapper, or the object itself.
        var additions: [String: Any] = [:]
        if let wrapped = snippetObject["mcpServers"] as? [String: Any] {
            guard !wrapped.isEmpty else { throw EditError.emptySnippet }
            additions = wrapped
        } else {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { throw EditError.missingName }
            additions = [trimmedName: snippetObject]
        }

        var root = objectRoot(from: existing)
        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        for (key, value) in additions {
            servers[key] = value
        }
        root["mcpServers"] = servers

        // Validate only the entries we just added; pre-existing broken siblings
        // are the user's to fix and must not block an unrelated add.
        let merged = serialize(root)
        let parsed = MCPConfigFile.parse(merged)
        for addedName in additions.keys {
            if let server = parsed.servers.first(where: { $0.name == addedName }),
               let reason = server.validationError {
                throw EditError.invalidServer(name: addedName, reason: reason)
            }
        }
        return merged
    }

    /// Rewrite a server entry's `"enabled"` key. Throws if the named entry is
    /// absent or is not a JSON object.
    public static func setEnabled(_ enabled: Bool, forServer name: String, in existing: Data) throws -> Data {
        var root = objectRoot(from: existing)
        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        guard var entry = servers[name] as? [String: Any] else {
            throw EditError.unknownServer(name: name)
        }
        entry["enabled"] = enabled
        servers[name] = entry
        root["mcpServers"] = servers
        return serialize(root)
    }

    /// Remove a server entry. Absent entries are a no-op (idempotent).
    public static func removeServer(_ name: String, in existing: Data) -> Data {
        var root = objectRoot(from: existing)
        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        servers.removeValue(forKey: name)
        root["mcpServers"] = servers
        return serialize(root)
    }

    // MARK: Helpers

    private static func objectRoot(from data: Data) -> [String: Any] {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any] else {
            return ["mcpServers": [String: Any]()]
        }
        return object
    }

    private static func serialize(_ object: [String: Any]) -> Data {
        let data = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data("{\n  \"mcpServers\" : {}\n}".utf8)
        return data + Data("\n".utf8)
    }
}
