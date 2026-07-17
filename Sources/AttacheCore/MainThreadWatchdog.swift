import Foundation

/// Which bucket a stall's duration falls into. Coarse buckets keep the
/// diagnostics surface readable (INF-349): nobody needs the exact
/// millisecond count, just an order of magnitude.
public enum StallDurationBucket: String, Codable, CaseIterable, Sendable {
    case ms250to500 = "250-500ms"
    case ms500to1s = "500ms-1s"
    case s1to2 = "1s-2s"
    case over2s = "over 2s"

    /// `nil` when the duration is below the stall threshold (250ms); the
    /// caller should not record an event in that case.
    public static func bucket(forDuration duration: TimeInterval) -> StallDurationBucket? {
        switch duration {
        case ..<0.25:
            return nil
        case 0.25..<0.5:
            return .ms250to500
        case 0.5..<1.0:
            return .ms500to1s
        case 1.0..<2.0:
            return .s1to2
        default:
            return .over2s
        }
    }
}

/// One recorded main-thread stall. Content-free by construction: the only
/// string field is a caller-supplied context label (a pane/state name like
/// "settings.context" or "call.live"), never user text, transcript
/// content, or file paths.
public struct StallEvent: Equatable, Sendable {
    public let bucket: StallDurationBucket
    public let duration: TimeInterval
    public let timestamp: Date
    public let context: String

    public init(bucket: StallDurationBucket, duration: TimeInterval, timestamp: Date, context: String) {
        self.bucket = bucket
        self.duration = duration
        self.timestamp = timestamp
        self.context = context
    }
}

/// Detects main-thread stalls by round-tripping a no-op block through the
/// main queue on a fixed cadence and measuring how long it took to start
/// executing. A background `DispatchSourceTimer` posts the probe every
/// `tickInterval`; if the probe does not begin running within
/// `stallThreshold`, the delay itself is the stall duration (the main
/// thread was busy with something else and could not service the queue).
///
/// Measurement only: this class never changes app behavior, never
/// captures user text, and keeps only the last `maxStoredEvents` events in
/// memory (no persistence).
public final class MainThreadWatchdog: @unchecked Sendable {
    public static let maxStoredEvents = 200

    private let tickInterval: TimeInterval
    private let stallThreshold: TimeInterval
    private let contextProvider: @Sendable () -> String
    private let timerQueue: DispatchQueue

    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var events: [StallEvent] = []

    /// - Parameters:
    ///   - tickInterval: how often the probe is posted to the main queue (default 100ms per spec).
    ///   - stallThreshold: minimum delay to count as a stall (default 250ms per spec).
    ///   - contextProvider: called on the background timer queue right before each probe is
    ///     posted; returns the caller-supplied current-context label to attach if this probe stalls.
    public init(
        tickInterval: TimeInterval = 0.1,
        stallThreshold: TimeInterval = 0.25,
        contextProvider: @escaping @Sendable () -> String = { "" }
    ) {
        self.tickInterval = tickInterval
        self.stallThreshold = stallThreshold
        self.contextProvider = contextProvider
        self.timerQueue = DispatchQueue(label: "com.bryanlabs.attache.watchdog", qos: .utility)
    }

    /// Starts the background timer. Safe to call more than once; restarts
    /// cleanly. No product behavior change: this only schedules
    /// measurement, never touches UI state.
    public func start() {
        stop()
        let source = DispatchSource.makeTimerSource(queue: timerQueue)
        source.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        source.resume()
        timer = source
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Last `maxStoredEvents` stall events, oldest first.
    public func report() -> [StallEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    /// Clears recorded events without stopping the timer. Exposed for
    /// tests and for a future "clear diagnostics" affordance; never called
    /// automatically.
    public func reset() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }

    private func tick() {
        let dispatchedAt = Date()
        let context = contextProvider()
        DispatchQueue.main.async { [weak self] in
            self?.finishProbe(dispatchedAt: dispatchedAt, context: context)
        }
    }

    private func finishProbe(dispatchedAt: Date, context: String) {
        let elapsed = Date().timeIntervalSince(dispatchedAt)
        recordDispatchLatency(elapsed, context: context, timestamp: Date())
    }

    /// Records a stall if `latency` exceeds the stall threshold. Split out
    /// from the real timer plumbing so unit tests can simulate a stalled
    /// dispatch deterministically, without depending on wall-clock timer
    /// scheduling.
    @discardableResult
    func recordDispatchLatency(_ latency: TimeInterval, context: String, timestamp: Date = Date()) -> StallEvent? {
        guard let bucket = StallDurationBucket.bucket(forDuration: latency) else { return nil }
        let event = StallEvent(bucket: bucket, duration: latency, timestamp: timestamp, context: context)
        lock.lock()
        events.append(event)
        if events.count > Self.maxStoredEvents {
            events.removeFirst(events.count - Self.maxStoredEvents)
        }
        lock.unlock()
        return event
    }
}
