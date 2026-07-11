import XCTest
@testable import AttacheApp

/// Non-bypass proof for the screenshot-matrix pose override (INF-244), the
/// same shape as `InstructionReplyEngineTests.testExpiryWindowOverrideRequiresUITestFlag`
/// and `PlaybackReliabilityTests.testSmokeMuteIsScopedToExplicitEnvironmentFlag`:
/// the pose flag must require ATTACHE_UI_TEST=1 to also be present, so a real
/// user's environment can never trigger it by itself.
final class MicTranscriptControllerForceListeningTests: XCTestCase {
    func testForcedListeningRequiresUITestFlag() {
        XCTAssertTrue(MicTranscriptController.shouldForceListeningForPose(environment: [
            "ATTACHE_UI_TEST": "1",
            "ATTACHE_UI_TEST_FORCE_LISTENING": "1"
        ]))

        // The pose flag alone, without ATTACHE_UI_TEST=1, must not count.
        XCTAssertFalse(MicTranscriptController.shouldForceListeningForPose(environment: [
            "ATTACHE_UI_TEST_FORCE_LISTENING": "1"
        ]))

        // ATTACHE_UI_TEST=1 alone (every headed smoke run) must not force
        // listening by itself.
        XCTAssertFalse(MicTranscriptController.shouldForceListeningForPose(environment: [
            "ATTACHE_UI_TEST": "1"
        ]))

        XCTAssertFalse(MicTranscriptController.shouldForceListeningForPose(environment: [:]))

        // A near-miss value ("true" instead of "1") must not count either: the
        // gate is the exact string the harness sets, not any truthy value.
        XCTAssertFalse(MicTranscriptController.shouldForceListeningForPose(environment: [
            "ATTACHE_UI_TEST": "true",
            "ATTACHE_UI_TEST_FORCE_LISTENING": "1"
        ]))
    }

    @MainActor
    func testApplyForcedListeningPoseOnlyFlipsWhenBothFlagsPresent() {
        let controller = MicTranscriptController()
        XCTAssertFalse(controller.isListening)

        controller.applyForcedListeningPoseIfRequested(environment: [
            "ATTACHE_UI_TEST": "1"
        ])
        XCTAssertFalse(controller.isListening, "the pose flag alone must not have flipped isListening")

        controller.applyForcedListeningPoseIfRequested(environment: [
            "ATTACHE_UI_TEST": "1",
            "ATTACHE_UI_TEST_FORCE_LISTENING": "1"
        ])
        XCTAssertTrue(controller.isListening)
    }
}
