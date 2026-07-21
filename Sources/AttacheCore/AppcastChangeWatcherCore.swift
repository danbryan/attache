import Foundation
import CryptoKit

/// Pure change-detection and poll-scheduling logic for the near-immediate update
/// path (INF: appcast change watcher). The app is a long-running menu bar app;
/// Sparkle's own scheduled check is hourly at best, so a lightweight poller does
/// a conditional GET against our own appcast every few minutes and, only when the
/// feed actually changed, asks Sparkle for a background check. Sparkle still
/// decides whether an update exists and whether to show any UI.
///
/// Everything here is side-effect free and deterministic so it can be unit tested
/// without a network or a clock. The App layer (`AppcastChangeWatcher`) owns the
/// URLSession, the timer, and the UserDefaults persistence, and delegates every
/// decision to this type.

/// The HTTP validators we store to detect a changed feed across polls. `etag`
/// and `lastModified` drive the conditional request; `contentHash` is a SHA-256
/// of the body as a fallback signal when a server reuses or omits validators.
public struct AppcastValidators: Equatable, Codable {
    public var etag: String?
    public var lastModified: String?
    public var contentHash: String?

    public init(etag: String? = nil, lastModified: String? = nil, contentHash: String? = nil) {
        self.etag = etag
        self.lastModified = lastModified
        self.contentHash = contentHash
    }

    /// True when this carries no usable signal at all.
    public var isEmpty: Bool {
        etag == nil && lastModified == nil && contentHash == nil
    }

    /// Lowercase hex SHA-256 of a response body, used as `contentHash`.
    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The outcome of one network probe, as seen by the pure policy. The App layer
/// maps an `HTTPURLResponse` onto one of these and never leaks URLSession types
/// into the decision.
public enum AppcastObservation: Equatable {
    /// Server answered 304 Not Modified to our conditional request.
    case notModified
    /// Server answered 2xx with a fresh body; validators (and body hash) attached.
    case fetched(AppcastValidators)
    /// Transport error, non-2xx/304 status, or a malformed response.
    case failure
}

/// What the watcher should do with a probe outcome. Only `changedTrigger` ever
/// asks Sparkle to check; the first observation only records validators so a
/// fresh install does not fire a redundant check on top of the launch-time one.
public enum AppcastChangeDecision: Equatable {
    /// No prior validators existed: store these, do NOT trigger a check.
    case firstObservationStored(AppcastValidators)
    /// Feed is unchanged (304, or validators match): do nothing.
    case unchanged
    /// Feed changed: store the new validators and trigger a background check.
    case changedTrigger(AppcastValidators)
    /// Probe failed: do nothing here; the caller backs off.
    case failure
}

public enum AppcastChangePolicy {
    /// The core decision. `previous` is nil only before the first successful
    /// fetch of this launch/profile.
    ///
    /// First-run rule (pinned): the very first observation with no stored
    /// validators only STORES them and never triggers, because app launch has
    /// already scheduled a Sparkle background check. Triggering here would just
    /// double up with that.
    ///
    /// Once-per-state rule: a change triggers exactly once because the new
    /// validators are stored alongside the trigger, so the next poll compares
    /// the feed against its own current state and reports `unchanged` until it
    /// changes again.
    public static func decide(previous: AppcastValidators?,
                              observation: AppcastObservation) -> AppcastChangeDecision {
        switch observation {
        case .failure:
            return .failure
        case .notModified:
            // 304 is defined relative to the validators we sent, i.e. no change.
            return .unchanged
        case .fetched(let fresh):
            guard let previous else {
                return .firstObservationStored(fresh)
            }
            return indicatesChange(previous: previous, fresh: fresh)
                ? .changedTrigger(fresh)
                : .unchanged
        }
    }

    /// True when `fresh` describes a different feed than `previous`. Any
    /// comparable validator that differs counts as a change; a matching strong
    /// validator with no other differing signal counts as unchanged. If nothing
    /// is comparable (a server that dropped every validator) fall back to whole
    /// struct inequality, but never treat two empties as a change.
    public static func indicatesChange(previous: AppcastValidators,
                                       fresh: AppcastValidators) -> Bool {
        var sawComparable = false
        if let a = previous.etag, let b = fresh.etag {
            sawComparable = true
            if a != b { return true }
        }
        if let a = previous.lastModified, let b = fresh.lastModified {
            sawComparable = true
            if a != b { return true }
        }
        if let a = previous.contentHash, let b = fresh.contentHash {
            sawComparable = true
            if a != b { return true }
        }
        if sawComparable { return false }
        if previous.isEmpty && fresh.isEmpty { return false }
        return previous != fresh
    }
}

/// Pure poll-interval schedule with exponential backoff on failure. Starts at
/// `baseInterval`, doubles each consecutive failure up to `maxInterval`, and
/// resets to `baseInterval` on any success.
public struct AppcastPollSchedule: Equatable {
    /// Delay before the first poll after launch, so a machine that just woke
    /// hears about a waiting update within about a minute.
    public static let firstPollDelay: TimeInterval = 60
    /// Steady-state poll cadence.
    public static let defaultBaseInterval: TimeInterval = 600      // 10 minutes
    /// Backoff ceiling, matching Sparkle's own one-hour floor.
    public static let defaultMaxInterval: TimeInterval = 3600      // 1 hour

    public let baseInterval: TimeInterval
    public let maxInterval: TimeInterval
    public private(set) var currentInterval: TimeInterval

    public init(baseInterval: TimeInterval = AppcastPollSchedule.defaultBaseInterval,
                maxInterval: TimeInterval = AppcastPollSchedule.defaultMaxInterval) {
        self.baseInterval = baseInterval
        self.maxInterval = maxInterval
        self.currentInterval = baseInterval
    }

    /// A good poll resets the cadence to the base interval.
    public mutating func recordSuccess() {
        currentInterval = baseInterval
    }

    /// A failed poll doubles the wait, capped at `maxInterval`.
    public mutating func recordFailure() {
        currentInterval = min(currentInterval * 2, maxInterval)
    }
}
