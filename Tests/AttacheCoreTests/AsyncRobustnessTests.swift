import XCTest
@testable import AttacheCore

final class AsyncRobustnessTests: XCTestCase {
    func testTimeoutReturnsOperationResultWhenFast() async {
        let result = await withTimeout(seconds: 5, operation: { "done" }, onTimeout: { "timeout" })
        XCTAssertEqual(result, "done")
    }

    func testTimeoutFiresWhenOperationStalls() async {
        let start = Date()
        let result = await withTimeout(seconds: 0.2) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5s stall
            return "done"
        } onTimeout: {
            "I could not check that in time."
        }
        XCTAssertEqual(result, "I could not check that in time.")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "should return around the timeout, not the stall")
    }

    func testRetrySucceedsAfterTransientFailure() async throws {
        actor Counter { var n = 0; func next() -> Int { n += 1; return n } }
        let counter = Counter()
        let value = try await retrying(attempts: 3, backoff: 0.01) { () async throws -> String in
            let attempt = await counter.next()
            if attempt < 2 { throw URLError(.timedOut) }
            return "ok on attempt \(attempt)"
        }
        XCTAssertEqual(value, "ok on attempt 2")
    }

    func testRetryThrowsAfterExhausting() async {
        do {
            _ = try await retrying(attempts: 2, backoff: 0.01) { () async throws -> String in
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("expected to throw")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }
}
