import XCTest
@testable import AttacheApp

final class LivePlaybackQueueTests: XCTestCase {
    func testFirstUpdatePlaysImmediatelyWhenIdle() {
        let q = LivePlaybackQueue()
        XCTAssertEqual(q.enqueue("A", isBusy: false), "A")
        XCTAssertEqual(q.inFlight, "A")
    }

    func testTwoRapidUpdatesBothPlayInOrder() {
        // Simulates the burst bug: B arrives during A's synthesis window.
        let q = LivePlaybackQueue()
        XCTAssertEqual(q.enqueue("A", isBusy: false), "A")   // A starts
        // B arrives while A is still busy (synthesizing or playing).
        XCTAssertNil(q.enqueue("B", isBusy: true))           // B queues, A not cancelled
        XCTAssertEqual(q.pending, "B")
        // A finishes -> B plays next.
        XCTAssertEqual(q.finished(), "B")
        XCTAssertEqual(q.inFlight, "B")
        XCTAssertNil(q.finished())                            // nothing left
    }

    func testFailedUpdateStillAdvancesQueue() {
        let q = LivePlaybackQueue()
        _ = q.enqueue("A", isBusy: false)
        _ = q.enqueue("B", isBusy: true)
        // A fails (synthesis error). The caller keeps A unread; the queue advances.
        XCTAssertEqual(q.finished(), "B")
        XCTAssertEqual(q.inFlight, "B")
    }

    func testReplyPreemptsAndResumesUpdate() {
        let q = LivePlaybackQueue()
        _ = q.enqueue("A", isBusy: false)   // A playing
        q.replyStarted()                     // reply preempts A
        XCTAssertTrue(q.replyActive)
        XCTAssertNil(q.inFlight)
        XCTAssertEqual(q.pending, "A")       // A requeued
        // A new update arriving during the reply would NOT start (reply active).
        XCTAssertNil(q.enqueue("A", isBusy: true))
        // Reply ends -> A resumes.
        XCTAssertEqual(q.replyFinished(), "A")
        XCTAssertEqual(q.inFlight, "A")
    }

    func testNewerUpdateReplacesPreemptedOne() {
        // INF-161 point 5: never stack more than one pending; newest wins.
        let q = LivePlaybackQueue()
        _ = q.enqueue("A", isBusy: false)
        q.replyStarted()                 // A requeued as pending
        XCTAssertEqual(q.pending, "A")
        _ = q.enqueue("B", isBusy: true) // B arrives during reply, replaces A
        XCTAssertEqual(q.pending, "B")
        XCTAssertEqual(q.replyFinished(), "B")
    }

    func testUpdateDoesNotInterruptUnrelatedPreview() {
        // A voice sample is playing (isBusy, but not tracked as inFlight/reply).
        let q = LivePlaybackQueue()
        XCTAssertNil(q.enqueue("A", isBusy: true))  // queues behind the preview
        XCTAssertEqual(q.pending, "A")
        // When the preview ends the queue drains.
        XCTAssertEqual(q.replyFinished(), "A")
    }

    func testReconcileClearsStaleInFlightWhenIdle() {
        let q = LivePlaybackQueue()
        _ = q.enqueue("A", isBusy: false)   // inFlight = A
        // A manual play/stop preempted A without a finish callback; player is idle.
        q.reconcile(isBusy: false)
        XCTAssertNil(q.inFlight)
        // A new update now plays instead of wedging.
        XCTAssertEqual(q.enqueue("B", isBusy: false), "B")
    }

    func testReconcileKeepsInFlightWhileBusy() {
        let q = LivePlaybackQueue()
        _ = q.enqueue("A", isBusy: false)
        q.reconcile(isBusy: true)   // still playing A
        XCTAssertEqual(q.inFlight, "A")
    }

    func testSecondCardArrivingMidPlayQueuesBehindAndDoesNotInterrupt() {
        // A new live update arriving while one is playing must queue to play next,
        // never preempt the card currently speaking.
        let q = LivePlaybackQueue()
        XCTAssertEqual(q.enqueue("A", isBusy: false), "A")   // A is playing
        XCTAssertNil(q.enqueue("B", isBusy: true), "B must not start while A plays")
        XCTAssertEqual(q.inFlight, "A", "the playing card is never interrupted by a new arrival")
        XCTAssertEqual(q.pending, "B", "the new arrival waits to play next")
        XCTAssertEqual(q.finished(), "B", "B plays only after A finishes")
        XCTAssertEqual(q.inFlight, "B")
    }
}
