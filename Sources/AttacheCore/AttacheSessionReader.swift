import Foundation

/// Reads more of a Codex session than the latest message: the full transcript
/// (user + assistant turns) and a listing of the working directory. This is the
/// data layer behind Attaché's "read more of the session" tool, so a voice
/// conversation can pull deeper context on demand instead of only the last reply.
public enum AttacheSessionReader {
    public struct Turn: Equatable {
        public var role: String   // "user" or "assistant"
        public var text: String

        public init(role: String, text: String) {
            self.role = role
            self.text = text
        }
    }

    /// The session transcript as readable text within `limit` characters. For a
    /// small session the whole thing is rendered; for a large one (hours-long,
    /// up to 144MB here) only the opening bytes and the most recent bytes are read
    /// via `FileHandle` (never the whole file), and the result is framed so the
    /// model knows the middle was omitted rather than assuming it has everything.
    /// Returns nil if no session file is found.
    public static func transcript(
        forSessionID id: String,
        limit: Int = 16_000,
        fileManager: FileManager = .default
    ) -> String? {
        guard let url = locateSessionFile(id: id, fileManager: fileManager) else {
            return nil
        }
        return transcript(fromFileURL: url, limit: limit, fileManager: fileManager)
    }

    /// Testable core of `transcript(forSessionID:)`: render a specific session file
    /// within `limit` characters, reading whole only when small and head+tail
    /// otherwise.
    static func transcript(
        fromFileURL url: URL,
        limit: Int = 16_000,
        fileManager: FileManager = .default
    ) -> String? {
        let fileSize = ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0

        // Small enough to read whole without a big allocation: render everything.
        if fileSize <= wholeReadByteCap {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let turns = parseTurns(fromJSONL: text)
            guard !turns.isEmpty else { return nil }
            let rendered = renderTurns(turns, startIndex: 1, total: turns.count)
            return clipToLast(rendered, limit: limit)
        }

        // Large: opening turns from the head bytes + recent turns from the tail
        // bytes, with an explicit gap so the model doesn't claim to have the middle.
        let headTurns = parseTurns(fromJSONL: readHead(url, bytes: headByteWindow))
        let tailTurns = parseTurns(fromJSONL: readTail(url, bytes: tailByteWindow))
        guard !headTurns.isEmpty || !tailTurns.isEmpty else { return nil }

        let headBudget = max(1_000, limit / 5)
        let tailBudget = max(1_000, limit - headBudget)
        var sections: [String] = []
        if !headTurns.isEmpty {
            let head = renderTurns(headTurns, startIndex: 1, total: nil)
            sections.append("[opening turns of the session]\n" + clipToFirst(head, limit: headBudget))
        }
        sections.append("[… middle of the session omitted (not read) …]")
        if !tailTurns.isEmpty {
            let tail = renderTurns(tailTurns, startIndex: nil, total: nil)
            sections.append("[most recent turns]\n" + clipToLastPlain(tail, limit: tailBudget))
        }
        return sections.joined(separator: "\n\n")
    }

    /// Sessions at or below this read whole; above it, head+tail only.
    private static let wholeReadByteCap = 512 * 1024
    private static let headByteWindow = 64 * 1024
    private static let tailByteWindow = 256 * 1024

    private static func renderTurns(_ turns: [Turn], startIndex: Int?, total: Int?) -> String {
        turns.enumerated().map { offset, turn in
            let label: String
            if let startIndex {
                let n = startIndex + offset
                label = total.map { "TURN \(n)/\($0) - \(turn.role.uppercased())" } ?? "TURN \(n) - \(turn.role.uppercased())"
            } else {
                label = turn.role.uppercased()
            }
            return "\(label): \(turn.text)"
        }.joined(separator: "\n\n")
    }

