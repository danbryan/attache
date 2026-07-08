import AttacheCore
import Foundation

struct AgentActivityPhrase: Identifiable, Equatable {
    enum Source: String {
        case toolIntent
        case toolResult
        case editEvent
        case externalTool
    }

    var id: String { text }
    var text: String
    var weight: Double
    var source: Source
    var lastSeen: Date
}

final class SessionActivityWatcher {
    var onPhrases: (([AgentActivityPhrase]) -> Void)?

    private struct Signal {
        var text: String
        var source: AgentActivityPhrase.Source
        var weight: Double
        var timestamp: Date
    }

    private struct AccumulatedSignal {
        var text: String
        var source: AgentActivityPhrase.Source
        var score: Double
        var lastSeen: Date
    }

    private let sessionsDirectory: URL
    private let archivedSessionsDirectory: URL
    private let claudeProjectsDirectory: URL
    private var timer: Timer?
    private var sessions: [CodexSessionTarget] = []
    private var fileOffsets: [String: UInt64] = [:]
    private var pendingFragments: [String: String] = [:]
    private var locatedFileURLs: [String: URL] = [:]
    private var signalsByText: [String: AccumulatedSignal] = [:]
    private let tailByteCap: UInt64 = 160_000
    private let firstReadWindow: TimeInterval = 120
    private let phraseLifetime: TimeInterval = 36

    init(
        sessionsDirectory: URL? = nil,
        archivedSessionsDirectory: URL? = nil,
        claudeProjectsDirectory: URL? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = CodexPaths.home()
        self.sessionsDirectory = sessionsDirectory ?? codexHome
            .appendingPathComponent("sessions", isDirectory: true)
        self.archivedSessionsDirectory = archivedSessionsDirectory ?? codexHome
            .appendingPathComponent("archived_sessions", isDirectory: true)
        self.claudeProjectsDirectory = claudeProjectsDirectory ?? home
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    func watch(_ sessions: [CodexSessionTarget]) {
        let active = sessions.filter { $0.category == .activeSession }
        let previousIDs = Set(self.sessions.map(\.id))
        let nextIDs = Set(active.map(\.id))
        self.sessions = active
        fileOffsets = fileOffsets.filter { nextIDs.contains($0.key) }
        pendingFragments = pendingFragments.filter { nextIDs.contains($0.key) }
        locatedFileURLs = locatedFileURLs.filter { nextIDs.contains($0.key) }

        if previousIDs != nextIDs {
            signalsByText.removeAll()
            onPhrases?([])
        }

        guard !active.isEmpty else {
            stop()
            return
        }

        poll()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                self?.poll()
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sessions = []
        fileOffsets.removeAll()
        pendingFragments.removeAll()
        locatedFileURLs.removeAll()
        signalsByText.removeAll()
        onPhrases?([])
    }

    private func poll() {
        let now = Date()
        for session in sessions {
            pollSession(session, now: now)
        }
        prune(now: now)
        onPhrases?(phrases(now: now))
    }

    private func pollSession(_ session: CodexSessionTarget, now: Date) {
        guard let fileURL = locateSessionFile(id: session.id),
              let size = fileSize(fileURL) else {
            return
        }

        let previousOffset = fileOffsets[session.id]
        let firstRead = previousOffset == nil
        let offset: UInt64
        if let previousOffset, size >= previousOffset {
            offset = previousOffset
        } else {
            offset = size > tailByteCap ? size - tailByteCap : 0
            pendingFragments[session.id] = nil
        }

        guard let text = appendedText(
            in: fileURL,
            sessionID: session.id,
            from: offset,
            skipPartialPrefix: firstRead && offset > 0
        ), !text.isEmpty else {
            fileOffsets[session.id] = size
            return
        }
        fileOffsets[session.id] = size

        let sourceKind: SourceKind = fileURL.path.contains("/.claude/") ? .claudeCode : .codex
        let recentCutoff = firstRead ? now.addingTimeInterval(-firstReadWindow) : nil
        for signal in activitySignals(inText: text, sourceKind: sourceKind, recentCutoff: recentCutoff) {
            record(signal)
        }
    }

    private func activitySignals(inText text: String, sourceKind: SourceKind, recentCutoff: Date?) -> [Signal] {
        var signals: [Signal] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestamp = timestamp(in: object) else {
                continue
            }
            if let recentCutoff, timestamp < recentCutoff { continue }

            if sourceKind == .claudeCode || object["payload"] == nil {
                signals.append(contentsOf: claudeSignals(from: object, timestamp: timestamp))
            } else {
                signals.append(contentsOf: codexSignals(from: object, timestamp: timestamp))
            }
        }
        return signals
    }

