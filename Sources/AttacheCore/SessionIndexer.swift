import Foundation

/// Builds and maintains the in-memory session index across every configured tool.
/// The per-tool specifics live in `SessionScanner`s; this type owns the shared work:
/// a persisted cache, incremental refresh (re-parsing only files whose modification
/// time changed), tag write-back, and thread-safe access so a background refresh and
/// the tagging task can't race.
public final class SessionIndexer: @unchecked Sendable {
    private let cacheURL: URL
    private let scanners: [SessionScanner]
    private var records: [String: SessionRecord] = [:]
    private let lock = NSRecursiveLock()

    public init(cacheURL: URL, scanners: [SessionScanner]? = nil) {
        self.cacheURL = cacheURL
        // Registry-driven (INF-360): production is exactly Codex + Claude
        // Code, in that order, matching the scanner list this replaced.
        self.scanners = scanners ?? SessionSourceRegistry.production().descriptors.map { $0.makeScanner() }
        loadCache()
    }

    public var allRecords: [SessionRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(records.values)
    }

    /// Records still missing a topic tag, most-recent first, so background tagging
    /// labels what the user is most likely to see before working down the tail.
    public func untaggedRecords() -> [SessionRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.values
            .filter { ($0.topicTag ?? "").isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Write back topic tags (id → tag) produced by background tagging, persist the
    /// cache, and return the full updated record set.
    @discardableResult
    public func applyTags(_ tags: [String: String]) -> [SessionRecord] {
        lock.lock(); defer { lock.unlock() }
        for (id, tag) in tags {
            let clean = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, var record = records[id] else { continue }
            record.topicTag = clean
            records[id] = record
        }
        saveCache()
        return Array(records.values)
    }

    /// Re-scan every source and update the index. Returns the full record set.
    @discardableResult
    public func refresh(contentCap: Int = 8_000) -> [SessionRecord] {
        lock.lock(); defer { lock.unlock() }
        var seen = Set<String>()
        for scanner in scanners {
            scanner.beginScan()
            for file in scanner.enumerateFiles() {
                seen.insert(file.id)
                if let existing = records[file.id], existing.fileMtime == file.mtime, existing.sourceKind == scanner.kind {
                    records[file.id] = scanner.refreshMetadata(existing, for: file)
                } else {
                    records[file.id] = scanner.makeRecord(for: file, priorTopicTag: records[file.id]?.topicTag, contentCap: contentCap)
                }
            }
        }
        records = records.filter { seen.contains($0.key) }
        saveCache()
        return Array(records.values)
    }

    // MARK: - Cache

    private func loadCache() {
        guard secureCacheFileForAccess(createIfMissing: false),
              let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder.iso8601.decode([SessionRecord].self, from: data) else {
            return
        }
        let scrubbed = cached.map(Self.cacheRecord)
        records = Dictionary(uniqueKeysWithValues: scrubbed.map { ($0.id, $0) })
        if zip(cached, scrubbed).contains(where: { $0.content != $1.content }) {
            saveCache()
        }
    }

    private func saveCache() {
        let cacheRecords = records.values.map(Self.cacheRecord)
        guard let data = try? JSONEncoder.iso8601.encode(cacheRecords),
              secureCacheFileForAccess(createIfMissing: true) else { return }
        do {
            // The cache is rebuildable. A direct write keeps the pre-created
            // inode at 0600 and avoids an atomic-write replacement briefly
            // inheriting a permissive process umask.
            try data.write(to: cacheURL)
            guard secureCacheFileForAccess(createIfMissing: false) else {
                try? FileManager.default.removeItem(at: cacheURL)
                return
            }
        } catch {
            // Never leave a partial cache available to a later launch.
            try? FileManager.default.removeItem(at: cacheURL)
        }
    }

    /// Transcript excerpts belong in the private FTS database, not in a second
    /// JSON cache. Metadata and mtimes are sufficient for incremental scanning.
    private static func cacheRecord(_ record: SessionRecord) -> SessionRecord {
        var scrubbed = record
        scrubbed.content = ""
        return scrubbed
    }

    /// Upgrades legacy cache permissions before reading and creates new cache
    /// files with restrictive permissions before any private bytes are written.
    private func secureCacheFileForAccess(createIfMissing: Bool) -> Bool {
        let fileManager = FileManager.default
        let directory = cacheURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

            if fileManager.fileExists(atPath: cacheURL.path) {
                let attributes = try fileManager.attributesOfItem(atPath: cacheURL.path)
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { return false }
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
            } else {
                guard createIfMissing else { return false }
                guard fileManager.createFile(
                    atPath: cacheURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else { return false }
            }

            let attributes = try fileManager.attributesOfItem(atPath: cacheURL.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            return attributes[.type] as? FileAttributeType == .typeRegular
                && permissions & 0o777 == 0o600
        } catch {
            return false
        }
    }
}

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
