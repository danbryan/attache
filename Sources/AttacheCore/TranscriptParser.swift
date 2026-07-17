import Foundation

/// Parses raw session JSONL (Claude Code or Codex) into the narration records the
/// coalescer consumes. Pure and side-effect free so it can be fixture-tested.
public enum TranscriptParser {
    public struct Result {
        public let records: [ParsedTranscriptRecord]
        /// The working directory in effect after the last parsed line, carried
        /// into the next chunk (Codex sets cwd on meta lines, Claude on each).
        public let cwd: String?
    }

    /// Parse a chunk of complete transcript lines. `carriedCWD` is the cwd left
    /// over from the previous chunk for this session.
    public static func parse(text: String, format: TranscriptFormat, carriedCWD: String?) -> Result {
        var cwd = carriedCWD
        var records: [ParsedTranscriptRecord] = []
        // Grok Build's chat_history.jsonl carries no per-line timestamp
        // (verified against real sessions on this Mac, INF-361 sampling
        // comment). A monotonically increasing synthetic timestamp anchored to
        // "now" preserves the line order the coalescer relies on even though
        // the absolute time is approximate; this only affects narration
        // ordering within one parsed chunk, never two-way correlation (which
        // uses transcript byte offsets, not timestamps).
        var syntheticIndex = 0

        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else {
                continue
            }

            let timestamp: Date
            if format == .grokBuild {
                timestamp = Date(timeIntervalSinceNow: TimeInterval(syntheticIndex) * 0.001)
                syntheticIndex += 1
            } else {
                guard let timestampText = object["timestamp"] as? String,
                      let parsed = parseDate(timestampText) else {
                    continue
                }
                timestamp = parsed
            }

            switch format {
            case .claude:
                parseClaudeLine(object, type: type, timestamp: timestamp, cwd: &cwd, into: &records)
            case .codex:
                parseCodexLine(object, type: type, timestamp: timestamp, cwd: &cwd, into: &records)
            case .grokBuild:
                parseGrokBuildLine(object, type: type, timestamp: timestamp, cwd: &cwd, into: &records)
            }
        }

        return Result(records: records, cwd: cwd)
    }

    // MARK: - Claude

    private static func parseClaudeLine(
        _ object: [String: Any],
        type: String,
        timestamp: Date,
        cwd: inout String?,
        into records: inout [ParsedTranscriptRecord]
    ) {
        // Claude lines carry cwd on every line and the message at top level (no
        // Codex `payload`).
        guard object["payload"] == nil else { return }
        if let lineCwd = object["cwd"] as? String, !lineCwd.isEmpty {
            cwd = lineCwd
        }
        // Sidechain (subagent) traffic is never the main narration.
        if object["isSidechain"] as? Bool == true { return }

        switch type {
        case "assistant":
            guard let text = claudeAssistantText(from: object["message"]),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            records.append(.init(kind: .assistantProse(text: text, isFinal: false), timestamp: timestamp, cwd: cwd))
        case "user":
            // A real user-typed message closes the previous turn; a user line that
            // only carries tool_result blocks does not.
            if isRealUserMessage(object["message"]) {
                records.append(.init(kind: .userTurnBoundary, timestamp: timestamp, cwd: cwd))
            }
        default:
            break
        }
    }

    /// Extract narratable prose from a Claude `message` (its `text` blocks),
    /// skipping thinking and tool-use blocks.
    static func claudeAssistantText(from message: Any?) -> String? {
        guard let message = message as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        let parts = blocks
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// True when a Claude `user` message is real typed input, not a tool result.
    /// Tool results are recorded as user-role messages whose content blocks are
    /// `tool_result`; those are not turn boundaries.
    private static func isRealUserMessage(_ message: Any?) -> Bool {
        guard let message = message as? [String: Any] else { return false }
        if message["content"] is String { return true }
        guard let blocks = message["content"] as? [[String: Any]] else { return false }
        let hasToolResult = blocks.contains { ($0["type"] as? String) == "tool_result" }
        return !hasToolResult
    }

    // MARK: - Codex

    private static func parseCodexLine(
        _ object: [String: Any],
        type: String,
        timestamp: Date,
        cwd: inout String?,
        into records: inout [ParsedTranscriptRecord]
    ) {
        guard let payload = object["payload"] as? [String: Any] else { return }

        if type == "session_meta" || type == "turn_context",
           let payloadCwd = payload["cwd"] as? String, !payloadCwd.isEmpty {
            cwd = payloadCwd
            return
        }

        guard type == "response_item", payload["type"] as? String == "message" else { return }
        let role = payload["role"] as? String

        if role == "user" {
            records.append(.init(kind: .userTurnBoundary, timestamp: timestamp, cwd: cwd))
            return
        }

        guard role == "assistant",
              let text = assistantText(from: payload),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // `final_answer` is a hard turn boundary. Any other phase, including a nil
        // phase from old-format logs, is an interstitial that coalesces (the old
        // code passed nil-phase straight through, which flooded).
        let phase = payload["phase"] as? String
        let isFinal = phase == "final_answer"
        // A non-final, explicitly-phased message that isn't prose we surface was
        // already excluded by the text check above; keep everything with prose.
        records.append(.init(kind: .assistantProse(text: text, isFinal: isFinal), timestamp: timestamp, cwd: cwd))
    }

    static func assistantText(from payload: [String: Any]) -> String? {
        guard let content = payload["content"] as? [[String: Any]] else { return nil }
        let parts = content.compactMap { item -> String? in
            if let text = item["text"] as? String { return text }
            if let text = item["output_text"] as? String { return text }
            return nil
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: - Grok Build

    /// Grok Build's `chat_history.jsonl` records (verified on real sessions,
    /// INF-361): `system` (skipped, not narratable), `user` (content is a
    /// `[{type, text}]` block list; a real typed prompt is a turn boundary),
    /// `assistant` (content is a plain string; always narratable prose - Grok
    /// exposes no Codex-style `phase`/`final_answer` marker, so every non-empty
    /// assistant line is treated as interstitial prose the same way Claude's
    /// is), and `tool_result` (content is a plain string of tool output, not
    /// narrated). Any other `type` value is skipped, never fatal.
    private static func parseGrokBuildLine(
        _ object: [String: Any],
        type: String,
        timestamp: Date,
        cwd: inout String?,
        into records: inout [ParsedTranscriptRecord]
    ) {
        switch type {
        case "assistant":
            guard let text = (object["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return
            }
            records.append(.init(kind: .assistantProse(text: text, isFinal: false), timestamp: timestamp, cwd: cwd))
        case "user":
            if grokBuildUserHasRealText(object["content"]) {
                records.append(.init(kind: .userTurnBoundary, timestamp: timestamp, cwd: cwd))
            }
        case "system", "tool_result":
            return
        default:
            return
        }
    }

    /// True when a Grok Build `user` record's content block list carries real
    /// typed text (`{type: "text", text: "..."}`), mirroring
    /// `isRealUserMessage`'s Claude equivalent.
    private static func grokBuildUserHasRealText(_ content: Any?) -> Bool {
        guard let blocks = content as? [[String: Any]] else { return false }
        return blocks.contains { block in
            guard block["type"] as? String == "text",
                  let text = block["text"] as? String else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Dates

    static func parseDate(_ value: String) -> Date? {
        ParserDateFormatters.fractional.date(from: value) ?? ParserDateFormatters.whole.date(from: value)
    }
}

private enum ParserDateFormatters {
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