    private func codexSignals(from object: [String: Any], timestamp: Date) -> [Signal] {
        guard let type = object["type"] as? String else { return [] }

        if type == "event_msg",
           let payload = object["payload"] as? [String: Any],
           let eventType = payload["type"] as? String {
            switch eventType {
            case "patch_apply_end":
                return [Signal(text: "editing files", source: .editEvent, weight: 0.65, timestamp: timestamp)]
            case "web_search_end":
                return [Signal(text: "searching web", source: .externalTool, weight: 1.0, timestamp: timestamp)]
            case "mcp_tool_call_end":
                return [Signal(text: externalPhrase(from: compactText(payload)) ?? "using connector", source: .externalTool, weight: 1.0, timestamp: timestamp)]
            default:
                return []
            }
        }

        guard type == "response_item",
              let payload = object["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String else {
            return []
        }

        switch payloadType {
        case "function_call", "custom_tool_call", "tool_search_call", "web_search_call":
            return intentSignals(from: payload, payloadType: payloadType, timestamp: timestamp)
        case "function_call_output", "custom_tool_call_output", "tool_search_output":
            let output = compactText(payload["output"] ?? payload["content"] ?? payload["result"])
            if let phrase = resultPhrase(from: output) {
                return [Signal(text: phrase, source: .toolResult, weight: 1.0, timestamp: timestamp)]
            }
            return []
        default:
            return []
        }
    }

    private func claudeSignals(from object: [String: Any], timestamp: Date) -> [Signal] {
        guard let message = object["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else {
            return []
        }

        var signals: [Signal] = []
        for block in blocks {
            switch block["type"] as? String {
            case "tool_use":
                signals.append(contentsOf: intentSignals(from: block, payloadType: "tool_use", timestamp: timestamp))
            case "tool_result":
                if let phrase = resultPhrase(from: compactText(block["content"])) {
                    signals.append(Signal(text: phrase, source: .toolResult, weight: 1.0, timestamp: timestamp))
                }
            default:
                continue
            }
        }
        return signals
    }

    private func intentSignals(from payload: [String: Any], payloadType: String, timestamp: Date) -> [Signal] {
        if payloadType == "web_search_call" {
            return [Signal(text: "searching web", source: .externalTool, weight: 1.0, timestamp: timestamp)]
        }
        if payloadType == "tool_search_call" {
            return [Signal(text: "finding tools", source: .externalTool, weight: 1.0, timestamp: timestamp)]
        }

        let name = (payload["name"] as? String)
            ?? (payload["tool_name"] as? String)
            ?? payloadType
        let argumentText = compactText(payload["arguments"] ?? payload["input"])
        let combined = "\(name) \(argumentText)".lowercased()

        if let external = externalPhrase(from: combined) {
            return [Signal(text: external, source: .externalTool, weight: 1.0, timestamp: timestamp)]
        }
        if payloadType == "custom_tool_call" || name == "apply_patch" {
            return [Signal(text: "editing files", source: .editEvent, weight: 0.65, timestamp: timestamp)]
        }
        if name == "write_stdin" {
            return [Signal(text: "continuing command", source: .toolIntent, weight: 1.0, timestamp: timestamp)]
        }
        if name == "view_image" {
            return [Signal(text: "viewing image", source: .toolIntent, weight: 1.0, timestamp: timestamp)]
        }

        let phrase = commandPhrase(from: combined) ?? toolNamePhrase(name)
        return [Signal(text: phrase, source: .toolIntent, weight: 1.0, timestamp: timestamp)]
    }

