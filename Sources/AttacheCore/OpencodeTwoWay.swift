import Foundation

/// SQLite-backed two-way primitives for opencode (INF-395). opencode stores
/// every session as rows in one shared database (`OpencodeReadOnlyDatabase`),
/// not one JSONL transcript file per session, so its delivery readiness and
/// positional reply correlation cannot reuse the byte-offset / `TranscriptFormat`
/// machinery the file sources (Codex, Claude Code, Grok Build) share
/// (`SessionDeliveryReadinessClassifier` / `SessionReplyCorrelation` in the App
/// layer). These pure functions replace that seam for opencode: they operate on
/// already-fetched `OpencodeTranscriptAdapter.MessageRow` values, so they are
/// unit-testable against fixture databases without a live `opencode` process.
///
/// `message.timeCreated` is opencode's own millisecond epoch (verified against
/// real sessions, INF-362): `OpencodeReadOnlyDatabase.messages(forSessionID:)`
/// returns it raw (unlike `sessionSummaries`, which divides by 1000). The
/// checkpoint cursor below is therefore an `Int64` of those milliseconds,
/// matching `Instruction.deliveryCheckpoint`'s existing `Int64` type (a byte
/// offset for the file sources; a message-time cursor for opencode).

/// One opencode session's delivery-relevant snapshot: its project directory
/// (working directory for the resume) and its ordered messages. `nil` from a
/// loader means the session row does not exist (the "session gone" signal),
/// distinct from a real session that simply has no messages yet.
public struct OpencodeSessionSnapshot: Sendable, Equatable {
    public let directory: String?
    public let messages: [OpencodeTranscriptAdapter.MessageRow]

    public init(directory: String?, messages: [OpencodeTranscriptAdapter.MessageRow]) {
        self.directory = directory
        self.messages = messages
    }

    /// Load a session's snapshot from an opencode database file. Returns `nil`
    /// when the database is missing/locked or the session row does not exist,
    /// so a caller can treat that as "no opencode session for this session
    /// yet" (capability) or "session gone" (delivery). Always read-only; never
    /// creates or writes the database.
    public static func load(sessionID: String, databaseURL: URL) -> OpencodeSessionSnapshot? {
        guard let database = OpencodeReadOnlyDatabase(url: databaseURL) else { return nil }
        defer { database.close() }
        guard let summary = database.sessionSummary(id: sessionID) else { return nil }
        return OpencodeSessionSnapshot(
            directory: summary.directory,
            messages: database.messages(forSessionID: sessionID)
        )
    }
}

/// Delivery readiness (idle-quiet, "COMPLETED assistant turn with no pending
/// tool parts") for opencode, the SQLite analog of the JSONL-oriented
/// `SessionDeliveryReadinessClassifier.turnIsComplete`. opencode marks a turn
/// finished with the assistant message's `finish == "stop"` (its only hard
/// turn boundary; it carries no Codex `phase == "final_answer"`), and it does
/// NOT set `finish` until the whole assistant turn, including every tool part,
/// has resolved. So a message-level `finish == "stop"` on the latest message
/// is exactly "completed assistant turn, no pending tool parts": a turn still
/// running a tool is the latest message with `finish == nil`, which this
/// classifies as not-ready.
public enum OpencodeDeliveryReadiness {
    public static func isReady(messages: [OpencodeTranscriptAdapter.MessageRow]) -> Bool {
        guard let last = messages.last else { return false }        // empty session: not ready
        return last.role == "assistant" && last.finish == "stop"    // user-last / mid-tool: not ready
    }

    /// The pre-delivery cursor: the latest message's `timeCreated` (ms), or 0
    /// for an empty session. Captured by the delivery adapter just before the
    /// resume so `OpencodeReplyCorrelation` can find the FIRST completed
    /// assistant turn created strictly after it (the reply this delivery
    /// produced).
    public static func checkpoint(messages: [OpencodeTranscriptAdapter.MessageRow]) -> Int64 {
        guard let last = messages.last else { return 0 }
        return Int64(last.timeCreated)
    }
}

/// Positional reply correlation for opencode (INF-245/B2 design, SQLite
/// variant). After delivering instruction N, the correlated reply is the first
/// completed assistant turn (`finish == "stop"`) whose `timeCreated` is
/// strictly greater than the delivery checkpoint. Because the engine delivers
/// single-flight FIFO per session (docs/two-way.md), everything created after
/// the checkpoint belongs to this delivery: the delivered user turn first,
/// then any interleaved tool/non-final assistant turns (skipped here, they are
/// not `finish == "stop"`), then the completed assistant reply. A second
/// instruction gets a later checkpoint (the first reply's time), so its reply
/// correlates to ITS own completed turn, never the prior one.
public enum OpencodeReplyCorrelation {
    /// The first completed assistant turn strictly after `checkpoint`, or `nil`
    /// if the rows don't contain one yet. Rows must be in the same
    /// oldest-first order `OpencodeReadOnlyDatabase.messages(forSessionID:)`
    /// returns (`time_created ASC, id ASC`).
    public static func firstCompletedAssistantTurn(
        messages: [OpencodeTranscriptAdapter.MessageRow],
        afterCheckpoint checkpoint: Int64
    ) -> (text: String, timeCreated: Int64)? {
        for message in messages {
            let time = Int64(message.timeCreated)
            guard time > checkpoint else { continue }
            guard message.role == "assistant", message.finish == "stop" else { continue }
            let text = OpencodeTranscriptAdapter.narratableText(of: message)
            guard !text.isEmpty else { continue }
            return (text, time)
        }
        return nil
    }
}
