import Foundation

public enum AttacheAppSupport {
    public static let appDisplayName = "Attaché"
    public static let supportDirectoryName = "Attache"
    public static let databaseFileName = "Attache.sqlite"

    public static func supportDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(supportDirectoryName, isDirectory: true)
    }

    /// Per-launch bearer token for the local event server. Local tools read it to
    /// authorize POSTs; see `LocalEventServer`.
    public static func eventTokenURL(fileManager: FileManager = .default) -> URL {
        supportDirectory(fileManager: fileManager).appendingPathComponent("event-token")
    }

    /// Persisted "do not record" session set (INF-357). See
    /// `SessionPrivacyRegistry`.
    public static func sessionPrivacyRegistryURL(fileManager: FileManager = .default) -> URL {
        supportDirectory(fileManager: fileManager).appendingPathComponent("SessionPrivacyRegistry.json")
    }

    public static func databaseURL(fileManager: FileManager = .default) -> URL {
        supportDirectory(fileManager: fileManager).appendingPathComponent(databaseFileName)
    }
}

public extension AttacheAppSupport {
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Development"
    }

    static var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "local"
    }
}
