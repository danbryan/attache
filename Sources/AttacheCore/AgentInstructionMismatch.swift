import Foundation

/// Structured outcome of validating a personality-declared `intended_agent`
/// argument (INF-246) against the frozen agent-send target before staging a
/// `stage_agent_instruction` tool call.
///
/// This exists to make the "no hidden phrase routing" decision of record
/// (AGENTS.md) executable: the model states its intent explicitly as a tool
/// argument, and the app's only job is to compare that declared intent
/// against the already-frozen target and refuse on mismatch. The app never
/// reroutes to a different target and never parses the user's English to
/// decide where to send something; `evaluate` below is a pure comparison of
/// two already-known values.
///
/// Absent `intended_agent` is not represented here: `evaluate` returns nil
/// for a nil/empty argument, and the caller (`AppModel.applyStageAgentInstructionTool`)
/// skips this check entirely in that case, so staging proceeds exactly as it
/// did before this ticket.
public struct AgentInstructionMismatch: Equatable {
    /// Kept separate from `ConversationFailureCategory` deliberately: that
    /// type classifies a *failed* conversation/personality LLM call (timeout,
    /// auth, rate limit, ...). A wrong-agent block is not a call failure - the
    /// call succeeded and the tool was invoked correctly - it is a deliberate
    /// safety refusal. A later ticket (C3) or the call UI can key off `status`
    /// instead of parsing `message`.
    public enum Status: Equatable {
        /// `intended_agent` names a source that IS currently watched, but it
        /// does not match the frozen target's source.
        case blockedWrongAgent
        /// `intended_agent` names a source with no watched session at all
        /// right now, so there is nothing the user could even focus.
        case blockedNoWatchedSession
        /// `intended_agent` did not decode to a recognized source
        /// ("codex" | "claude_code"). Failing closed rather than silently
        /// ignoring an unrecognized value, per the ticket's "fail closed" title.
        case blockedUnrecognizedAgent
    }

    public let status: Status
    /// Prose safe to relay to the user via the personality. Every case
    /// includes the literal phrase "No staging occurred." as a stable marker,
    /// in addition to `status`, for anything that still wants to check text.
    public let message: String

    public init(status: Status, message: String) {
        self.status = status
        self.message = message
    }

    /// Pure comparison: the declared intent vs. the frozen target's source and
    /// the set of currently watched sources. Returns nil when there is no
    /// mismatch (either `intendedAgent` is nil/empty, or it names the same
    /// source as `focusedSource`), so staging proceeds unchanged.
    public static func evaluate(
        intendedAgent: String?,
        focusedSource: SourceKind,
        focusedTitle: String,
        watchedSources: Set<SourceKind>
    ) -> AgentInstructionMismatch? {
        guard let raw = intendedAgent?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        guard SourceKind.liveAgentRawValues.contains(raw), let requested = SourceKind(rawValue: raw) else {
            return AgentInstructionMismatch(
                status: .blockedUnrecognizedAgent,
                message: "Attaché didn't recognize \"\(raw)\" as an agent to send to. No staging occurred. The focused session is \(focusedSource.displayName) (\(focusedTitle))."
            )
        }
        guard requested != focusedSource else { return nil }
        guard watchedSources.contains(requested) else {
            return AgentInstructionMismatch(
                status: .blockedNoWatchedSession,
                message: "No \(requested.displayName) sessions are currently being watched. No staging occurred."
            )
        }
        return AgentInstructionMismatch(
            status: .blockedWrongAgent,
            message: "The focused session is \(focusedSource.displayName) (\(focusedTitle)). No staging occurred. Ask the user to focus a \(requested.displayName) session, or to confirm sending to \(focusedSource.displayName)."
        )
    }
}
