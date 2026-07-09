import XCTest
@testable import AttacheApp

final class PlaybackReliabilityTests: XCTestCase {
    func testSmokeMuteIsScopedToExplicitEnvironmentFlag() {
        XCTAssertTrue(SpeechPlaybackController.shouldMuteAudioOutput(environment: [
            "ATTACHE_UI_TEST_MUTE_AUDIO": "1"
        ]))
        XCTAssertFalse(SpeechPlaybackController.shouldMuteAudioOutput(environment: [
            "ATTACHE_UI_TEST": "1"
        ]))
        XCTAssertFalse(SpeechPlaybackController.shouldMuteAudioOutput(environment: [:]))
    }

    func testRejectsImplausiblyEarlyLongClipFinish() {
        XCTAssertFalse(PlaybackCompletionValidator.isCredibleFinish(
            flag: true,
            currentTime: 103.8,
            duration: 103.8,
            elapsed: 5.0,
            startOffset: 0,
            seekCount: 0
        ))
    }

    func testAcceptsNaturalLongClipFinish() {
        XCTAssertTrue(PlaybackCompletionValidator.isCredibleFinish(
            flag: true,
            currentTime: 103.8,
            duration: 103.8,
            elapsed: 104.0,
            startOffset: 0,
            seekCount: 0
        ))
    }

    func testAcceptsFinishAfterOneExplicitSeek() {
        XCTAssertTrue(PlaybackCompletionValidator.isCredibleFinish(
            flag: true,
            currentTime: 103.8,
            duration: 103.8,
            elapsed: 3.0,
            startOffset: 0,
            seekCount: 1
        ))
    }

    func testRejectsSeekStormAndIncompletePosition() {
        XCTAssertFalse(PlaybackCompletionValidator.isCredibleFinish(
            flag: true,
            currentTime: 103.8,
            duration: 103.8,
            elapsed: 5.0,
            startOffset: 0,
            seekCount: 12
        ))
        XCTAssertFalse(PlaybackCompletionValidator.isCredibleFinish(
            flag: true,
            currentTime: 12.0,
            duration: 103.8,
            elapsed: 12.0,
            startOffset: 0,
            seekCount: 0
        ))
    }
}
