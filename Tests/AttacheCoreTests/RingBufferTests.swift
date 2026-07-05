import AttacheCore
import XCTest

final class RingBufferTests: XCTestCase {
    func testSequentialFillWithinCapacity() {
        var ring = RingBuffer(capacity: 4)
        ring.append([1, 2, 3])
        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(ring.latest(3), [1, 2, 3])
    }

    func testLatestBeyondCountIncludesLeadingZeros() {
        var ring = RingBuffer(capacity: 4)
        ring.append([1, 2])
        XCTAssertEqual(ring.latest(4), [0, 0, 1, 2])
    }

    func testWraparoundAcrossAppends() {
        var ring = RingBuffer(capacity: 4)
        ring.append([1, 2, 3])
        ring.append([4, 5])
        XCTAssertEqual(ring.count, 4)
        XCTAssertEqual(ring.latest(4), [2, 3, 4, 5])
    }

    func testExactCapacityAppend() {
        var ring = RingBuffer(capacity: 4)
        ring.append([1, 2, 3, 4])
        XCTAssertEqual(ring.count, 4)
        XCTAssertEqual(ring.latest(4), [1, 2, 3, 4])
    }

    func testAppendLargerThanCapacityKeepsMostRecent() {
        var ring = RingBuffer(capacity: 3)
        ring.append([1, 2, 3, 4, 5])
        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(ring.latest(3), [3, 4, 5])
    }

    func testEmptyAppendAndZeroLatestAreNoops() {
        var ring = RingBuffer(capacity: 4)
        ring.append([1, 2])
        ring.append([])
        XCTAssertEqual(ring.count, 2)
        XCTAssertEqual(ring.latest(0), [])
    }
}
