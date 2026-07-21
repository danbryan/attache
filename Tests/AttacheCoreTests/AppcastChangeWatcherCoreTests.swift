import XCTest
@testable import AttacheCore

/// Pure change-detection and backoff logic for the near-immediate update path.
/// No network, no clock: every case exercises `AppcastChangePolicy` /
/// `AppcastPollSchedule` directly.
final class AppcastChangeWatcherCoreTests: XCTestCase {

    // MARK: First-run rule (pinned)

    func testFirstObservationStoresWithoutTriggering() {
        let fresh = AppcastValidators(etag: "v1", lastModified: "Mon", contentHash: "aa")
        let decision = AppcastChangePolicy.decide(previous: nil, observation: .fetched(fresh))
        XCTAssertEqual(decision, .firstObservationStored(fresh),
                       "the first observation must only record validators, never trigger a check")
    }

    // MARK: Unchanged feed

    func testMatchingEtagDoesNotTrigger() {
        let previous = AppcastValidators(etag: "v1", lastModified: "Mon", contentHash: "aa")
        let fresh = AppcastValidators(etag: "v1", lastModified: "Mon", contentHash: "aa")
        XCTAssertEqual(AppcastChangePolicy.decide(previous: previous, observation: .fetched(fresh)), .unchanged)
    }

    func testMatchingEtagWinsEvenIfNoOtherValidators() {
        // A strong validator that matches means unchanged, even when the server
        // stopped sending Last-Modified and we carry no hash to compare.
        let previous = AppcastValidators(etag: "v1")
        let fresh = AppcastValidators(etag: "v1")
        XCTAssertEqual(AppcastChangePolicy.decide(previous: previous, observation: .fetched(fresh)), .unchanged)
    }

    func testNotModifiedDoesNothing() {
        let previous = AppcastValidators(etag: "v1")
        XCTAssertEqual(AppcastChangePolicy.decide(previous: previous, observation: .notModified), .unchanged)
    }

    func testFailureDoesNothing() {
        let previous = AppcastValidators(etag: "v1")
        XCTAssertEqual(AppcastChangePolicy.decide(previous: previous, observation: .failure), .failure)
    }

    // MARK: Changed feed

    func testChangedEtagTriggersAndCarriesNewValidators() {
        let previous = AppcastValidators(etag: "v1", lastModified: "Mon", contentHash: "aa")
        let fresh = AppcastValidators(etag: "v2", lastModified: "Tue", contentHash: "bb")
        XCTAssertEqual(AppcastChangePolicy.decide(previous: previous, observation: .fetched(fresh)),
                       .changedTrigger(fresh))
    }

    func testChangedByLastModifiedWhenNoEtag() {
        let previous = AppcastValidators(lastModified: "Mon")
        let fresh = AppcastValidators(lastModified: "Tue")
        XCTAssertEqual(AppcastChangePolicy.decide(previous: previous, observation: .fetched(fresh)),
                       .changedTrigger(fresh))
    }

    func testChangedByContentHashWhenValidatorsAbsent() {
        // No ETag or Last-Modified either side; only the body hash differs.
        let previous = AppcastValidators(contentHash: "aa")
        let fresh = AppcastValidators(contentHash: "bb")
        XCTAssertEqual(AppcastChangePolicy.decide(previous: previous, observation: .fetched(fresh)),
                       .changedTrigger(fresh))
    }

    func testChangedByHashEvenWhenEtagReused() {
        // A misconfigured server that reuses an ETag but ships a new body still
        // counts as a change, because the hash is comparable and differs.
        let previous = AppcastValidators(etag: "v1", contentHash: "aa")
        let fresh = AppcastValidators(etag: "v1", contentHash: "bb")
        XCTAssertEqual(AppcastChangePolicy.decide(previous: previous, observation: .fetched(fresh)),
                       .changedTrigger(fresh))
    }

    func testTwoEmptyObservationsAreNotAChange() {
        let previous = AppcastValidators()
        let fresh = AppcastValidators()
        XCTAssertEqual(AppcastChangePolicy.decide(previous: previous, observation: .fetched(fresh)), .unchanged)
    }

    // MARK: Once-per-distinct-state

    func testTriggerFiresAtMostOncePerDistinctFeedState() {
        // Simulate the watcher's store-then-compare loop across a sequence of
        // fetches and assert exactly one trigger per new state.
        var stored: AppcastValidators?
        var triggers = 0

        func step(_ fresh: AppcastValidators) {
            switch AppcastChangePolicy.decide(previous: stored, observation: .fetched(fresh)) {
            case .firstObservationStored(let v):
                stored = v
            case .changedTrigger(let v):
                stored = v
                triggers += 1
            case .unchanged, .failure:
                break
            }
        }

        let stateA = AppcastValidators(etag: "A")
        let stateB = AppcastValidators(etag: "B")

        step(stateA)   // first observation: store, no trigger
        step(stateA)   // unchanged
        step(stateA)   // unchanged
        step(stateB)   // change: one trigger
        step(stateB)   // unchanged
        step(stateA)   // change back: one trigger
        step(stateA)   // unchanged

        XCTAssertEqual(triggers, 2, "one trigger per distinct new feed state, never repeated on a stable feed")
        XCTAssertEqual(stored, stateA)
    }

    // MARK: Backoff arithmetic

    func testBackoffDoublesOnConsecutiveFailuresUpToMax() {
        var schedule = AppcastPollSchedule(baseInterval: 600, maxInterval: 3600)
        XCTAssertEqual(schedule.currentInterval, 600)
        schedule.recordFailure(); XCTAssertEqual(schedule.currentInterval, 1200)
        schedule.recordFailure(); XCTAssertEqual(schedule.currentInterval, 2400)
        schedule.recordFailure(); XCTAssertEqual(schedule.currentInterval, 3600, "doubling clamps at maxInterval")
        schedule.recordFailure(); XCTAssertEqual(schedule.currentInterval, 3600, "stays clamped, never past the ceiling")
    }

    func testBackoffResetsOnSuccess() {
        var schedule = AppcastPollSchedule(baseInterval: 600, maxInterval: 3600)
        schedule.recordFailure()
        schedule.recordFailure()
        XCTAssertEqual(schedule.currentInterval, 2400)
        schedule.recordSuccess()
        XCTAssertEqual(schedule.currentInterval, 600, "any success returns to the base cadence")
    }

    func testDefaultScheduleConstants() {
        XCTAssertEqual(AppcastPollSchedule.firstPollDelay, 60)
        XCTAssertEqual(AppcastPollSchedule.defaultBaseInterval, 600)
        XCTAssertEqual(AppcastPollSchedule.defaultMaxInterval, 3600)
    }

    // MARK: Validator hashing

    func testHashIsStableAndDistinguishesContent() {
        let a = AppcastValidators.hash(Data("<rss>one</rss>".utf8))
        let a2 = AppcastValidators.hash(Data("<rss>one</rss>".utf8))
        let b = AppcastValidators.hash(Data("<rss>two</rss>".utf8))
        XCTAssertEqual(a, a2)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 64, "SHA-256 renders as 64 hex chars")
    }
}
