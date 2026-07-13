import Foundation

/// What a watched session needs from the user right now, derived purely from
/// the tail of its transcript.
///
/// The transcript is exact about some things and silent about others. A
/// pending AskUserQuestion or ExitPlanMode is an unambiguous "waiting on
/// you". A pending ordinary tool with a long quiet gap is ambiguous: it could
/// be an unanswered permission prompt (the CLI writes nothing while it waits)
/// or just a long build, so it is reported softly and only after a generous
/// threshold. Exact permission detection is available through the local event
/// bridge (a Claude Code Notification hook posting `needs_attention`).
public enum SessionAttentionState: Equatable, Sendable {
    /// Records are landing; the agent is working.
    case active
    /// The agent finished its turn; the ball is in the user's court.
    case turnComplete
    /// The agent explicitly asked the user something and is blocked on it.
    case awaitingAnswer
    /// A tool call has been pending with no output for a long time: either an
    /// unanswered permission prompt or a genuinely long task.
    case possiblyWaiting(quietSeconds: Int)
    /// The tail shows a recent error record.
    case erroredRecently
    /// Nothing pending and nothing recent.
    case quiet

    /// States that justify interrupting the user.
    public var needsUser: Bool {
        switch self {
        case .awaitingAnswer, .possiblyWaiting: return true
        default: return false
        }
    }

}

/// A classification plus the live sub-agent count (INF-275): how many
/// sub-agent tool calls are pending in the session's main chain right now.
public struct SessionAssessment: Equatable, Sendable {
    public var state: SessionAttentionState
    public var activeSubAgents: Int

    public init(state: SessionAttentionState, activeSubAgents: Int = 0) {
        self.state = state
        self.activeSubAgents = activeSubAgents
    }
}

public enum SessionAttentionClassifier {
    /// Tools whose pending call always means "waiting on the user".
    public static let blockingToolNames: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// Tools whose pending call means a sub-agent is running (Claude Code's
    /// delegation tools). Codex transcripts have no equivalent signal.
    public static let subAgentToolNames: Set<String> = ["Task", "Agent"]

    /// How recent the newest record must be for the session to read as active.
    public static let activeWindow: TimeInterval = 30
    /// How long assistant prose must sit unchallenged before the turn reads
    /// complete. Long generations pause a few seconds between records, so
    /// this cannot be instant, but it should not wait out `activeWindow`
    /// either: a finished turn showing as still working for half a minute
    /// reads as lag (INF-282).
    public static let turnSettleWindow: TimeInterval = 10
    /// How long a pending ordinary tool must sit quiet before it is even
    /// softly flagged. Builds and test suites routinely run for minutes.
    public static let pendingToolQuietThreshold: TimeInterval = 150
    /// Sessions with nothing newer than this are simply quiet.
    public static let staleWindow: TimeInterval = 30 * 60

    /// Classify from the tail lines of a session transcript. Pure; fixture-tested.
    public static func classify(
        tailLines: [String],
        format: TranscriptFormat,
        now: Date = Date()
    ) -> SessionAttentionState {
        assess(tailLines: tailLines, format: format, now: now).state
    }

    /// Classification plus the live sub-agent count, from one tail scan. A
    /// sub-agent is counted while its delegation tool call is pending and the
    /// session is still fresh; a stale or quiet session reports zero even if
    /// the transcript's last record left a call dangling.
    public static func assess(
        tailLines: [String],
        format: TranscriptFormat,
        now: Date = Date()
    ) -> SessionAssessment {
        var pendingTools: [String: (name: String, timestamp: Date)] = [:]
        var lastAssistantText: (text: String, timestamp: Date)?
        var lastRecordTimestamp: Date?
        var lastErrorTimestamp: Date?
        var lastRealUserTimestamp: Date?

        for line in tailLines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            guard let timestampText = object["timestamp"] as? String,
                  let timestamp = TranscriptParser.parseDate(timestampText) else {
                continue
            }
            lastRecordTimestamp = max(lastRecordTimestamp ?? .distantPast, timestamp)

            switch format {
            case .claude:
                scanClaude(object, timestamp: timestamp,
                           pendingTools: &pendingTools,
                           lastAssistantText: &lastAssistantText,
                           lastErrorTimestamp: &lastErrorTimestamp,
                           lastRealUserTimestamp: &lastRealUserTimestamp)
            case .codex:
                scanCodex(object, timestamp: timestamp,
                          pendingTools: &pendingTools,
                          lastAssistantText: &lastAssistantText,
                          lastRealUserTimestamp: &lastRealUserTimestamp)
            }
        }

