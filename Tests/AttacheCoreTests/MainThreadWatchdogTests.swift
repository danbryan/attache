import XCTest
@testable import AttacheCore

final class MainThreadWatchdogTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testSyntheticFourHundredMillisecondStallProducesOneEventInThe250To500Bucket() {
        let watchdog = MainThreadWatchdog()

        let event = watchdog.recordDispatchLatency(0.4, context: "call.live", timestamp: referenceDate)

        XCTAssertEqual(event?.bucket, .ms250to500)
        let report = watchdog.report()
        XCTAssertEqual(report.count, 1)
        XCTAssertEqual(report.first?.bucket, .ms250to500)
        XCTAssertEqual(report.first?.context, "call.live")
        XCTAssertEqual(report.first?.duration, 0.4)
    }

    func testLatencyBelowThresholdIsNotRecorded() {
        let watchdog = MainThreadWatchdog()

        let event = watchdog.recordDispatchLatency(0.1, context: "idle", timestamp: referenceDate)

        XCTAssertNil(event)
        XCTAssertTrue(watchdog.report().isEmpty)
    }

    func testBucketBoundaries() {
        XCTAssertNil(StallDurationBucket.bucket(forDuration: 0.249))
        XCTAssertEqual(StallDurationBucket.bucket(forDuration: 0.25), .ms250to500)
        XCTAssertEqual(StallDurationBucket.bucket(forDuration: 0.499), .ms250to500)
        XCTAssertEqual(StallDurationBucket.bucket(forDuration: 0.5), .ms500to1s)
        XCTAssertEqual(StallDurationBucket.bucket(forDuration: 0.999), .ms500to1s)
        XCTAssertEqual(StallDurationBucket.bucket(forDuration: 1.0), .s1to2)
        XCTAssertEqual(StallDurationBucket.bucket(forDuration: 1.999), .s1to2)
        XCTAssertEqual(StallDurationBucket.bucket(forDuration: 2.0), .over2s)
        XCTAssertEqual(StallDurationBucket.bucket(forDuration: 5.0), .over2s)
    }

    func testReportIsCappedAtTwoHundredEvents() {
        let watchdog = MainThreadWatchdog()

        for i in 0..<(MainThreadWatchdog.maxStoredEvents + 25) {
            watchdog.recordDispatchLatency(
                0.3,
                context: "idle",
                timestamp: referenceDate.addingTimeInterval(Double(i))
            )
        }

        let report = watchdog.report()
        XCTAssertEqual(report.count, MainThreadWatchdog.maxStoredEvents)
        // The oldest events were evicted; the report should retain the most recent ones.
        XCTAssertEqual(report.last?.timestamp, referenceDate.addingTimeInterval(Double(MainThreadWatchdog.maxStoredEvents + 24)))
    }

    func testResetClearsEvents() {
        let watchdog = MainThreadWatchdog()
        watchdog.recordDispatchLatency(0.4, context: "call.live", timestamp: referenceDate)
        XCTAssertEqual(watchdog.report().count, 1)

        watchdog.reset()

        XCTAssertTrue(watchdog.report().isEmpty)
    }
}
