import Foundation

/// One session file discovered on disk: enough to decide whether it changed since
/// the last scan before paying to parse it.
public struct ScannedFile {
    public let id: String
    public let url: URL
    public let mtime: Double
    public let archived: Bool
    public init(id: String, url: URL, mtime: Double, archived: Bool) {
        self.id = id
        self.url = url
        self.mtime = mtime
        self.archived = archived
    }
}

/// A per-tool adapter that knows where that tool stores sessions and how to read
/// one. The indexer owns the shared cache + incremental (by-mtime) bookkeeping and
/// merges every scanner's output into one searchable set; each scanner owns only
/// the format specifics, so adding a tool means adding a scanner, not touching the
/// index. `beginScan()` is called once per refresh to load any global title/recency
/// index cheaply before per-file work.
public protocol SessionScanner: AnyObject {
    var kind: SourceKind { get }
    func beginScan()
    func enumerateFiles() -> [ScannedFile]
    func makeRecord(for file: ScannedFile, priorTopicTag: String?, contentCap: Int) -> SessionRecord
    func refreshMetadata(_ record: SessionRecord, for file: ScannedFile) -> SessionRecord
}

// MARK: - Codex

/// Codex Desktop, the Codex CLI, and exec automations all write the same rollout
/// JSONL into ~/.codex/sessions (and archived_sessions); titles + recency come from
/// ~/.codex/session_index.jsonl.
public final class CodexSessionScanner: SessionScanner {
    public let kind: SourceKind = .codex
    private let codexHome: URL
    private var indexTitles: [String: (title: String?, updatedAt: Date)] = [:]
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(codexHome: URL? = nil) {
        self.codexHome = codexHome ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    public func beginScan() {
        indexTitles = loadSessionIndex()
    }

    public func enumerateFiles() -> [ScannedFile] {
        var files: [ScannedFile] = []
        for (dir, archived) in [("sessions", false), ("archived_sessions", true)] {
            let base = codexHome.appendingPathComponent(dir, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: base,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let id = Self.sessionID(fromFileName: url.lastPathComponent) else { continue }
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
                    .timeIntervalSince1970 ?? 0
                files.append(ScannedFile(id: id, url: url, mtime: mtime, archived: archived))
            }
        }
        return files
    }

    public func makeRecord(for file: ScannedFile, priorTopicTag: String?, contentCap: Int) -> SessionRecord {
        let meta = indexTitles[file.id]
        let indexTitle = meta?.title
        let parsed = Self.readSessionFile(file.url, contentCap: contentCap)
        let title = indexTitle ?? parsed.firstUserMessage ?? "Session \(file.id.prefix(8))"
        return SessionRecord(
            id: file.id,
            title: title,
            project: parsed.project,
            threadName: indexTitle,
            updatedAt: meta?.updatedAt ?? Date(timeIntervalSince1970: file.mtime),
            archived: file.archived,
            filePath: file.url.path,
            fileMtime: file.mtime,
            content: parsed.content,
            topicTag: priorTopicTag,
            sourceKind: .codex
        )
    }

    public func refreshMetadata(_ record: SessionRecord, for file: ScannedFile) -> SessionRecord {
        var refreshed = record
        let meta = indexTitles[file.id]
        refreshed.title = meta?.title ?? record.title
        refreshed.threadName = meta?.title
        refreshed.updatedAt = meta?.updatedAt ?? record.updatedAt
        refreshed.archived = file.archived
        refreshed.sourceKind = .codex
        return refreshed
    }

    // MARK: Codex parsing (pure)

    public static func sessionID(fromFileName name: String) -> String? {
        let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range, in: name) else {
            return nil
        }
        return String(name[range]).lowercased()
    }

