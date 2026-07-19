import Foundation
import SQLite3

/// opencode stores every session as rows in one shared SQLite database at
/// `~/.local/share/opencode/opencode.db` (WAL mode; verified against real
/// sessions on this Mac, INF-362), not as one transcript file per session the
/// way Codex/Claude Code/Grok Build do. Tables sampled: `session` (id,
/// project_id, workspace_id, directory, title, time_created, time_updated,
/// time_archived, ...), `message` (id, session_id, time_created, data JSON
/// with role/finish/mode/...), `part` (id, message_id, session_id, data JSON
/// with type/text/...), `project`, `project_directory`, `workspace`. There is
/// no per-line timestamp/file to tail; change detection instead compares each
/// session's own `time_updated` column, which `SessionIndexer.refresh`
/// already treats as this scanner's `ScannedFile.mtime` (INF-362 step 3): a
/// session whose `time_updated` hasn't moved is skipped without a re-query,
/// giving the same incremental behavior `SessionIndexer` gets from a file
/// mtime, keyed per session even though every session shares one physical
/// `.db`/`-wal`/`-shm` file triplet.
public final class OpencodeSessionScanner: SessionScanner {
    public let kind: SourceKind = .opencode
    private let databaseURL: URL

    public init(opencodeDataHome: URL? = nil) {
        let home = opencodeDataHome ?? OpencodePaths.dataHome()
        self.databaseURL = home.appendingPathComponent("opencode.db")
    }

    public func beginScan() {}

    public func enumerateFiles() -> [ScannedFile] {
        guard let db = OpencodeReadOnlyDatabase(url: databaseURL) else { return [] }
        defer { db.close() }
        return db.sessionSummaries().map { summary in
            ScannedFile(id: summary.id, url: databaseURL, mtime: summary.timeUpdated, archived: summary.archived)
        }
    }

    public func makeRecord(for file: ScannedFile, priorTopicTag: String?, contentCap: Int) -> SessionRecord {
        guard let db = OpencodeReadOnlyDatabase(url: databaseURL) else {
            return fallbackRecord(for: file, priorTopicTag: priorTopicTag)
        }
        defer { db.close() }
        guard let summary = db.sessionSummary(id: file.id) else {
            return fallbackRecord(for: file, priorTopicTag: priorTopicTag)
        }
        let content = OpencodeTranscriptAdapter.searchDigest(
            forSessionID: file.id, database: db, contentCap: contentCap
        )
        return SessionRecord(
            id: summary.id,
            title: summary.title,
            project: summary.directory,
            threadName: summary.parentID,
            updatedAt: Date(timeIntervalSince1970: summary.timeUpdated),
            archived: summary.archived,
            filePath: databaseURL.path,
            fileMtime: summary.timeUpdated,
            content: content,
            topicTag: priorTopicTag,
            sourceKind: .opencode
        )
    }

    public func refreshMetadata(_ record: SessionRecord, for file: ScannedFile) -> SessionRecord {
        var refreshed = record
        refreshed.updatedAt = Date(timeIntervalSince1970: file.mtime)
        refreshed.fileMtime = file.mtime
        refreshed.archived = file.archived
        refreshed.sourceKind = .opencode
        return refreshed
    }

    private func fallbackRecord(for file: ScannedFile, priorTopicTag: String?) -> SessionRecord {
        SessionRecord(
            id: file.id,
            title: "Session \(file.id.prefix(8))",
            project: nil,
            threadName: nil,
            updatedAt: Date(timeIntervalSince1970: file.mtime),
            archived: file.archived,
            filePath: databaseURL.path,
            fileMtime: file.mtime,
            content: "",
            topicTag: priorTopicTag,
            sourceKind: .opencode
        )
    }
}

// MARK: - Transcript adapter

