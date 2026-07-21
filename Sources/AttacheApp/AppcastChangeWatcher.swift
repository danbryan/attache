import Foundation
import AttacheCore

/// The network-facing half of the near-immediate update path. It periodically
/// issues a conditional GET against our own appcast, hands the outcome to the
/// pure `AppcastChangePolicy`, and, only when the feed actually changed, asks
/// Sparkle for a background update check (which shows UI solely if a real update
/// exists). All decision logic lives in `AttacheCore` so it can be tested without
/// a network or a clock; this type owns only the side effects: the transport, the
/// timer, the UserDefaults-backed validator store, and the Sparkle trigger.
///
/// Threading contract: the injected scheduler and the probe's completion must be
/// delivered on the same serial context (the main queue in the app; the test
/// thread under a synchronous scheduler). The watcher touches its mutable state
/// only from that context, so it needs no additional locking.

/// Abstracts a delayed one-shot so tests can drive time deterministically.
protocol AppcastPollScheduler {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> AppcastScheduledWork
}

/// A handle to cancel a scheduled one-shot.
protocol AppcastScheduledWork {
    func cancel()
}

/// Performs one conditional probe of the feed and reports a pure observation.
protocol AppcastFeedProbe {
    /// `validators` carries the last stored ETag/Last-Modified to send as
    /// If-None-Match / If-Modified-Since. The completion MUST be delivered on the
    /// watcher's serial context (see the type's threading contract).
    func probe(url: URL,
               validators: AppcastValidators,
               completion: @escaping (AppcastObservation) -> Void)
}

/// Loads and stores the appcast validators across polls.
protocol AppcastValidatorStore {
    func load() -> AppcastValidators?
    func save(_ validators: AppcastValidators)
}

final class AppcastChangeWatcher {
    private let feedURL: URL
    private let probe: AppcastFeedProbe
    private let scheduler: AppcastPollScheduler
    private let store: AppcastValidatorStore
    private let triggerBackgroundCheck: () -> Void
    private let canCheck: () -> Bool

    private var schedule: AppcastPollSchedule
    private var pending: AppcastScheduledWork?
    private var running = false

    /// Test-only counters, cheap and side-effect free.
    private(set) var pollCount = 0
    private(set) var triggerCount = 0

    init(feedURL: URL,
         probe: AppcastFeedProbe,
         scheduler: AppcastPollScheduler,
         store: AppcastValidatorStore,
         canCheck: @escaping () -> Bool,
         triggerBackgroundCheck: @escaping () -> Void,
         baseInterval: TimeInterval = AppcastPollSchedule.defaultBaseInterval,
         maxInterval: TimeInterval = AppcastPollSchedule.defaultMaxInterval) {
        self.feedURL = feedURL
        self.probe = probe
        self.scheduler = scheduler
        self.store = store
        self.canCheck = canCheck
        self.triggerBackgroundCheck = triggerBackgroundCheck
        self.schedule = AppcastPollSchedule(baseInterval: baseInterval, maxInterval: maxInterval)
    }

    /// Begin polling. Idempotent: a second call while running is a no-op, so the
    /// live toggle can call `start()` freely. The cadence resets and the first
    /// poll lands shortly after, so a machine that just woke hears about a waiting
    /// update within about a minute.
    func start() {
        guard !running else { return }
        running = true
        schedule.recordSuccess()
        armNext(after: AppcastPollSchedule.firstPollDelay)
    }

    /// Stop polling immediately and cancel any pending one-shot. In-flight probe
    /// completions become no-ops because they check `running`. Idempotent.
    func stop() {
        running = false
        pending?.cancel()
        pending = nil
    }

    private func armNext(after delay: TimeInterval) {
        pending = scheduler.schedule(after: delay) { [weak self] in self?.poll() }
    }

    private func poll() {
        guard running else { return }
        pending = nil
        pollCount += 1
        // Sparkle may be mid-update or otherwise unable to check; skip the trigger
        // path entirely and retry at the current cadence.
        guard canCheck() else {
            armNext(after: schedule.currentInterval)
            return
        }
        let previous = store.load()
        probe.probe(url: feedURL, validators: previous ?? AppcastValidators()) { [weak self] observation in
            self?.handle(observation, previous: previous)
        }
    }

    private func handle(_ observation: AppcastObservation, previous: AppcastValidators?) {
        guard running else { return }
        switch AppcastChangePolicy.decide(previous: previous, observation: observation) {
        case .firstObservationStored(let validators):
            store.save(validators)
            schedule.recordSuccess()
        case .unchanged:
            schedule.recordSuccess()
        case .changedTrigger(let validators):
            store.save(validators)
            schedule.recordSuccess()
            triggerCount += 1
            AttacheLog.updates.info("appcast feed changed; requesting background update check")
            triggerBackgroundCheck()
        case .failure:
            schedule.recordFailure()
        }
        guard running else { return }
        armNext(after: schedule.currentInterval)
    }
}

// MARK: - Production side effects

/// Main-queue one-shot scheduler backing the live watcher.
struct MainQueueAppcastScheduler: AppcastPollScheduler {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> AppcastScheduledWork {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return WorkItemHandle(item: item)
    }

    private struct WorkItemHandle: AppcastScheduledWork {
        let item: DispatchWorkItem
        func cancel() { item.cancel() }
    }
}

/// Conditional-GET probe over URLSession. Requests only the feed URL with no
/// query params and no identifying payload beyond the conditional validators, and
/// re-delivers its completion on the main queue to honor the watcher's threading
/// contract.
struct URLSessionAppcastProbe: AppcastFeedProbe {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func probe(url: URL,
               validators: AppcastValidators,
               completion: @escaping (AppcastObservation) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag = validators.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = validators.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        let task = session.dataTask(with: request) { data, response, error in
            let observation = Self.observation(data: data, response: response, error: error)
            DispatchQueue.main.async { completion(observation) }
        }
        task.resume()
    }

    static func observation(data: Data?, response: URLResponse?, error: Error?) -> AppcastObservation {
        guard error == nil, let http = response as? HTTPURLResponse else {
            return .failure
        }
        if http.statusCode == 304 {
            return .notModified
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failure
        }
        let etag = http.value(forHTTPHeaderField: "Etag")
        let lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        let contentHash = data.map(AppcastValidators.hash)
        return .fetched(AppcastValidators(etag: etag, lastModified: lastModified, contentHash: contentHash))
    }
}

/// UserDefaults-backed validator store using `attache.`-prefixed keys.
struct UserDefaultsAppcastValidatorStore: AppcastValidatorStore {
    let defaults: UserDefaults

    enum Key {
        static let etag = "attache.appcastETag"
        static let lastModified = "attache.appcastLastModified"
        static let contentHash = "attache.appcastContentHash"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppcastValidators? {
        let etag = defaults.string(forKey: Key.etag)
        let lastModified = defaults.string(forKey: Key.lastModified)
        let contentHash = defaults.string(forKey: Key.contentHash)
        if etag == nil, lastModified == nil, contentHash == nil {
            return nil
        }
        return AppcastValidators(etag: etag, lastModified: lastModified, contentHash: contentHash)
    }

    func save(_ validators: AppcastValidators) {
        defaults.set(validators.etag, forKey: Key.etag)
        defaults.set(validators.lastModified, forKey: Key.lastModified)
        defaults.set(validators.contentHash, forKey: Key.contentHash)
    }
}
