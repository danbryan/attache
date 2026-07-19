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
        self.codexHome = codexHome ?? CodexPaths.home()
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
        // The desktop index already owns the user-visible title for nearly all
        // Codex sessions. Read only enough of those files to capture session
        // metadata; the background FTS pass streams searchable turns later.
        // Sessions without an indexed title still get the larger prefix so a
        // first-user-message fallback can be derived.
        let parsed = Self.readSessionFile(
            file.url,
            contentCap: indexTitle == nil ? contentCap : 0,
            byteCap: indexTitle == nil ? 262_144 : 16_384
        )
        let title = indexTitle ?? parsed.firstUserMessage ?? "Session \(file.id.prefix(8))"
        // No localModelHint for Codex (INF-398): the rollout data the scanner
        // reads (session_meta.cwd, response_item message turns) carries no model
        // identity, and Codex's own transcript records none on the lines this
        // scanner parses. Absent an evidence field, the honest choice is to skip
        // rather than invent one. Wire it here through
        // LocalModelHint.classify(providerID:modelID:) if a model field is ever
        // confirmed on real Codex rollout data.
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
        let turns = AttacheSessionReader.parseTurns(fromJSONL: text)
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
        let home = claudeHome ?? ClaudePaths.home()
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
        // Title precedence: an explicit CLI rename (`customTitle`) is the
        // user's most recent intent, so it wins over everything, including
        // the desktop sidebar title. Below that, desktop title still beats
        // the generated `aiTitle`, which beats the cleaned first prompt
        // (INF-368 Part A).
        let title = parsed.customTitle
            ?? desktopTitles[file.id]
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
            sourceKind: .claudeCode,
            localModelHint: parsed.localModelHint
        )
    }

    public func refreshMetadata(_ record: SessionRecord, for file: ScannedFile) -> SessionRecord {
        var refreshed = record
        refreshed.updatedAt = Date(timeIntervalSince1970: file.mtime)
        refreshed.sourceKind = .claudeCode
        // Tail-aware rename pickup: a CLI rename (`customTitle`) is appended
        // mid-session, far past `readSessionFile`'s 256KiB head-window read
        // that produced this record, so scan just the last 64KiB instead of
        // re-reading the whole file. A rename beats the desktop sidebar name
        // too (it is the user's most recent explicit intent), matching
        // `makeRecord`'s precedence (INF-368 Part A).
        let tailCustomTitle = Self.tailCustomTitle(url: file.url)
        // Desktop titles can appear or change without the transcript's mtime
        // moving, and cached records may predate the markup cleanup; keep the
        // displayed name in sync either way.
        if let tailCustomTitle {
            refreshed.title = tailCustomTitle
        } else if let desktopTitle = desktopTitles[file.id] {
            refreshed.title = desktopTitle
        } else if refreshed.title.contains("<command-name>") || refreshed.title.contains("<local-command-caveat>") {
            refreshed.title = SessionDigest.title(from: refreshed.title)
        }
        return refreshed
    }

    // MARK: Claude parsing (pure)

    /// Read a Claude Code session prefix and pull out the cwd, the generated title,
    /// the first user prompt, the last-seen CLI rename, the local-model hint,
    /// and a lowercased content digest.
    static func readSessionFile(_ url: URL, contentCap: Int, byteCap: Int = 262_144) -> (project: String?, content: String, title: String?, firstUserMessage: String?, customTitle: String?, localModelHint: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, "", nil, nil, nil, nil) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: byteCap)) ?? Data()
        guard !data.isEmpty else { return (nil, "", nil, nil, nil, nil) }
        let text = String(decoding: data, as: UTF8.self)
        return parse(jsonl: text, contentCap: contentCap)
    }

    public static func parse(jsonl text: String, contentCap: Int) -> (project: String?, content: String, title: String?, firstUserMessage: String?, customTitle: String?, localModelHint: String?) {
        var project: String?
        var aiTitle: String?
        var firstUser: String?
        // The CLI persists a rename (Command-K "Rename" or `/rename`) as its
        // own JSONL record (verified shape: type/sessionId/customTitle), not
        // as a field on the session-meta or message lines. Track the LAST
        // one seen so a later rename supersedes an earlier one (INF-368 Part A).
        var customTitle: String?
        var modelHint: String?
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
            if let renamed = (object["customTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !renamed.isEmpty {
                customTitle = renamed
            }
            let type = object["type"] as? String
            if modelHint == nil, type == "assistant",
               let message = object["message"] as? [String: Any],
               let modelID = message["model"] as? String {
                modelHint = localModelHint(forModelID: modelID)
            }
            guard type == "user" || type == "assistant",
                  let text = messageText(in: object["message"]) else {
                continue
            }
            if type == "user", firstUser == nil { firstUser = SessionDigest.title(from: text) }
            parts.append(text)
        }
        var content = parts.joined(separator: " ").lowercased()
        if content.count > contentCap { content = String(content.prefix(contentCap)) }
        return (project, content, aiTitle, firstUser, customTitle, modelHint)
    }

    /// Scans the last `byteCap` bytes of a session file for `customTitle`
    /// records, returning the LAST one found. This is how a mid-session
    /// rename surfaces on refresh without re-reading the whole (potentially
    /// 100MB+) file (INF-368 Part A).
    static func tailCustomTitle(url: URL, byteCap: Int = 65_536) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(byteCap) ? size - UInt64(byteCap) : 0
        do {
            try handle.seek(toOffset: start)
        } catch {
            return nil
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        var customTitle: String?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let renamed = (object["customTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !renamed.isEmpty else { continue }
            customTitle = renamed
        }
        return customTitle
    }

    /// Pure detection of a "this is a local, non-Anthropic model" marker from a
    /// Claude Code assistant record's `message.model` field (confirmed present
    /// on real `~/.claude` session records, INF-363). A normal cloud Claude
    /// Code session carries a `claude-*` model id (e.g. `claude-sonnet-5`,
    /// `claude-3-5-sonnet-20241022`). Dan's `claude-oss` wrapper points the
    /// real `claude` CLI at a local Ollama endpoint by setting
    /// `ANTHROPIC_BASE_URL`; Ollama echoes back its own served model tag (e.g.
    /// `qwen2.5-coder:32b`, `glm-4`) in that same field rather than a Claude
    /// model id, which is what this function keys on. Absent field, or a
    /// `claude-*` id, yields nil (cloud session, no badge). Any other
    /// non-empty tag is treated as local-model evidence and returned verbatim
    /// so the UI can show it as a tooltip.
    ///
    /// False-positive risk: a hypothetical future Anthropic-hosted model
    /// whose id does not start with `claude` would be misclassified as local.
    /// No such id exists today; if one ships, this allowlist should grow.
    public static func localModelHint(forModelID modelID: String?) -> String? {
        // Claude Code reports a model id but no provider id, so classify on the
        // model-id-only axis. The shared classifier preserves this scanner's
        // original claude-prefix behavior byte-for-byte (INF-398).
        LocalModelHint.classify(providerID: nil, modelID: modelID)
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

// MARK: - Grok Build

/// Grok Build writes one directory per session under
/// `~/.grok/sessions/<percent-encoded-project-path>/<session-uuid>/`, holding
/// `chat_history.jsonl` (the narratable transcript), `events.jsonl`,
/// `hunk_records.jsonl`, `plan.md`, `plan_mode.json`, and `images/` (verified
/// on real sessions on this Mac, INF-361). There is no separate archived
/// directory or session-title index like Codex's; the title comes from the
/// session's own content (`plan.md`'s first heading, else the first user
/// prompt), and the project cwd comes from percent-decoding the parent
/// directory name rather than a `cwd` field on any transcript line (Grok's
/// chat_history.jsonl records carry none).
public final class GrokBuildSessionScanner: SessionScanner {
    public let kind: SourceKind = .grokBuild
    private let sessionsDirectory: URL

    public init(grokHome: URL? = nil) {
        let home = grokHome ?? GrokPaths.home()
        self.sessionsDirectory = home.appendingPathComponent("sessions", isDirectory: true)
    }

    public func beginScan() {}

    public func enumerateFiles() -> [ScannedFile] {
        let fileManager = FileManager.default
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: sessionsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [ScannedFile] = []
        for projectDir in projectDirs {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: projectDir.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            guard let sessionDirs = try? fileManager.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for sessionDir in sessionDirs {
                guard fileManager.fileExists(atPath: sessionDir.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                let chatHistory = sessionDir.appendingPathComponent("chat_history.jsonl")
                guard fileManager.fileExists(atPath: chatHistory.path) else { continue }
                let id = sessionDir.lastPathComponent.lowercased()
                let mtime = (try? chatHistory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
                    .timeIntervalSince1970 ?? 0
                files.append(ScannedFile(id: id, url: chatHistory, mtime: mtime, archived: false))
            }
        }
        return files
    }

    public func makeRecord(for file: ScannedFile, priorTopicTag: String?, contentCap: Int) -> SessionRecord {
        let sessionDir = file.url.deletingLastPathComponent()
        let project = Self.decodedProject(fromSessionDirectory: sessionDir)
        let parsed = Self.readSessionFile(file.url, contentCap: contentCap)
        let title = Self.planTitle(inSessionDirectory: sessionDir)
            ?? parsed.firstUserMessage
            ?? "Session \(file.id.prefix(8))"
        // No localModelHint for Grok Build (INF-398): chat_history.jsonl records
        // carry no model field (nor even a cwd), and Grok sessions are always
        // xAI cloud models today. Absent an evidence field there is nothing to
        // classify, so skip rather than invent. Wire it here through
        // LocalModelHint.classify if a model field ever appears in Grok data.
        return SessionRecord(
            id: file.id,
            title: title,
            project: project,
            threadName: nil,
            updatedAt: Date(timeIntervalSince1970: file.mtime),
            archived: file.archived,
            filePath: file.url.path,
            fileMtime: file.mtime,
            content: parsed.content,
            topicTag: priorTopicTag,
            sourceKind: .grokBuild
        )
    }

    public func refreshMetadata(_ record: SessionRecord, for file: ScannedFile) -> SessionRecord {
        var refreshed = record
        refreshed.updatedAt = Date(timeIntervalSince1970: file.mtime)
        refreshed.sourceKind = .grokBuild
        return refreshed
    }

    // MARK: Grok Build parsing (pure)

    /// The project directory name is a percent-encoded absolute path (e.g.
    /// `%2FUsers%2Fdanb` decodes to `/Users/danb`), verified against real
    /// sessions on this Mac. `removingPercentEncoding` handles spaces and
    /// non-ASCII the same way it decodes `%20`/`%C3%A9`, etc.
    public static func decodedProject(fromSessionDirectory sessionDirectory: URL) -> String? {
        let encodedProjectName = sessionDirectory.deletingLastPathComponent().lastPathComponent
        guard !encodedProjectName.isEmpty else { return nil }
        return encodedProjectName.removingPercentEncoding
    }

    /// `plan.md`'s first Markdown heading, if the session wrote one, else nil.
    static func planTitle(inSessionDirectory sessionDirectory: URL) -> String? {
        let planURL = sessionDirectory.appendingPathComponent("plan.md")
        guard let text = try? String(contentsOf: planURL, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let heading = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if !heading.isEmpty { return heading }
        }
        return nil
    }

    static func readSessionFile(_ url: URL, contentCap: Int, byteCap: Int = 262_144) -> (content: String, firstUserMessage: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ("", nil) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: byteCap)) ?? Data()
        guard !data.isEmpty else { return ("", nil) }
        let text = String(decoding: data, as: UTF8.self)
        return parse(jsonl: text, contentCap: contentCap)
    }

    public static func parse(jsonl text: String, contentCap: Int) -> (content: String, firstUserMessage: String?) {
        var firstUser: String?
        var parts: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else {
                continue
            }
            switch type {
            case "user":
                guard let blocks = object["content"] as? [[String: Any]] else { continue }
                let text = blocks
                    .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                guard !text.isEmpty else { continue }
                if firstUser == nil { firstUser = SessionDigest.title(from: text) }
                parts.append(text)
            case "assistant":
                guard let text = (object["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                parts.append(text)
            default:
                continue
            }
        }
        var content = parts.joined(separator: " ").lowercased()
        if content.count > contentCap { content = String(content.prefix(contentCap)) }
        return (content, firstUser)
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
        let text = strippedLocalCommandCaveat(text)
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

    /// Claude Code CLI wraps the first turn of a session that included a
    /// local (non-slash) command in a `<local-command-caveat>…</local-command-caveat>`
    /// envelope of boilerplate ("Caveat: The messages below were generated
    /// by…"). Strip that envelope BEFORE the command-name handling above so
    /// a title derives from the user's actual content, not the caveat text
    /// (INF-368 Part A). If the closing tag never appears (a truncated
    /// head-window read cut it off), treat everything from the open tag
    /// onward as boilerplate rather than showing it raw.
    private static func strippedLocalCommandCaveat(_ text: String) -> String {
        guard text.contains("<local-command-caveat>") else { return text }
        if let regex = try? NSRegularExpression(
            pattern: "<local-command-caveat>.*?</local-command-caveat>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            let range = NSRange(text.startIndex..., in: text)
            let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            if stripped != text {
                return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let openRange = text.range(of: "<local-command-caveat>") {
            return String(text[..<openRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Removes agent command markup from free text while keeping the
    /// surrounding prose. Unlike `cleanedCommandMarkup` this never collapses
    /// the text down to the command itself, so it is safe for multi-turn
    /// content like search snippets.
    public static func strippedTranscriptMarkup(_ text: String) -> String {
        guard text.contains("<command-") || text.contains("<local-command-") else { return text }
        return text
            .replacingOccurrences(
                of: #"</?(?:command-name|command-message|command-args|command-contents|local-command-stdout|local-command-stderr|local-command-caveat)>"#,
                with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
