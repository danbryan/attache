import Foundation

/// One propose_memory invocation, as seen by local policy. Records enough to
/// reconstruct a session's memory behavior after the fact: what decoding did,
/// what the disposition was, and what egress and scope were stored. The
/// statement content is included only for successes and non-secret
/// rejections; secret-class rejections and decode failures never carry
/// content.
public struct AttacheMemoryAttemptRecord: Equatable, Sendable {
    public let timestamp: Date
    public let personalityID: String
    /// "ok", "defaulted: type,egress", or "decode-failed rawLength=N".
    public let decodeOutcome: String
    /// "saved", "rejected(reason)", "refused-duplicate-turn",
    /// "invalid-arguments", or "ignored-mode-off".
    public let disposition: String
    /// Omitted for secret-class rejections and decode failures.
    public let statement: String?
    public let egress: String?
    public let scope: String?

    public init(
        timestamp: Date,
        personalityID: String,
        decodeOutcome: String,
        disposition: String,
        statement: String?,
        egress: String?,
        scope: String?
    ) {
        self.timestamp = timestamp
        self.personalityID = personalityID
        self.decodeOutcome = decodeOutcome
        self.disposition = disposition
        self.statement = statement
        self.egress = egress
        self.scope = scope
    }
}

/// Bounded in-memory log of propose_memory attempts, following the same
/// `diagnostics()` snapshot idiom as the other Core subsystems. Retention is
/// capped so a long session cannot grow it unbounded.
public final class AttacheMemoryAttemptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [AttacheMemoryAttemptRecord] = []
    private let capacity: Int

    public init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    public func record(_ entry: AttacheMemoryAttemptRecord) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Snapshot of the retained attempts, oldest first.
    public func diagnostics() -> [AttacheMemoryAttemptRecord] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}
