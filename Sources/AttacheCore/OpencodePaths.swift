import Foundation

/// Mirrors `GrokPaths`/`CodexPaths`/`ClaudePaths`, but opencode stores its
/// state under XDG's data-home convention rather than a dotfile home:
/// `~/.local/share/opencode/opencode.db` (WAL mode; verified on this Mac,
/// INF-362). `opencode --help` does not document `XDG_DATA_HOME`, but
/// `opencode debug paths` (also checked on this Mac) proves the real CLI
/// honors it empirically: with `XDG_DATA_HOME=/tmp/x` set, its reported
/// `data` path becomes `/tmp/x/opencode` instead of `~/.local/share/opencode`.
/// So unlike Grok Build (no working override at all), setting this on this
/// app's own environment IS honored by the real `opencode` binary too, the
/// same way `CODEX_HOME`/`CLAUDE_CONFIG_DIR` are. It also gives tests and
/// fixtures (`scripts/create-fake-opencode-home.py`) a disposable data home
/// without touching the real `~/.local/share/opencode`.
public enum OpencodePaths {
    public static func dataHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let raw = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true)
                .standardizedFileURL
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .standardizedFileURL
    }

    /// `OPENCODE_HOME` is not a real opencode override (checked against
    /// `opencode --help` on this Mac, INF-362); the alias below exists only
    /// so call sites read naturally. `dataHome()` is the actual resolver.
    public static func home(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        dataHome(environment: environment, fileManager: fileManager)
    }

    public static func databaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        dataHome(environment: environment, fileManager: fileManager)
            .appendingPathComponent("opencode.db")
    }

    public static func databaseWALURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        URL(fileURLWithPath: databaseURL(environment: environment, fileManager: fileManager).path + "-wal")
    }

    public static func databaseSHMURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        URL(fileURLWithPath: databaseURL(environment: environment, fileManager: fileManager).path + "-shm")
    }

    /// opencode's user config directory: `$XDG_CONFIG_HOME/opencode`, defaulting
    /// to `~/.config/opencode`. This is the CONFIG home, distinct from the DATA
    /// home above that holds the session database.
    public static func configDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let raw = environment["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true)
                .standardizedFileURL
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .standardizedFileURL
    }

    /// Candidate MCP config files, in probe order: `opencode.json` then the
    /// older `config.json`.
    public static func configFileURLs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [URL] {
        let directory = configDirectory(environment: environment, fileManager: fileManager)
        return [
            directory.appendingPathComponent("opencode.json"),
            directory.appendingPathComponent("config.json"),
        ]
    }
}
