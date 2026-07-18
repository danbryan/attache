import Foundation

public enum CodexPaths {
    public static func home(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let raw = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL
    }

    public static func sessionsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        home(environment: environment, fileManager: fileManager)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    public static func archivedSessionsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        home(environment: environment, fileManager: fileManager)
            .appendingPathComponent("archived_sessions", isDirectory: true)
    }

    public static func automationsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        home(environment: environment, fileManager: fileManager)
            .appendingPathComponent("automations", isDirectory: true)
    }

    public static func sessionIndexURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        home(environment: environment, fileManager: fileManager)
            .appendingPathComponent("session_index.jsonl")
    }

    /// The Codex config file that holds `[mcp_servers.<name>]` tables.
    public static func configTOMLURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        home(environment: environment, fileManager: fileManager)
            .appendingPathComponent("config.toml")
    }
}
