import Foundation

/// The Claude desktop app names sessions (its sidebar titles) in small JSON
/// records under Application Support, keyed by the CLI session id that also
/// names the transcript file. Reading them lets Attaché show the same names
/// the user sees in Claude Code instead of raw first-message text.
public enum ClaudeDesktopSessionTitles {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    /// cliSessionId -> title. Missing directory or malformed files simply
    /// yield an empty map; CLI-only installs never have this store.
    public static func load(root: URL = defaultRoot) -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [:] }
        var titles: [String: String] = [:]
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > 2000 { break }
            guard url.pathExtension == "json" else { continue }
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cliSessionID = object["cliSessionId"] as? String,
                  let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { continue }
            titles[cliSessionID] = title
        }
        return titles
    }
}
