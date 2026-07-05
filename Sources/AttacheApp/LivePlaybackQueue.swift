import Foundation

/// Orders live attached-session updates so exactly one is spoken at a time, a
/// failed or finished update advances to the next, and a conversation reply
/// preempts the current update and resumes it afterward.
///
/// Pure and deterministic (no audio, no store), so the lifecycle the pipeline
/// review flagged is unit-testable. The caller marks cards heard and plays audio;
/// this only decides ordering.
final class LivePlaybackQueue {
    /// The update currently synthesizing or playing, if any.
    private(set) var inFlight: String?
    /// The next update waiting to play. At most one, per the "never stack more
    /// than one pending per session" rule.
    private(set) var pending: String?
    /// A conversation reply is speaking and has priority over updates.
    private(set) var replyActive = false

    var isIdle: Bool { inFlight == nil && !replyActive }

    /// A live update arrived. Returns the card to start now, or nil if it queued
    /// behind an in-flight update, an active reply, or anything else currently
    /// playing (`isBusy`). A newer update replaces an older un-started one so only
    /// the latest is ever pending.
    func enqueue(_ cardID: String, isBusy: Bool) -> String? {
        pending = cardID
        return startNextIfIdle(isBusy: isBusy)
    }

    /// The in-flight update finished (success or failure). Returns the next update
    /// to play, if the queue is now free. The player has just gone idle here.
    func finished() -> String? {
        inFlight = nil
        return startNextIfIdle(isBusy: false)
    }

    /// A conversation reply started. It preempts the in-flight update, which
    /// returns to pending so it resumes after the reply (unless a newer update
    /// arrives first).
    func replyStarted() {
        replyActive = true
        if let card = inFlight {
            pending = card
            inFlight = nil
        }
    }

    /// The reply ended. Returns the update to resume, if any. The player has just
    /// gone idle here.
    func replyFinished() -> String? {
        replyActive = false
        return startNextIfIdle(isBusy: false)
    }

    func reset() {
        inFlight = nil
        pending = nil
        replyActive = false
    }

    /// Drop a stale in-flight marker when the player is actually idle, e.g. a
    /// manual play or an explicit stop preempted a live update without a finish
    /// callback. Keeps the queue from wedging on an orphaned in-flight id.
    func reconcile(isBusy: Bool) {
        if !isBusy && !replyActive { inFlight = nil }
    }

    private func startNextIfIdle(isBusy: Bool) -> String? {
        guard !isBusy, inFlight == nil, !replyActive, let next = pending else { return nil }
        pending = nil
        inFlight = next
        return next
    }
}
