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
        self.scanners = scanners ?? [CodexSessionScanner(), ClaudeCodeSessionScanner()]
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
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder.iso8601.decode([SessionRecord].self, from: data) else {
            return
        }
        records = Dictionary(uniqueKeysWithValues: cached.map { ($0.id, $0) })
    }

    private func saveCache() {
        guard let data = try? JSONEncoder.iso8601.encode(Array(records.values)) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL)
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