    static func readSessionFile(_ url: URL, contentCap: Int, byteCap: Int = 262_144) -> (project: String?, content: String, firstUserMessage: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, "", nil) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: byteCap)) ?? Data()
        guard !data.isEmpty else { return (nil, "", nil) }
        let text = String(decoding: data, as: UTF8.self)

        let project = firstCWD(inJSONL: text)
        let turns = CompanionSessionReader.parseTurns(fromJSONL: text)
        let firstUser = turns.first(where: { $0.role == "user" }).map { SessionDigest.title(from: $0.text) }
        var content = turns.map { $0.text }.joined(separator: " ").lowercased()
        if content.count > contentCap { content = String(content.prefix(contentCap)) }
        return (project, content, firstUser)
    }

    public static func firstCWD(inJSONL text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline).prefix(40) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any],
                  let cwd = payload["cwd"] as? String else {
                continue
            }
            return cwd
        }
        return nil
    }

    private func loadSessionIndex() -> [String: (title: String?, updatedAt: Date)] {
        let url = codexHome.appendingPathComponent("session_index.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var index: [String: (title: String?, updatedAt: Date)] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = (object["id"] as? String)?.lowercased() else {
                continue
            }
            let raw = (object["thread_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (raw?.isEmpty == false) ? raw : nil
            let updatedAt = (object["updated_at"] as? String).flatMap { isoFormatter.date(from: $0) }
                ?? ISO8601DateFormatter().date(from: (object["updated_at"] as? String) ?? "")
            index[id] = (title, updatedAt ?? Date(timeIntervalSince1970: 0))
        }
        return index
    }
}

// MARK: - Claude Code

/// Claude Code (CLI, and the agent sessions embedded in Claude Desktop) writes one
/// JSONL per session under ~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl.
/// Each line carries `cwd`, the message, and a timestamp; a generated title arrives
/// on an `ai-title` line. We read the cwd straight out of the file (the folder name
/// is a lossy encoding of it), so Attaché's own working directory never matters.
public final class ClaudeCodeSessionScanner: SessionScanner {
    /// Desktop app sidebar titles, refreshed once per scan pass.
    private var desktopTitles: [String: String] = [:]

    public let kind: SourceKind = .claudeCode
    private let projectsDirectory: URL

    public init(claudeHome: URL? = nil) {
        let home = claudeHome ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        self.projectsDirectory = home.appendingPathComponent("projects", isDirectory: true)
    }

    public func beginScan() {
        desktopTitles = ClaudeDesktopSessionTitles.load()
    }

