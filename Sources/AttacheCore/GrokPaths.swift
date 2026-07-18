import Foundation

/// Mirrors `CodexPaths`/`ClaudePaths`. Unlike `CODEX_HOME` and
/// `CLAUDE_CONFIG_DIR`, `grok --help` (checked on this Mac, INF-361) does not
/// document a `GROK_HOME` override for the real Grok Build CLI, so setting it
/// on this app's own environment has no effect on where the real `grok`
/// itself writes session state. `GROK_HOME` is still honored here, for the
/// same reason `CODEX_HOME`/`CLAUDE_CONFIG_DIR` are: it gives tests and
/// fixtures (`scripts/create-fake-grok-home.py`) a disposable home to point
/// the scanner/watcher at without touching `~/.grok`.
public enum GrokPaths {
    public static func home(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let raw = environment["GROK_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
            .standardizedFileURL
    }

    public static func sessionsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        home(environment: environment, fileManager: fileManager)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Candidate config files to probe for an MCP configuration. Grok Build is
    /// TOML-based (`~/.grok/config.toml`); the installed version on this Mac
    /// (INF-361) carries no `[mcp_servers]` table, so probing it simply returns
    /// nothing. Adding a real path later is one entry in this list.
    public static func configTOMLURLs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [URL] {
        [home(environment: environment, fileManager: fileManager)
            .appendingPathComponent("config.toml")]
    }
}