    /// Read the first `bytes` of a file via FileHandle (no whole-file allocation).
    private static func readHead(_ url: URL, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: bytes)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else {
            // A multibyte char may be split at the boundary; drop the trailing partial line.
            return dropPartialTrailingLine(String(decoding: data, as: UTF8.self))
        }
        return dropPartialTrailingLine(text)
    }

    /// Read the last `bytes` of a file via FileHandle, dropping the partial first line.
    private static func readTail(_ url: URL, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        // If we didn't start at the top, the first line is a partial; drop it.
        guard start > 0, let newline = text.firstIndex(where: \.isNewline) else { return text }
        return String(text[text.index(after: newline)...])
    }

    private static func dropPartialTrailingLine(_ text: String) -> String {
        guard let newline = text.lastIndex(where: \.isNewline) else { return text }
        return String(text[..<newline])
    }

    private static func clipToFirst(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]) + "\n[…]"
    }

    private static func clipToLastPlain(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let start = text.index(text.endIndex, offsetBy: -limit)
        return "[…]\n" + String(text[start...])
    }

    /// A page of the transcript starting at `startTurn` (1-indexed), up to
    /// `maxChars` of rendered text, labeled with absolute turn numbers and the
    /// total. Streams the file in chunks so memory stays flat even on a 144MB
    /// session; the model uses this to reach an arbitrary earlier turn within its
    /// round budget. Returns nil if no session file is found.
    public static func transcriptPage(
        forSessionID id: String,
        startTurn: Int,
        maxChars: Int = 12_000,
        fileManager: FileManager = .default
    ) -> String? {
        guard let url = locateSessionFile(id: id, fileManager: fileManager) else { return nil }
        return transcriptPage(fromFileURL: url, startTurn: startTurn, maxChars: maxChars)
    }

    static func transcriptPage(fromFileURL url: URL, startTurn: Int, maxChars: Int = 12_000) -> String? {
        let firstWanted = max(1, startTurn)
        var total = 0
        var collected: [(index: Int, turn: Turn)] = []
        var renderedChars = 0
        var stopCollecting = false
        streamTurns(fromFileURL: url) { index, turn in
            total = index
            if !stopCollecting, index >= firstWanted {
                let cost = turn.text.count + turn.role.count + 12
                if renderedChars + cost > maxChars, !collected.isEmpty {
                    stopCollecting = true
                } else {
                    collected.append((index, turn))
                    renderedChars += cost
                }
            }
            return true   // read to the end so `total` is exact
        }
        guard total > 0 else { return nil }
        if collected.isEmpty {
            return "This session has \(total) turns; there is no turn \(firstWanted)."
        }
        let body = collected.map { "TURN \($0.index)/\(total) - \($0.turn.role.uppercased()): \($0.turn.text)" }
            .joined(separator: "\n\n")
        let last = collected.last!.index
        let more = last < total ? "\n\n[continues; ask for start_turn \(last + 1) for more]" : ""
        return body + more
    }

    /// Search the whole session transcript for `query`, returning matching turn
    /// numbers with short snippets, to pair with paging. Streams the file, so it
    /// works on any size. Returns nil if no session file is found.
    public static func searchTranscript(
        forSessionID id: String,
        query: String,
        limit: Int = 8,
        fileManager: FileManager = .default
    ) -> String? {
        guard let url = locateSessionFile(id: id, fileManager: fileManager) else { return nil }
        return searchTranscript(fromFileURL: url, query: query, limit: limit)
    }

    static func searchTranscript(fromFileURL url: URL, query: String, limit: Int = 8) -> String? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return "Provide a search query." }
        var matches: [String] = []
        streamTurns(fromFileURL: url) { index, turn in
            if turn.text.lowercased().contains(needle) {
                matches.append("TURN \(index) - \(turn.role.uppercased()): \(snippet(turn.text, around: needle))")
            }
            return matches.count < limit   // stop once we have enough
        }
        if matches.isEmpty {
            return "No turns matched \"\(query)\". Try a different term, or read_session_transcript with a start_turn."
        }
        return matches.joined(separator: "\n\n")
    }

    /// A short window of text around the first occurrence of `needle`.
    private static func snippet(_ text: String, around needle: String, radius: Int = 120) -> String {
        let lower = text.lowercased()
        guard let range = lower.range(of: needle) else { return String(text.prefix(radius * 2)) }
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        let prefix = start > text.startIndex ? "…" : ""
        let suffix = end < text.endIndex ? "…" : ""
        return prefix + text[start..<end].replacingOccurrences(of: "\n", with: " ") + suffix
    }

    /// Enumerate every parsed user/assistant turn from a concrete transcript
    /// without first loading the JSONL file into memory. The URL must already
    /// have been resolved and authorized by the app layer; this function does
    /// not discover sessions or grant access on its own.
    @discardableResult
    public static func enumerateTurns(
        fromFileURL url: URL,
        handle: (Int, Turn) -> Bool
    ) -> Bool {
        streamLocatedTurns(fromFileURL: url) { index, turn, _, _ in
            handle(index, turn)
        }
    }

    /// Enumerate from an already opened descriptor. The app layer uses this
    /// overload after binding authorization to one O_NOFOLLOW/fstat-verified
    /// transcript inode, so parsing cannot reopen a swapped pathname. The
    /// caller retains ownership of the descriptor.
    @discardableResult
    public static func enumerateTurns(
        fromFileDescriptor descriptor: Int32,
        handle: (Int, Turn) -> Bool
    ) -> Bool {
        guard descriptor >= 0 else { return false }
        let fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            try fileHandle.seek(toOffset: 0)
        } catch {
            return false
        }
        return streamLocatedTurns(fileHandle: fileHandle) { index, turn, _, _ in
            handle(index, turn)
        }
    }

    /// Stream a session file's turns in order without holding the whole file:
    /// reads in chunks, parses complete lines, and calls `handle(index, turn)`.
    /// `handle` returns false to stop early (used by search).
    private static func streamTurns(fromFileURL url: URL, handle: (Int, Turn) -> Bool) {
        _ = enumerateTurns(fromFileURL: url, handle: handle)
    }

    /// Stream user/assistant turns together with the exact JSONL source-line
    /// byte range that produced each turn. The search index stores these raw
    /// locators instead of offsets into a normalized digest, so a later reader
    /// can re-open and validate the authoritative transcript line.
    @discardableResult
    static func streamLocatedTurns(
        fromFileURL url: URL,
        maxLineBytes: Int = 64 * 1024 * 1024,
        handle: (Int, Turn, Int, Int) -> Bool
    ) -> Bool {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fileHandle.close() }
        return streamLocatedTurns(
            fileHandle: fileHandle,
            maxLineBytes: maxLineBytes,
            handle: handle
        )
    }

    /// Descriptor-preserving streaming implementation shared by URL callers
    /// and the app's authorization-bound descriptor path.
    @discardableResult
    private static func streamLocatedTurns(
        fileHandle: FileHandle,
        maxLineBytes: Int = 64 * 1024 * 1024,
        handle: (Int, Turn, Int, Int) -> Bool
    ) -> Bool {
        var index = 0
        var pendingLine = Data()
        var currentLineLength = 0
        var currentLineByteOffset = 0
        var discardingOversizedLine = false
        let newline = UInt8(ascii: "\n")

        func appendSegment(_ segment: Data.SubSequence) {
            currentLineLength += segment.count
            guard !discardingOversizedLine else { return }
            guard pendingLine.count + segment.count <= maxLineBytes else {
                // A malformed or pathological single JSONL record must not
                // make session discovery consume unbounded memory. Keep
                // scanning to the next newline, then resume with later turns.
                pendingLine = Data()
                discardingOversizedLine = true
                return
            }
            pendingLine.append(contentsOf: segment)
        }

        func finishLine() -> Bool {
            defer {
                currentLineByteOffset += currentLineLength + 1
                currentLineLength = 0
                pendingLine = Data()
                discardingOversizedLine = false
            }
            guard !discardingOversizedLine,
                  let turn = turn(fromLine: pendingLine) else { return true }
            index += 1
            return handle(index, turn, currentLineByteOffset, currentLineLength)
        }

        while true {
            let chunk = (try? fileHandle.read(upToCount: 256 * 1024)) ?? Data()
            if chunk.isEmpty { break }
            var cursor = chunk.startIndex
            while cursor < chunk.endIndex {
                if let nl = chunk[cursor...].firstIndex(of: newline) {
                    appendSegment(chunk[cursor..<nl])
                    if !finishLine() { return true }
                    cursor = chunk.index(after: nl)
                } else {
                    appendSegment(chunk[cursor..<chunk.endIndex])
                    cursor = chunk.endIndex
                }
            }
        }
        if currentLineLength > 0,
           !discardingOversizedLine,
           let turn = turn(fromLine: pendingLine) {
            index += 1
            _ = handle(index, turn, currentLineByteOffset, currentLineLength)
        }
        return true
    }

    private static func turn(fromLine data: Data) -> Turn? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return codexTurn(from: object) ?? claudeTurn(from: object) ?? grokBuildTurn(from: object)
    }

    /// A shallow listing of the working directory so Attaché can see what
    /// exists before deciding what to read. Hidden entries are omitted.
    public static func workingDirectoryListing(
        path: String,
        limit: Int = 200,
        fileManager: FileManager = .default
    ) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let entries = try? fileManager.contentsOfDirectory(atPath: trimmed) else {
            return nil
        }
        let visible = entries.filter { !$0.hasPrefix(".") }.sorted()
        guard !visible.isEmpty else { return "(empty directory)" }
        let shown = visible.prefix(limit)
        var listing = shown.joined(separator: "\n")
        if visible.count > shown.count {
            listing += "\n… and \(visible.count - shown.count) more"
        }
        return listing
    }

    /// Read a file inside the working directory. `path` may be relative to
    /// `rootPath`; reads outside the root are refused so the tool can't wander the
    /// whole disk. Symlinks are resolved on both sides before the containment
    /// check, so a link inside the project (or a symlinked root like /tmp) can't
    /// redirect the read elsewhere. Files over `maxReadableFileBytes` are refused.
    /// Clipped to the first `limit` characters.
    public static func readFile(
        path: String,
        within rootPath: String,
        limit: Int = 12_000,
        fileManager: FileManager = .default
    ) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Canonicalize both sides: resolve symlinks first, then collapse any
        // remaining "." / ".." components, so containment is checked against
        // real filesystem locations rather than the lexical path.
        let root = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().standardizedFileURL
        let target = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed).resolvingSymlinksInPath().standardizedFileURL
            : root.appendingPathComponent(trimmed).resolvingSymlinksInPath().standardizedFileURL
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        if let size = (try? fileManager.attributesOfItem(atPath: target.path))?[.size] as? Int,
           size > maxReadableFileBytes {
            return nil
        }
        guard let text = try? String(contentsOf: target, encoding: .utf8) else {
            return nil
        }
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n[…file truncated…]"
    }

    /// Refuse to load files larger than this into memory for the read tool.
    private static let maxReadableFileBytes = 5_000_000

    // MARK: - Parsing (pure, testable)

    /// Parse a session `.jsonl` log into ordered user/assistant turns. Handles both
    /// the Codex rollout schema (`response_item` payloads) and the Claude Code schema
    /// (`user`/`assistant` lines with a `message`), so one reader serves both tools.
    public static func parseTurns(fromJSONL text: String) -> [Turn] {
        var turns: [Turn] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let turn = codexTurn(from: object) ?? claudeTurn(from: object) ?? grokBuildTurn(from: object) {
                turns.append(turn)
            }
        }
        return turns
    }

    /// Grok Build's `chat_history.jsonl` shape (INF-361/INF-370): `type` is
    /// `"user"`/`"assistant"` like Claude Code, but content sits directly on
    /// the record (`content`), not nested under a `message` key; assistant
    /// content is a plain string, user content is a typed block list. Tried
    /// last so a Claude Code line (which always has a `message` key) never
    /// falls through here.
    private static func grokBuildTurn(from object: [String: Any]) -> Turn? {
        guard let role = object["type"] as? String, role == "user" || role == "assistant" else {
            return nil
        }
        let text: String?
        if let string = object["content"] as? String {
            text = string
        } else if let blocks = object["content"] as? [[String: Any]] {
            let parts = blocks
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            text = parts.isEmpty ? nil : parts.joined(separator: "\n")
        } else {
            text = nil
        }
        guard let resolved = text?.trimmingCharacters(in: .whitespacesAndNewlines), !resolved.isEmpty else {
            return nil
        }
        return Turn(role: role, text: resolved)
    }

    private static func codexTurn(from object: [String: Any]) -> Turn? {
        guard object["type"] as? String == "response_item",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "message",
              let role = payload["role"] as? String,
              role == "user" || role == "assistant",
              let content = payload["content"] as? [[String: Any]] else {
            return nil
        }
        let parts = content
            .compactMap { ($0["text"] as? String) ?? ($0["output_text"] as? String) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return Turn(role: role, text: parts.joined(separator: "\n"))
    }

    private static func claudeTurn(from object: [String: Any]) -> Turn? {
        guard let role = object["type"] as? String,
              role == "user" || role == "assistant",
              let message = object["message"] as? [String: Any] else {
            return nil
        }
        let text: String?
        if let string = message["content"] as? String {
            text = string
        } else if let blocks = message["content"] as? [[String: Any]] {
            let parts = blocks
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            text = parts.isEmpty ? nil : parts.joined(separator: "\n")
        } else {
            text = nil
        }
        guard let resolved = text?.trimmingCharacters(in: .whitespacesAndNewlines), !resolved.isEmpty else {
            return nil
        }
        return Turn(role: role, text: resolved)
    }

    private static func clipToLast(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let start = text.index(text.endIndex, offsetBy: -limit)
        return "[…earlier transcript omitted…]\n\n" + String(text[start...])
    }

    /// Resolve the newest transcript file for a session across the Codex and
    /// Claude Code storage trees. Used by the two-way coordinator to check a
    /// session's activity and confirm it exists before delivering.
    public static func sessionFileURL(forSessionID id: String, fileManager: FileManager = .default) -> URL? {
        locateSessionFile(id: id, fileManager: fileManager)
    }

    private static func locateSessionFile(id: String, fileManager: FileManager) -> URL? {
        let codexHome = CodexPaths.home(fileManager: fileManager)
        let claudeHome = ClaudePaths.home(fileManager: fileManager)
        let directories = [
            codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexHome.appendingPathComponent("archived_sessions", isDirectory: true),
            claudeHome.appendingPathComponent("projects", isDirectory: true)
        ]
        var best: (url: URL, modified: Date)?
        for directory in directories {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl",
                      url.lastPathComponent.contains(id) else {
                    continue
                }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? Date(timeIntervalSince1970: 0)
                if best == nil || modified > best!.modified {
                    best = (url, modified)
                }
            }
        }
        return best?.url
    }
}