    public func enumerateFiles() -> [ScannedFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [ScannedFile] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            // Skip subagent sidechain transcripts (9:1 of real Claude data). They're
            // not attachable sessions, narrate nothing, and would pollute the index
            // and topic-tagging spend (INF-168).
            if Self.isSubagentTranscript(url) { continue }
            let id = url.deletingPathExtension().lastPathComponent.lowercased()
            guard !id.isEmpty else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
                .timeIntervalSince1970 ?? 0
            files.append(ScannedFile(id: id, url: url, mtime: mtime, archived: false))
        }
        return files
    }

    /// True for Claude Code subagent sidechain files: `<session>/subagents/agent-*.jsonl`.
    public static func isSubagentTranscript(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name.hasPrefix("agent-") { return true }
        return url.pathComponents.contains { $0.lowercased() == "subagents" }
    }

    public func makeRecord(for file: ScannedFile, priorTopicTag: String?, contentCap: Int) -> SessionRecord {
        let parsed = Self.readSessionFile(file.url, contentCap: contentCap)
        // Prefer the name the user sees in the Claude app, then the
        // transcript's own title, then the (markup-cleaned) first prompt.
        let title = desktopTitles[file.id]
            ?? parsed.title
            ?? parsed.firstUserMessage
            ?? "Session \(file.id.prefix(8))"
        return SessionRecord(
            id: file.id,
            title: title,
            project: parsed.project,
            threadName: nil,   // Claude continuation chains are detected later, not by a shared name
            updatedAt: Date(timeIntervalSince1970: file.mtime),
            archived: file.archived,
            filePath: file.url.path,
            fileMtime: file.mtime,
            content: parsed.content,
            topicTag: priorTopicTag,
            sourceKind: .claudeCode
        )
    }

    public func refreshMetadata(_ record: SessionRecord, for file: ScannedFile) -> SessionRecord {
        var refreshed = record
        refreshed.updatedAt = Date(timeIntervalSince1970: file.mtime)
        refreshed.sourceKind = .claudeCode
        // Desktop titles can appear or change without the transcript's mtime
        // moving, and cached records may predate the markup cleanup; keep the
        // displayed name in sync either way.
        if let desktopTitle = desktopTitles[file.id] {
            refreshed.title = desktopTitle
        } else if refreshed.title.contains("<command-name>") {
            refreshed.title = SessionDigest.title(from: refreshed.title)
        }
        return refreshed
    }

    // MARK: Claude parsing (pure)

    /// Read a Claude Code session prefix and pull out the cwd, the generated title,
    /// the first user prompt, and a lowercased content digest.
    static func readSessionFile(_ url: URL, contentCap: Int, byteCap: Int = 262_144) -> (project: String?, content: String, title: String?, firstUserMessage: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, "", nil, nil) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: byteCap)) ?? Data()
        guard !data.isEmpty else { return (nil, "", nil, nil) }
        let text = String(decoding: data, as: UTF8.self)
        return parse(jsonl: text, contentCap: contentCap)
    }

    public static func parse(jsonl text: String, contentCap: Int) -> (project: String?, content: String, title: String?, firstUserMessage: String?) {
        var project: String?
        var aiTitle: String?
        var firstUser: String?
        var parts: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if project == nil, let cwd = object["cwd"] as? String, !cwd.isEmpty {
                project = cwd
            }
            if aiTitle == nil, let title = (object["aiTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                aiTitle = title
            }
            let type = object["type"] as? String
            guard type == "user" || type == "assistant",
                  let text = messageText(in: object["message"]) else {
                continue
            }
            if type == "user", firstUser == nil { firstUser = SessionDigest.title(from: text) }
            parts.append(text)
        }
        var content = parts.joined(separator: " ").lowercased()
        if content.count > contentCap { content = String(content.prefix(contentCap)) }
        return (project, content, aiTitle, firstUser)
    }

    /// Extract readable text from a Claude `message` (content is a string for user
    /// turns, a block list of {type:text/thinking/tool_use} for assistant turns).
    private static func messageText(in message: Any?) -> String? {
        guard let message = message as? [String: Any] else { return nil }
        if let text = message["content"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text", let t = block["text"] as? String else { return nil }
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }
}

// MARK: - Shared

public enum SessionDigest {
    /// A short, single-line title derived from a message (the first user prompt).
    public static func title(from text: String, limit: Int = 64) -> String {
        let oneLine = cleanedCommandMarkup(text)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > limit else { return oneLine }
        return String(oneLine.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Claude Code records slash-command turns as markup like
    /// `<command-name>/goal</command-name><command-message>goal</command-message>
    /// <command-args>Work ticket…</command-args>`. Render those as the command
    /// followed by its arguments so titles read like what the user typed.
    public static func cleanedCommandMarkup(_ text: String) -> String {
        guard text.contains("<command-name>") else { return text }
        func capture(_ tag: String) -> String? {
            guard let regex = try? NSRegularExpression(
                pattern: "<\(tag)>(.*?)</\(tag)>",
                options: [.dotMatchesLineSeparators, .caseInsensitive]),
                let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                let range = Range(match.range(at: 1), in: text) else { return nil }
            let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        let name = capture("command-name") ?? ""
        let args = capture("command-args") ?? ""
        let joined = [name, args].filter { !$0.isEmpty }.joined(separator: " ")
        if !joined.isEmpty { return joined }
        // Unknown markup shape: strip tags rather than showing them raw.
        return text.replacingOccurrences(of: #"</?[a-z-]+>"#, with: " ", options: .regularExpression)
    }

    /// Removes agent command markup from free text while keeping the
    /// surrounding prose. Unlike `cleanedCommandMarkup` this never collapses
    /// the text down to the command itself, so it is safe for multi-turn
    /// content like search snippets.
    public static func strippedTranscriptMarkup(_ text: String) -> String {
        guard text.contains("<command-") || text.contains("<local-command-") else { return text }
        return text
            .replacingOccurrences(
                of: #"</?(?:command-name|command-message|command-args|command-contents|local-command-stdout|local-command-stderr)>"#,
                with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
