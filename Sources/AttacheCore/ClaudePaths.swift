import Foundation

/// Mirrors `CodexPaths`: the real Claude Code CLI honors `CLAUDE_CONFIG_DIR` as a
/// full override of `~/.claude` (verified against the real CLI on this machine,
/// INF-257/E2). Every place Attaché locates Claude Code's on-disk session state
/// must resolve through here instead of hardcoding `~/.claude`, so a disposable
/// `CLAUDE_CONFIG_DIR` set on the app's own environment (the same way
/// `codex-two-way-smoke.sh` sets `CODEX_HOME`) is honored end to end: session
/// discovery (Command-K), the live watcher, and the two-way delivery adapter's
/// readiness/transcript lookup all agree with whatever `claude` itself is using.
public enum ClaudePaths {
    public static func home(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let raw = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .standardizedFileURL
    }

    public static func projectsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        home(environment: environment, fileManager: fileManager)
            .appendingPathComponent("projects", isDirectory: true)
    }
}
