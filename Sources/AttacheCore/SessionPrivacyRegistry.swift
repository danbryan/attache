import Foundation

/// Persisted set of session ids marked "do not record" (INF-357). A session in
/// this registry gets no new cards, no FTS index rows, no session-map entries,
/// and no direct-chat capsules while it remains disabled: live narration and
/// the character's activity reactions keep working, but nothing is written.
///
/// Stays pure and testable like `CardStore`/`SessionFTSIndex`/`SessionIndexer`:
/// callers resolve the on-disk location (normally
/// `AttacheAppSupport.sessionPrivacyRegistryURL()`) and pass it in, rather than
/// this type resolving Application Support itself.
///
/// The backing file is JSON, versioned via `schemaVersion`, and kept at file
/// permissions 0600 inside a 0700 directory using the same pre-create-then-
/// write-then-verify technique as `SessionIndexer`'s cache: a direct
/// (non-atomic) write onto a pre-created 0600 inode, so a transient atomic-swap
/// window can never inherit a permissive process umask. Any failure to encode,
/// write, or verify removes the file rather than risk leaving a partially
/// written or loosely permissioned copy behind.
public struct SessionPrivacyRegistry {
    /// On-disk shape. `schemaVersion` lets a future format change be detected;
    /// today there is nothing to migrate, so an unknown/older version is
    /// treated conservatively (accepted, then rewritten at the current
    /// version on next save) rather than discarded.
    private struct File: Codable {
        var schemaVersion: Int
        var disabledSessionIDs: [String]
    }

    public static let currentSchemaVersion = 1

    private let fileURL: URL
    private let fileManager: FileManager
    private var disabledSessionIDs: Set<String>

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.disabledSessionIDs = Self.load(fileURL: fileURL, fileManager: fileManager)
    }

    /// Pure, disk-free lookup: safe to call on every persisted event.
    public func isRecordingDisabled(sessionID: String) -> Bool {
        !sessionID.isEmpty && disabledSessionIDs.contains(sessionID)
    }

    /// All session ids currently marked "do not record".
    public var allDisabledSessionIDs: Set<String> {
        disabledSessionIDs
    }

    /// Marks `sessionID` "do not record". No-op (and no disk write) if already
    /// disabled. Returns whether the registry's on-disk state is consistent
    /// with the in-memory state afterward.
    @discardableResult
    public mutating func setRecordingDisabled(sessionID: String) -> Bool {
        guard !sessionID.isEmpty else { return true }
        guard disabledSessionIDs.insert(sessionID).inserted else { return true }
        guard save() else {
            disabledSessionIDs.remove(sessionID)
            return false
        }
        return true
    }

    /// Resumes normal persistence for `sessionID`. This only affects NEW
    /// events going forward; it never restores anything previously skipped
    /// while the session was disabled.
    @discardableResult
    public mutating func clearRecordingDisabled(sessionID: String) -> Bool {
        guard !sessionID.isEmpty else { return true }
        guard disabledSessionIDs.remove(sessionID) != nil else { return true }
        guard save() else {
            disabledSessionIDs.insert(sessionID)
            return false
        }
        return true
    }

    // MARK: - Persistence

    @discardableResult
    private func save() -> Bool {
        let file = File(schemaVersion: Self.currentSchemaVersion, disabledSessionIDs: Array(disabledSessionIDs).sorted())
        guard let data = try? JSONEncoder().encode(file),
              secureFileForAccess(createIfMissing: true) else { return false }
        do {
            // The registry is small and rebuildable if corrupted. A direct
            // write keeps the pre-created inode at 0600 and avoids an
            // atomic-write replacement briefly inheriting a permissive
            // process umask (mirrors SessionIndexer.saveCache).
            try data.write(to: fileURL)
            guard secureFileForAccess(createIfMissing: false) else {
                try? fileManager.removeItem(at: fileURL)
                return false
            }
            return true
        } catch {
            // Never leave a partially written registry available to a later launch.
            try? fileManager.removeItem(at: fileURL)
            return false
        }
    }

    private static func load(fileURL: URL, fileManager: FileManager) -> Set<String> {
        // Harden a legacy/loosely-permissioned file before reading it, same
        // as SessionIndexer's cache load path.
        _ = secureFileForAccess(fileURL: fileURL, fileManager: fileManager, createIfMissing: false)
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return []
        }
        // Unknown/older schema versions are accepted as-is today (nothing to
        // migrate yet); the next save rewrites at currentSchemaVersion.
        return Set(file.disabledSessionIDs)
    }

    private func secureFileForAccess(createIfMissing: Bool) -> Bool {
        Self.secureFileForAccess(fileURL: fileURL, fileManager: fileManager, createIfMissing: createIfMissing)
    }

    /// Upgrades legacy file permissions before reading and creates new files
    /// with restrictive permissions before any private bytes are written.
    private static func secureFileForAccess(fileURL: URL, fileManager: FileManager, createIfMissing: Bool) -> Bool {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

            if fileManager.fileExists(atPath: fileURL.path) {
                let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { return false }
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            } else {
                guard createIfMissing else { return false }
                guard fileManager.createFile(
                    atPath: fileURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else { return false }
            }

            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            return attributes[.type] as? FileAttributeType == .typeRegular
                && permissions & 0o777 == 0o600
        } catch {
            return false
        }
    }
}
