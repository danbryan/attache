import UserNotifications
import XCTest
@testable import AttacheApp

/// `ATTACHE_UI_TEST=1` makes `AttacheNotifier` skip the notification-permission
/// request (`requestAuthorizationIfUndetermined`), so smoke runs leave real
/// authorization status at `.notDetermined` for the whole run. Before INF-369,
/// `setApplicationBadgeCount` called `UNUserNotificationCenter.setBadgeCount`
/// unconditionally, so every unread-count update failed with
/// `UNErrorDomain error 1` and logged, flooding smoke output. This proves the
/// short-circuit that gates the actual OS write on current authorization,
/// without touching real notification permission state (no request is ever
/// made from this path; `AttacheNotifier.shouldAttemptBadgeUpdate` is a pure
/// function over `UNAuthorizationStatus`).
final class AttacheNotifierBadgeGateTests: XCTestCase {
    func testShortCircuitsWhenNotDetermined() {
        XCTAssertFalse(AttacheNotifier.shouldAttemptBadgeUpdate(authorizationStatus: .notDetermined),
                        "the ATTACHE_UI_TEST steady state must not attempt the OS write")
    }

    func testShortCircuitsWhenDenied() {
        XCTAssertFalse(AttacheNotifier.shouldAttemptBadgeUpdate(authorizationStatus: .denied))
    }

    func testProceedsWhenAuthorized() {
        XCTAssertTrue(AttacheNotifier.shouldAttemptBadgeUpdate(authorizationStatus: .authorized))
    }

    func testProceedsWhenProvisional() {
        XCTAssertTrue(AttacheNotifier.shouldAttemptBadgeUpdate(authorizationStatus: .provisional))
    }
}