/// Materializes an opencode session's `message`/`part` rows into the same
/// `ParsedTranscriptRecord` shape `TranscriptParser.parse` produces for
/// JSONL sources, without a line parser: this converts query results
/// directly (INF-362 step 2). There is no text blob to hand to
/// `TranscriptParser`, so this is the SQLite-native replacement for that
/// seam, consumed the same way by anything downstream that coalesces
/// `ParsedTranscriptRecord` values into narration turns.
public enum OpencodeTranscriptAdapter {
    /// One opencode `message` row plus its ordered `part` rows, already
    /// decoded from JSON. Exposed so tests can build fixtures without a real
    /// database.
    public struct MessageRow: Sendable, Equatable {
        public let id: String
        public let role: String?
        /// Present on assistant messages once a turn completes (`"stop"`
        /// observed on real sessions). opencode carries no Codex-style
        /// `phase`, but `finish == "stop"` is an equally hard turn boundary.
        public let finish: String?
        public let timeCreated: Double
        public let parts: [PartRow]

        public init(id: String, role: String?, finish: String?, timeCreated: Double, parts: [PartRow]) {
            self.id = id
            self.role = role
            self.finish = finish
            self.timeCreated = timeCreated
            self.parts = parts
        }
    }

    public struct PartRow: Sendable, Equatable {
        public let type: String?
        public let text: String?

        public init(type: String?, text: String?) {
            self.type = type
            self.text = text
        }
    }

    /// The concatenated narratable (`text`-type) prose of one message's parts,
    /// the same shape `records(from:cwd:)` narrates and the two-way SQLite
    /// reply correlation returns for a completed assistant turn. Public so both
    /// `OpencodeReplyCorrelation` and the app-layer `OpencodeLiveWatcher`
    /// (INF-397) reuse the exact part-composition rules instead of re-deriving
    /// them.
    public static func narratableText(of message: MessageRow) -> String {
        concatenatedText(message.parts)
    }

    /// Converts ordered message rows into narration records: a real user
    /// message is a turn boundary (mirrors Claude/Grok's "real user message
    /// closes the previous turn"); an assistant message's concatenated
    /// `text`-type parts become prose, final only when `finish == "stop"`.
    /// Messages/parts carrying no narratable text (tool calls, reasoning,
    /// step markers) are skipped, never fatal, the same tolerance
    /// `TranscriptParser`'s line parsers apply to unknown record shapes.
    public static func records(from messages: [MessageRow], cwd: String?) -> [ParsedTranscriptRecord] {
        var records: [ParsedTranscriptRecord] = []
        for message in messages {
            let timestamp = Date(timeIntervalSince1970: message.timeCreated / 1000)
            switch message.role {
            case "user":
                if hasRealText(message.parts) {
                    records.append(.init(kind: .userTurnBoundary, timestamp: timestamp, cwd: cwd))
                }
            case "assistant":
                let text = concatenatedText(message.parts)
                guard !text.isEmpty else { continue }
                let isFinal = message.finish == "stop"
                records.append(.init(kind: .assistantProse(text: text, isFinal: isFinal), timestamp: timestamp, cwd: cwd))
            default:
                continue
            }
        }
        return records
    }

    private static func hasRealText(_ parts: [PartRow]) -> Bool {
        parts.contains { part in
            part.type == "text" && !(part.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func concatenatedText(_ parts: [PartRow]) -> String {
        parts
            .filter { $0.type == "text" }
            .compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// A lowercased, capped digest for the search index (mirrors
    /// `GrokBuildSessionScanner.parse`'s `content` shape): every user and
    /// assistant text part, joined and truncated to `contentCap`. Unlike
    /// `records(from:cwd:)`, which only narrates assistant prose (a user
    /// message is a turn boundary, not narratable text), the search digest
    /// wants the user's own words indexed too, so this walks the rows
    /// directly rather than routing through `ParsedTranscriptRecord`.
    static func searchDigest(forSessionID sessionID: String, database: OpencodeReadOnlyDatabase, contentCap: Int) -> String {
        let messages = database.messages(forSessionID: sessionID)
        let parts = messages.compactMap { message -> String? in
            guard message.role == "user" || message.role == "assistant" else { return nil }
            let text = concatenatedText(message.parts)
            return text.isEmpty ? nil : text
        }
        var content = parts.joined(separator: " ").lowercased()
        if content.count > contentCap { content = String(content.prefix(contentCap)) }
        return content
    }
}
