import Foundation

public enum CompanionAppSupport {
    public static let appDisplayName = "Attaché"
    public static let supportDirectoryName = "Attache"
    public static let legacyAppDisplayName = "Codex Companion"
    public static let databaseFileName = "Attache.sqlite"
    public static let legacyDatabaseFileName = "CodexCompanion.sqlite"

    public static func supportDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = base.appendingPathComponent(supportDirectoryName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyAppDisplayName, isDirectory: true)

        if !fileManager.fileExists(atPath: current.path),
           fileManager.fileExists(atPath: legacy.path) {
            try? fileManager.moveItem(at: legacy, to: current)
        }
        return current
    }

    /// Per-launch bearer token for the local event server. Local tools read it to
    /// authorize POSTs; see `LocalEventServer`.
    public static func eventTokenURL(fileManager: FileManager = .default) -> URL {
        supportDirectory(fileManager: fileManager).appendingPathComponent("event-token")
    }

    public static func databaseURL(fileManager: FileManager = .default) -> URL {
        let support = supportDirectory(fileManager: fileManager)
        let current = support.appendingPathComponent(databaseFileName)
        let legacy = support.appendingPathComponent(legacyDatabaseFileName)

        if !fileManager.fileExists(atPath: current.path) {
            moveSQLiteStore(from: legacy, to: current, fileManager: fileManager)
        }
        return current
    }

    private static func moveSQLiteStore(from legacy: URL, to current: URL, fileManager: FileManager) {
        for suffix in ["", "-wal", "-shm"] {
            let legacySidecar = URL(fileURLWithPath: legacy.path + suffix)
            let currentSidecar = URL(fileURLWithPath: current.path + suffix)
            if fileManager.fileExists(atPath: legacySidecar.path),
               !fileManager.fileExists(atPath: currentSidecar.path) {
                try? fileManager.moveItem(at: legacySidecar, to: currentSidecar)
            }
        }
    }
}

public extension CompanionAppSupport {
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Development"
    }

    static var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "local"
    }
}
