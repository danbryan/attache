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

    func testMeteredFallbackDrivesBarsBeforeFullAnalysisIsReady() {
        let audible = SpeechPlaybackController.meteredFrame(
            averagePowerDB: -24,
            peakPowerDB: -12
        )
        XCTAssertGreaterThan(audible.rms, 0)
        XCTAssertGreaterThan(audible.peak, audible.rms)
        XCTAssertEqual(audible.bands.count, 56)
        XCTAssertGreaterThan(audible.bands.max() ?? 0, 0)

        let silent = SpeechPlaybackController.meteredFrame(
            averagePowerDB: -160,
            peakPowerDB: -160
        )
        XCTAssertEqual(silent.rms, 0)
        XCTAssertEqual(silent.bands.max(), 0)
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