    private func commandPhrase(from text: String) -> String? {
        if text.contains("swift test") { return "running tests" }
        if text.contains("swift build") { return "building app" }
        if text.contains("package-app") { return "packaging app" }
        if text.contains("codesign") || text.contains("spctl") || text.contains("stapler") || text.contains("notarytool") || text.contains("shasum") {
            return "verifying release"
        }
        if text.contains("git diff") { return "reviewing diff" }
        if text.contains("git status") || text.contains("git log") || text.contains("git show") { return "checking git" }
        if text.contains("rg ") || text.contains("\"rg") { return "searching code" }
        if text.contains("sed -n") || text.contains("nl -ba") || text.contains("cat ") || text.contains("head ") || text.contains("tail ") {
            return "reading files"
        }
        if text.contains("find ") || text.contains("ls ") { return "scanning files" }
        if text.contains("open ") || text.contains("osascript") { return "launching app" }
        if text.contains("pgrep") || text.contains("pkill") { return "checking app" }
        if text.contains("curl ") { return "calling endpoint" }
        if text.contains("jq ") { return "parsing logs" }
        if text.contains("xcrun ") { return "checking tools" }
        return nil
    }

    private func externalPhrase(from text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("linear") || lower.contains("_list_issues") || lower.contains("_get_issue") || lower.contains("_save_issue") || lower.contains("_list_comments") {
            return "checking Linear"
        }
        if lower.contains("email") || lower.contains("gmail") || lower.contains("outlook") || lower.contains("_list_messages") || lower.contains("_move_email") || lower.contains("_create_draft") {
            return "checking email"
        }
        if lower.contains("qbo") || lower.contains("quickbooks") {
            return "checking QBO"
        }
        if lower.contains("coinbase") {
            return "checking Coinbase"
        }
        if lower.contains("drive") || lower.contains("docs") || lower.contains("sheets") || lower.contains("slides") {
            return "checking Drive"
        }
        if lower.contains("calendar") {
            return "checking calendar"
        }
        if lower.contains("slack") {
            return "checking Slack"
        }
        if lower.contains("zoom") {
            return "checking Zoom"
        }
        if lower.contains("web_search") || lower.contains("search_query") {
            return "searching web"
        }
        if lower.contains("tool_search") {
            return "finding tools"
        }
        return nil
    }

    private func toolNamePhrase(_ name: String) -> String {
        switch name {
        case "exec_command", "Bash":
            return "running command"
        case "Read":
            return "reading files"
        case "Write", "Edit", "MultiEdit":
            return "editing files"
        case "Agent":
            return "delegating work"
        case "TodoWrite", "update_plan":
            return "updating plan"
        case "load_workspace_dependencies":
            return "checking tools"
        default:
            return "using tool"
        }
    }

    private func resultPhrase(from output: String) -> String? {
        let lower = output.lowercased()
        if lower.isEmpty { return nil }
        if lower.contains("build complete") { return "build complete" }
        if lower.contains("test suite") && lower.contains("0 failures") { return "tests passed" }
        if lower.contains("process exited with code 0") { return "command passed" }
        if lower.contains("exited with code 1") || lower.contains("exited with code 2") || lower.contains("exited with code 127") {
            return "command failed"
        }
        if lower.contains("compile error") || lower.contains("jq: error") || lower.contains("error:") {
            return "error found"
        }
        if lower.contains("no such file") || lower.contains("file does not exist") {
            return "missing file"
        }
        if lower.contains("valid on disk") || lower.contains("satisfies its designated requirement") {
            return "signature valid"
        }
        if lower.contains("source=notarized developer id") || lower.contains("accepted") {
            return "gatekeeper accepted"
        }
        return nil
    }

