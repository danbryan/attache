import XCTest
@testable import AttacheApp

final class PlaybackReliabilityTests: XCTestCase {
    func testLegacyNarrationCacheIsHardenedBeforeReuse() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-audio-cache-permissions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("private-recap.aiff")
        XCTAssertTrue(FileManager.default.createFile(atPath: audio.path, contents: Data("private narration".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: audio.path)

        try SpeechPlaybackController.securePrivateAudioDirectory(at: root)

        let rootAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual(((rootAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o700)
        let audioAttributes = try FileManager.default.attributesOfItem(atPath: audio.path)
        XCTAssertEqual(((audioAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o600)
        XCTAssertTrue(SpeechPlaybackController.securePrivateAudioFile(at: audio))
    }

    func testInboxReloadNeverPreSynthesizesUnplayedVoicemail() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appModel = try String(contentsOf: root.appendingPathComponent(
            "Sources/AttacheApp/AppModel.swift"
        ))

        XCTAssertFalse(
            appModel.contains("prepareAudioCache(for:"),
            "Off-call voicemail synthesis must begin only after Play, Preview, catch-up, or live delivery."
        )
    }

    func testOnCallLiveQueueDrainIsNotReGatedOnVoicemailMode() throws {
        // INF-374 symptom 1: the on-call live-queue drain must not require
        // `!voicemailMode` (which defaults on and a call never clears), or
        // queued updates strand as unread voicemail mid-call. Guarding the drain
        // on `onCall` alone still blocks an off-call manual replay from chaining.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appModel = try String(contentsOf: root.appendingPathComponent(
            "Sources/AttacheApp/AppModel.swift"
        ))
        XCTAssertFalse(
            appModel.contains("if onCall, !voicemailMode, let next"),
            "The on-call live-queue drain must not be re-gated on voicemailMode (INF-374)."
        )
        XCTAssertTrue(
            appModel.contains("if onCall, let next {\n            playCardLive(cardID: next)"),
            "The live queue must drain whenever on a call so queued updates play next (INF-374)."
        )
    }

    func testDisplacedPendingLiveUpdateIsMarkedHeardNotLeftUnread() throws {
        // INF-374 symptom 3: newest-wins coalescing drops an earlier pending
        // live update; it must be marked heard, never left as unread voicemail.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appModel = try String(contentsOf: root.appendingPathComponent(
            "Sources/AttacheApp/AppModel.swift"
        ))
        XCTAssertTrue(
            appModel.contains("let displacedPending = livePlaybackQueue.pending"),
            "The live path must capture a superseded pending update (INF-374)."
        )
        XCTAssertTrue(
            appModel.contains("try? store.markHeard(cardID: displacedPending)"),
            "A superseded pending live update must be marked heard, not left unread (INF-374)."
        )
    }

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

    // MARK: - HeardThreshold (partial-listen -> History)

    func testHeardThresholdJustBelowHalfStaysUnread() {
        XCTAssertFalse(HeardThreshold.reached(maxFraction: 0.49, durationMs: 60_000, seekCount: 0))
    }

    func testHeardThresholdAtHalfMarksHeard() {
        XCTAssertTrue(HeardThreshold.reached(maxFraction: 0.50, durationMs: 60_000, seekCount: 0))
    }

    func testHeardThresholdJustAboveHalfMarksHeard() {
        XCTAssertTrue(HeardThreshold.reached(maxFraction: 0.51, durationMs: 60_000, seekCount: 0))
    }

    func testHeardThresholdFullCompletionStillMarksHeard() {
        XCTAssertTrue(HeardThreshold.reached(maxFraction: 1.0, durationMs: 60_000, seekCount: 0))
    }

    func testHeardThresholdSixtyPercentThenStoppedMarksHeard() {
        // A card played to 60% then stopped: past the threshold -> History.
        XCTAssertTrue(HeardThreshold.reached(maxFraction: 0.60, durationMs: 180_000, seekCount: 1))
    }

    func testHeardThresholdTwentyPercentThenStoppedStaysUnread() {
        // A barely-started card (20%) stopped early is not lost; it stays unread.
        XCTAssertFalse(HeardThreshold.reached(maxFraction: 0.20, durationMs: 180_000, seekCount: 0))
    }

    func testHeardThresholdSeekStormNearEndIsGuarded() {
        // A seek storm can push the high-water mark near the end without the user
        // listening; an implausible seek count must not mark a 3-minute card heard.
        XCTAssertFalse(HeardThreshold.reached(maxFraction: 0.98, durationMs: 180_000, seekCount: 12))
    }

    func testHeardThresholdAllowsAFewExplicitSeeks() {
        // A handful of seeks while genuinely listening past 50% still counts.
        XCTAssertTrue(HeardThreshold.reached(maxFraction: 0.72, durationMs: 180_000, seekCount: 4))
    }

    func testHeardThresholdMutedBlipStaysUnread() {
        // A ~2s muted blip on a 3-minute card: the genuine fraction stays tiny, so
        // it never qualifies even though a spurious finish flag might fire.
        XCTAssertFalse(HeardThreshold.reached(maxFraction: 2.0 / 180.0, durationMs: 180_000, seekCount: 0))
    }

    func testHeardThresholdTinyDurationGuard() {
        // A sub-second clip is too short to infer intent from a 50% high-water mark;
        // a genuine full play still files heard through the credible-finish path.
        XCTAssertFalse(HeardThreshold.reached(maxFraction: 1.0, durationMs: 500, seekCount: 0))
        XCTAssertFalse(HeardThreshold.reached(maxFraction: 1.0, durationMs: 0, seekCount: 0))
    }
}