        // Sub-agents only count while the session is fresh; a dangling
        // delegation call in a stale transcript is history, not activity.
        let subAgents = pendingTools.values.filter { subAgentToolNames.contains($0.name) }.count
        func result(_ state: SessionAttentionState) -> SessionAssessment {
            SessionAssessment(state: state, activeSubAgents: state == .quiet ? 0 : subAgents)
        }

        guard let newest = lastRecordTimestamp else { return result(.quiet) }
        let quiet = now.timeIntervalSince(newest)
        if quiet > staleWindow { return result(.quiet) }

        // A blocking ask pending resolution is exact, regardless of quiet time.
        if pendingTools.values.contains(where: { blockingToolNames.contains($0.name) }) {
            return result(.awaitingAnswer)
        }

        // A recent error with nothing newer on top of it.
        if let errorAt = lastErrorTimestamp, errorAt >= newest.addingTimeInterval(-1),
           now.timeIntervalSince(errorAt) < pendingToolQuietThreshold {
            return result(.erroredRecently)
        }

        // Ordinary pending tool: soft "possibly waiting" only after a long quiet.
        if let oldestPending = pendingTools.values.map(\.timestamp).min() {
            let pendingQuiet = now.timeIntervalSince(oldestPending)
            if quiet >= pendingToolQuietThreshold {
                return result(.possiblyWaiting(quietSeconds: Int(pendingQuiet)))
            }
            return result(.active)
        }

        // The user spoke last: the agent is (or should be) computing.
        if let userAt = lastRealUserTimestamp, userAt >= (lastAssistantText?.timestamp ?? .distantPast) {
            return result(quiet < activeWindow ? .active : .quiet)
        }

        // Assistant prose is the newest thing: turn is over once the stream
        // has clearly stopped. A trailing question is a direct ask.
        if let last = lastAssistantText {
            if quiet < turnSettleWindow { return result(.active) }
            if endsWithQuestion(last.text) { return result(.awaitingAnswer) }
            return result(.turnComplete)
        }

        return result(quiet < activeWindow ? .active : .quiet)
    }

    static func endsWithQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastSentenceEnd = trimmed.last else { return false }
        return lastSentenceEnd == "?"
    }

    // MARK: - Claude records

    private static func scanClaude(
        _ object: [String: Any],
        timestamp: Date,
        pendingTools: inout [String: (name: String, timestamp: Date)],
        lastAssistantText: inout (text: String, timestamp: Date)?,
        lastErrorTimestamp: inout Date?,
        lastRealUserTimestamp: inout Date?
    ) {
        if object["isSidechain"] as? Bool == true { return }
        switch object["type"] as? String {
        case "assistant":
            guard let message = object["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { return }
            for block in blocks {
                switch block["type"] as? String {
                case "tool_use":
                    if let id = block["id"] as? String {
                        pendingTools[id] = (block["name"] as? String ?? "", timestamp)
                    }
                case "text":
                    if let text = block["text"] as? String,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lastAssistantText = (text, timestamp)
                    }
                default:
                    break
                }
            }
        case "user":
            guard let message = object["message"] as? [String: Any] else { return }
            if let blocks = message["content"] as? [[String: Any]] {
                var sawToolResult = false
                for block in blocks where (block["type"] as? String) == "tool_result" {
                    sawToolResult = true
                    if let id = block["tool_use_id"] as? String {
                        pendingTools.removeValue(forKey: id)
                    }
                }
                if !sawToolResult { lastRealUserTimestamp = timestamp }
            } else if message["content"] is String {
                lastRealUserTimestamp = timestamp
            }
        case "system":
            if (object["subtype"] as? String) == "api_error" {
                lastErrorTimestamp = timestamp
            }
        default:
            break
        }
    }

    // MARK: - Codex records

    private static func scanCodex(
        _ object: [String: Any],
        timestamp: Date,
        pendingTools: inout [String: (name: String, timestamp: Date)],
        lastAssistantText: inout (text: String, timestamp: Date)?,
        lastRealUserTimestamp: inout Date?
    ) {
        guard let payload = object["payload"] as? [String: Any] else { return }
        switch payload["type"] as? String {
        case "function_call":
            if let id = (payload["call_id"] as? String) ?? (payload["id"] as? String) {
                pendingTools[id] = (payload["name"] as? String ?? "", timestamp)
            }
        case "function_call_output":
            if let id = payload["call_id"] as? String {
                pendingTools.removeValue(forKey: id)
            }
        case "message":
            let role = payload["role"] as? String
            if role == "user" {
                lastRealUserTimestamp = timestamp
            } else if role == "assistant",
                      let text = TranscriptParser.assistantText(from: payload) {
                lastAssistantText = (text, timestamp)
            }
        default:
            break
        }
    }
}
