import Foundation

/// Which agent wrote a transcript line, since Claude Code and Codex use different
/// JSONL shapes.
public enum TranscriptFormat {
    case claude
    case codex
}

/// One meaningful record parsed from a session transcript: either a piece of
/// assistant prose to narrate, or the start of a new human turn (a real user
/// message, not a tool result). Everything else (thinking, tool calls, tool
/// results, metadata) is dropped during parsing.
public struct ParsedTranscriptRecord: Equatable {
    public enum Kind: Equatable {
        /// Assistant prose. `isFinal` is true only for a Codex `final_answer`
        /// phase, which is a hard turn boundary; Claude prose is never final on
        /// its own (its turns close on the next user line or a quiet window).
        case assistantProse(text: String, isFinal: Bool)
        /// A real user-typed message, which closes the previous turn.
        case userTurnBoundary
    }

    public let kind: Kind
    public let timestamp: Date
    public let cwd: String?

    public init(kind: Kind, timestamp: Date, cwd: String?) {
        self.kind = kind
        self.timestamp = timestamp
        self.cwd = cwd
    }

    public var isProse: Bool {
        if case .assistantProse = kind { return true }
        return false
    }
}

/// One coalesced agent turn: the recap text (the turn's final assistant message)
/// plus any earlier interstitial prose from the same turn, for the activity
/// ticker and for presentation trajectory context.
public struct CoalescedTurn: Equatable {
    public let text: String
    public let interstitials: [String]
    public let cwd: String?
    public let timestamp: Date

    public init(text: String, interstitials: [String], cwd: String?, timestamp: Date) {
        self.text = text
        self.interstitials = interstitials
        self.cwd = cwd
        self.timestamp = timestamp
    }
}

/// Turns a stream of parsed transcript records (delivered one poll at a time)
/// into at most a few coalesced turns, so a multi-message agent turn becomes one
/// spoken recap and one card instead of a burst.
///
/// Pure and deterministic: it holds only the in-flight buffer and an idle-poll
/// counter, and it never touches the clock or the filesystem, so it is driven
/// directly in tests.
public final class NarrationCoalescer {
    /// Polls with no new prose before the buffer is flushed as a completed turn.
    /// At the watcher's 2s poll interval, 3 polls is a ~6s quiet window.
    private let quietPolls: Int

    private var buffer: [(text: String, cwd: String?, timestamp: Date)] = []
    private var pollsSinceProse = 0

    public init(quietPolls: Int = 3) {
        self.quietPolls = max(1, quietPolls)
    }

    public var hasBufferedProse: Bool { !buffer.isEmpty }

    /// Feed the records parsed this poll (empty if nothing new arrived) and get
    /// back any turns that completed. Flushes on a Codex final answer, on a new
    /// user turn, or after the quiet window with prose still buffered.
    public func poll(_ records: [ParsedTranscriptRecord]) -> [CoalescedTurn] {
        var emitted: [CoalescedTurn] = []

        if records.isEmpty {
            pollsSinceProse += 1
        }

        for record in records {
            switch record.kind {
            case .userTurnBoundary:
                // The user spoke again, so whatever the agent said before this is
                // a completed turn.
                if let turn = flush() { emitted.append(turn) }
            case let .assistantProse(text, isFinal):
                buffer.append((text: text, cwd: record.cwd, timestamp: record.timestamp))
                pollsSinceProse = 0
                if isFinal, let turn = flush() { emitted.append(turn) }
            }
        }

        if !buffer.isEmpty, pollsSinceProse >= quietPolls, let turn = flush() {
            emitted.append(turn)
        }

        return emitted
    }

    /// Force out whatever is buffered (e.g. when the session detaches). Returns
    /// nil if nothing is buffered.
    public func flushPending() -> CoalescedTurn? {
        flush()
    }

    private func flush() -> CoalescedTurn? {
        guard let last = buffer.last else { return nil }
        let interstitials = buffer.dropLast().map(\.text)
        let turn = CoalescedTurn(
            text: last.text,
            interstitials: Array(interstitials),
            cwd: last.cwd,
            timestamp: last.timestamp
        )
        buffer.removeAll(keepingCapacity: true)
        pollsSinceProse = 0
        return turn
    }
}
