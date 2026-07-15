import Foundation

/// Pure, testable merge of Attaché's managed hook entries into a Claude Code
/// `settings.json`. Attaché drives the character's exact status from Claude Code
/// lifecycle hooks (a `Notification` hook for "waiting on you" and a `Stop`
/// hook for "turn done"); this places those entries without disturbing any of
/// the user's own settings or hooks, and removes only its own on uninstall.
///
/// Managed entries are identified by their command pointing at Attaché's own
/// hook script path, so no foreign marker keys are written into the file that
/// Claude Code reads. File IO lives in the app layer; this stays pure.
public enum ClaudeHookInstaller {
    public struct Entry: Equatable {
        /// The Claude Code hook event, e.g. "Notification" or "Stop".
        public let event: String
        /// The full command line, e.g. "'/path/attache-hook.sh' turn_complete".
        public let command: String

        public init(event: String, command: String) {
            self.event = event
            self.command = command
        }
    }

    /// Returns `settingsJSON` with Attaché's managed entries for the given
    /// events replaced by `entries` (stale ones for those events removed
    /// first, so repeat installs are idempotent). Every other key and every
    /// non-managed hook is preserved. `nil`/empty input starts from `{}`.
    public static func settings(
        byInstalling entries: [Entry],
        into settingsJSON: Data?,
        managedScriptPath: String
    ) throws -> Data {
        var root = try object(from: settingsJSON)
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]

        for event in Set(entries.map(\.event)) {
            var list = (hooks[event] as? [[String: Any]]) ?? []
            list.removeAll { isManaged($0, scriptPath: managedScriptPath) }
            hooks[event] = list
        }
        for entry in entries {
            var list = (hooks[entry.event] as? [[String: Any]]) ?? []
            list.append(["hooks": [["type": "command", "command": entry.command]]])
            hooks[entry.event] = list
        }
        // A managed event that ended up empty (only possible with no entries)
        // is dropped so an empty array is never left behind.
        for (event, value) in hooks where (value as? [[String: Any]])?.isEmpty == true {
            hooks.removeValue(forKey: event)
        }

        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return try data(from: root)
    }

    /// Returns `settingsJSON` with only Attaché's managed entries removed,
    /// dropping any hook event left empty and the `hooks` key if it empties.
    public static func settings(
        byRemovingManagedFrom settingsJSON: Data?,
        managedScriptPath: String
    ) throws -> Data {
        var root = try object(from: settingsJSON)
        guard var hooks = root["hooks"] as? [String: Any] else { return try data(from: root) }
        for (event, value) in hooks {
            guard var list = value as? [[String: Any]] else { continue }
            list.removeAll { isManaged($0, scriptPath: managedScriptPath) }
            if list.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = list }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return try data(from: root)
    }

    /// True if `settingsJSON` already carries exactly Attaché's managed entries
    /// for `entries` and nothing stale, so the app can skip a rewrite.
    public static func isUpToDate(
        _ settingsJSON: Data?,
        entries: [Entry],
        managedScriptPath: String
    ) -> Bool {
        guard let current = settingsJSON,
              let target = try? settings(byInstalling: entries, into: settingsJSON, managedScriptPath: managedScriptPath)
        else { return false }
        // Compare normalized forms so key ordering and formatting never matter.
        return normalized(current) == normalized(target)
    }

    // MARK: - Internals

    static func isManaged(_ matcherObject: [String: Any], scriptPath: String) -> Bool {
        guard let inner = matcherObject["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { ($0["command"] as? String)?.contains(scriptPath) == true }
    }

    static func object(from data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func data(from object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func normalized(_ data: Data) -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }
}
