import XCTest
import AttacheCore
@testable import AttacheApp

/// Watcher behavior over an injectable scheduler, transport, and store, plus the
/// user-facing `promptUpdateChecks` preference (default-enabled and persistence).
/// No real network or clock: `ManualScheduler` drives time and `FakeProbe`
/// supplies canned observations synchronously on the test thread.
final class AppcastChangeWatcherTests: XCTestCase {
    private let feedURL = URL(string: "https://attache.fm/appcast.xml")!

    // MARK: Test doubles

    private final class ManualScheduler: AppcastPollScheduler {
        private final class Item: AppcastScheduledWork {
            var work: (() -> Void)?
            init(_ work: @escaping () -> Void) { self.work = work }
            func cancel() { work = nil }
        }
        private var pending: Item?
        private(set) var lastDelay: TimeInterval?

        var hasPending: Bool { pending?.work != nil }

        func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> AppcastScheduledWork {
            let item = Item(work)
            pending = item
            lastDelay = delay
            return item
        }

        /// Run the currently pending one-shot, if it has not been cancelled.
        func fire() {
            guard let work = pending?.work else { return }
            pending = nil
            work()
        }
    }

    private final class FakeProbe: AppcastFeedProbe {
        var observations: [AppcastObservation] = []
        var defaultObservation: AppcastObservation = .failure
        private(set) var sentValidators: [AppcastValidators] = []
        private(set) var probeCount = 0

        func probe(url: URL,
                   validators: AppcastValidators,
                   completion: @escaping (AppcastObservation) -> Void) {
            probeCount += 1
            sentValidators.append(validators)
            let next = observations.isEmpty ? defaultObservation : observations.removeFirst()
            completion(next)
        }
    }

    private final class InMemoryStore: AppcastValidatorStore {
        var validators: AppcastValidators?
        func load() -> AppcastValidators? { validators }
        func save(_ v: AppcastValidators) { validators = v }
    }

    private func makeWatcher(scheduler: ManualScheduler,
                             probe: FakeProbe,
                             store: InMemoryStore,
                             canCheck: @escaping () -> Bool = { true },
                             onTrigger: @escaping () -> Void) -> AppcastChangeWatcher {
        AppcastChangeWatcher(
            feedURL: feedURL,
            probe: probe,
            scheduler: scheduler,
            store: store,
            canCheck: canCheck,
            triggerBackgroundCheck: onTrigger
        )
    }

    // MARK: Scheduling and detection

    func testFirstPollUsesFirstPollDelayThenStoresWithoutTrigger() {
        let scheduler = ManualScheduler(); let probe = FakeProbe(); let store = InMemoryStore()
        probe.observations = [.fetched(AppcastValidators(etag: "A"))]
        var triggers = 0
        let watcher = makeWatcher(scheduler: scheduler, probe: probe, store: store) { triggers += 1 }

        watcher.start()
        XCTAssertEqual(scheduler.lastDelay, AppcastPollSchedule.firstPollDelay,
                       "the first poll is scheduled shortly after launch")

        scheduler.fire()
        XCTAssertEqual(probe.probeCount, 1)
        XCTAssertEqual(triggers, 0, "the first observation never triggers, the launch check already did")
        XCTAssertEqual(store.validators, AppcastValidators(etag: "A"))
        XCTAssertEqual(scheduler.lastDelay, AppcastPollSchedule.defaultBaseInterval,
                       "subsequent polls fall to the base cadence")
    }

    func testChangedFeedTriggersBackgroundCheckExactlyOnce() {
        let scheduler = ManualScheduler(); let probe = FakeProbe(); let store = InMemoryStore()
        store.validators = AppcastValidators(etag: "A")
        probe.observations = [.fetched(AppcastValidators(etag: "B")), .fetched(AppcastValidators(etag: "B"))]
        var triggers = 0
        let watcher = makeWatcher(scheduler: scheduler, probe: probe, store: store) { triggers += 1 }

        watcher.start()
        scheduler.fire()   // A -> B: change
        XCTAssertEqual(triggers, 1)
        XCTAssertEqual(store.validators, AppcastValidators(etag: "B"))

        scheduler.fire()   // B -> B: unchanged
        XCTAssertEqual(triggers, 1, "a stable feed never re-triggers")
    }

    func testProbeSendsStoredValidatorsForConditionalRequest() {
        let scheduler = ManualScheduler(); let probe = FakeProbe(); let store = InMemoryStore()
        store.validators = AppcastValidators(etag: "A", lastModified: "Mon")
        probe.observations = [.notModified]
        let watcher = makeWatcher(scheduler: scheduler, probe: probe, store: store) {}

        watcher.start()
        scheduler.fire()
        XCTAssertEqual(probe.sentValidators.first, AppcastValidators(etag: "A", lastModified: "Mon"))
    }

