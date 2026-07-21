import XCTest
@testable import AttacheApp

/// Non-bypass proof for the UI-smoke background-mode focus suppression, the same
/// shape as `MicTranscriptControllerForceListeningTests` and
/// `PremiumVoiceFakeGateTests`: the background flag must require
/// ATTACHE_UI_TEST=1 to also be present, so a real user's environment can never
/// suppress the app's own foreground activation by itself.
final class AppActivationTests: XCTestCase {
    func testForegroundSuppressionRequiresBothFlags() {
        XCTAssertTrue(AppActivation.shouldSuppressForeground(environment: [
            "ATTACHE_UI_TEST": "1",
            "ATTACHE_UI_TEST_BACKGROUND": "1"
        ]))

        // The background flag alone, without ATTACHE_UI_TEST=1, must not count.
        XCTAssertFalse(AppActivation.shouldSuppressForeground(environment: [
            "ATTACHE_UI_TEST_BACKGROUND": "1"
        ]))

        // ATTACHE_UI_TEST=1 alone (every headed smoke run) must keep the app's
        // normal foreground activation.
        XCTAssertFalse(AppActivation.shouldSuppressForeground(environment: [
            "ATTACHE_UI_TEST": "1"
        ]))

        XCTAssertFalse(AppActivation.shouldSuppressForeground(environment: [:]))

        // A near-miss value ("true" instead of "1") must not count either: the
        // gate is the exact string the harness sets, not any truthy value.
        XCTAssertFalse(AppActivation.shouldSuppressForeground(environment: [
            "ATTACHE_UI_TEST": "1",
            "ATTACHE_UI_TEST_BACKGROUND": "true"
        ]))
    }
}