    private func record(_ signal: Signal) {
        let text = normalizedPhrase(signal.text)
        guard !text.isEmpty else { return }
        var current = signalsByText[text] ?? AccumulatedSignal(
            text: text,
            source: signal.source,
            score: 0,
            lastSeen: signal.timestamp
        )
        current.source = signal.source
        current.score = min(6, current.score + signal.weight)
        current.lastSeen = max(current.lastSeen, signal.timestamp)
        signalsByText[text] = current
    }

    private func prune(now: Date) {
        signalsByText = signalsByText.filter { _, signal in
            now.timeIntervalSince(signal.lastSeen) <= phraseLifetime
        }
    }

    private func phrases(now: Date) -> [AgentActivityPhrase] {
        let ranked = signalsByText.values.compactMap { signal -> AgentActivityPhrase? in
            let age = max(0, now.timeIntervalSince(signal.lastSeen))
            guard age <= phraseLifetime else { return nil }
            let decay = max(0.18, 1.0 - (age / phraseLifetime))
            return AgentActivityPhrase(
                text: signal.text,
                weight: min(1.0, max(0.25, (signal.score / 4.0) * decay)),
                source: signal.source,
                lastSeen: signal.lastSeen
            )
        }
        return ranked.sorted {
            if $0.weight == $1.weight { return $0.lastSeen > $1.lastSeen }
            return $0.weight > $1.weight
        }
        .prefix(9)
        .map { $0 }
    }

    private func normalizedPhrase(_ value: String) -> String {
        let words = value
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(3)
        return words.joined(separator: " ")
    }

    private func appendedText(in fileURL: URL, sessionID: String, from offset: UInt64, skipPartialPrefix: Bool) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            guard var text = String(data: data, encoding: .utf8), !text.isEmpty else {
                return nil
            }
            if skipPartialPrefix, let newline = text.firstIndex(where: \.isNewline) {
                text = String(text[text.index(after: newline)...])
            }
            let combined = (pendingFragments[sessionID] ?? "") + text
            guard let last = combined.last else { return nil }
            if last.isNewline {
                pendingFragments[sessionID] = nil
                return combined
            }

            let lines = combined.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            guard let lastFragment = lines.last else {
                pendingFragments[sessionID] = combined
                return nil
            }
            pendingFragments[sessionID] = String(lastFragment)
            return lines.dropLast().map(String.init).joined(separator: "\n")
        } catch {
            return nil
        }
    }

    private func locateSessionFile(id: String) -> URL? {
        if let cached = locatedFileURLs[id],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        let located = findSessionFile(id: id, under: sessionsDirectory)
            ?? findSessionFile(id: id, under: archivedSessionsDirectory)
            ?? findSessionFile(id: id, under: claudeProjectsDirectory)
        locatedFileURLs[id] = located
        return located
    }

    private func findSessionFile(id: String, under directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var matches: [(url: URL, modified: Date)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl",
                  fileURL.lastPathComponent.contains(id) else {
                continue
            }
            let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date(timeIntervalSince1970: 0)
            matches.append((fileURL, modified))
        }
        return matches.sorted { $0.modified > $1.modified }.first?.url
    }

    private func fileSize(_ fileURL: URL) -> UInt64? {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? NSNumber {
            return size.uint64Value
        }
        if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return UInt64(size)
        }
        return nil
    }

    private func timestamp(in object: [String: Any]) -> Date? {
        guard let value = object["timestamp"] as? String else { return nil }
        return ActivityDateFormatters.fractional.date(from: value)
            ?? ActivityDateFormatters.whole.date(from: value)
    }

    private func compactText(_ value: Any?, limit: Int = 2_000) -> String {
        guard let value else { return "" }
        if let text = value as? String { return String(text.prefix(limit)) }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: []),
           let text = String(data: data, encoding: .utf8) {
            return String(text.prefix(limit))
        }
        return String(String(describing: value).prefix(limit))
    }
}

private enum ActivityDateFormatters {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