    func testFailureBacksOffAndSuccessResets() {
        let scheduler = ManualScheduler(); let probe = FakeProbe(); let store = InMemoryStore()
        probe.observations = [.failure, .failure, .fetched(AppcastValidators(etag: "A"))]
        let watcher = makeWatcher(scheduler: scheduler, probe: probe, store: store) {}

        watcher.start()
        scheduler.fire()   // failure
        XCTAssertEqual(scheduler.lastDelay, 1200)
        scheduler.fire()   // failure
        XCTAssertEqual(scheduler.lastDelay, 2400)
        scheduler.fire()   // success (first store)
        XCTAssertEqual(scheduler.lastDelay, AppcastPollSchedule.defaultBaseInterval)
    }

    func testUpdaterUnavailableSkipsProbeButReschedules() {
        let scheduler = ManualScheduler(); let probe = FakeProbe(); let store = InMemoryStore()
        let watcher = makeWatcher(scheduler: scheduler, probe: probe, store: store, canCheck: { false }) {}

        watcher.start()
        scheduler.fire()
        XCTAssertEqual(probe.probeCount, 0, "no probe when Sparkle cannot currently check")
        XCTAssertEqual(scheduler.lastDelay, AppcastPollSchedule.defaultBaseInterval,
                       "still rearms so it recovers when the updater is ready again")
    }

    // MARK: Live toggle

    func testStopHaltsSchedulingImmediately() {
        let scheduler = ManualScheduler(); let probe = FakeProbe(); let store = InMemoryStore()
        let watcher = makeWatcher(scheduler: scheduler, probe: probe, store: store) {}

        watcher.start()
        XCTAssertTrue(scheduler.hasPending)
        watcher.stop()
        XCTAssertFalse(scheduler.hasPending, "flipping the toggle off cancels the pending poll live")
        scheduler.fire()
        XCTAssertEqual(probe.probeCount, 0, "a cancelled poll never reaches the network")
    }

    func testStartResumesAfterStop() {
        let scheduler = ManualScheduler(); let probe = FakeProbe(); let store = InMemoryStore()
        let watcher = makeWatcher(scheduler: scheduler, probe: probe, store: store) {}

        watcher.start()
        watcher.stop()
        watcher.start()
        XCTAssertTrue(scheduler.hasPending)
        XCTAssertEqual(scheduler.lastDelay, AppcastPollSchedule.firstPollDelay,
                       "flipping the toggle back on polls again shortly after")
    }

    // MARK: URLSession probe mapping (pure)

    func testObservationMappingCoversStatuses() {
        let r304 = HTTPURLResponse(url: feedURL, statusCode: 304, httpVersion: nil, headerFields: nil)!
        XCTAssertEqual(URLSessionAppcastProbe.observation(data: nil, response: r304, error: nil), .notModified)

        let body = Data("<rss/>".utf8)
        let r200 = HTTPURLResponse(url: feedURL, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Etag": "v9", "Last-Modified": "Tue"])!
        XCTAssertEqual(
            URLSessionAppcastProbe.observation(data: body, response: r200, error: nil),
            .fetched(AppcastValidators(etag: "v9", lastModified: "Tue", contentHash: AppcastValidators.hash(body)))
        )

        XCTAssertEqual(
            URLSessionAppcastProbe.observation(data: nil, response: nil, error: URLError(.timedOut)),
            .failure
        )
        let r500 = HTTPURLResponse(url: feedURL, statusCode: 500, httpVersion: nil, headerFields: nil)!
        XCTAssertEqual(URLSessionAppcastProbe.observation(data: nil, response: r500, error: nil), .failure)
    }

    // MARK: UserDefaults-backed validator store

    func testValidatorStoreRoundTripsUnderAttachePrefixedKeys() {
        let suite = UserDefaults(suiteName: "attache.appcast.test.\(UUID().uuidString)")!
        let store = UserDefaultsAppcastValidatorStore(defaults: suite)
        XCTAssertNil(store.load(), "no validators before the first save")
        let validators = AppcastValidators(etag: "v1", lastModified: "Mon", contentHash: "abc")
        store.save(validators)
        XCTAssertEqual(store.load(), validators)
        XCTAssertEqual(suite.string(forKey: UserDefaultsAppcastValidatorStore.Key.etag), "v1")
    }

    // MARK: Preference default and persistence

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: AttachePreferenceKey.promptUpdateChecks)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AttachePreferenceKey.promptUpdateChecks)
        super.tearDown()
    }

    func testPromptUpdateChecksDefaultsEnabledOnFreshDefaults() throws {
        let model = try AppModel(store: CardStore.inMemory())
        XCTAssertTrue(model.promptUpdateChecks, "prompt update checks ship on by default")
    }

    func testPromptUpdateChecksPersistsAcrossReload() throws {
        let model = try AppModel(store: CardStore.inMemory())
        model.promptUpdateChecks = false
        XCTAssertEqual(UserDefaults.standard.object(forKey: AttachePreferenceKey.promptUpdateChecks) as? Bool, false)

        let reloaded = try AppModel(store: CardStore.inMemory())
        XCTAssertFalse(reloaded.promptUpdateChecks, "a disabled preference survives a relaunch")
    }
}
