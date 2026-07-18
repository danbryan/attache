import AttacheCore
import XCTest

/// Full routing matrix for the INF-374 live-vs-voicemail decision. Each case
/// pins one of the three regressions the pure router closes.
final class LivePlaybackRouterTests: XCTestCase {
    private func route(
        liveCallActive: Bool = true,
        eventIsFromLiveAgent: Bool = true,
        sessionIsCallTarget: Bool = true,
        audioPlaying: Bool = false,
        settingsOverlayOpen: Bool = false
    ) -> LivePlaybackRouting {
        LivePlaybackRouter.route(
            liveCallActive: liveCallActive,
            eventIsFromLiveAgent: eventIsFromLiveAgent,
            sessionIsCallTarget: sessionIsCallTarget,
            audioPlaying: audioPlaying,
            settingsOverlayOpen: settingsOverlayOpen
        )
    }

    // MARK: Live call, on target

    func testLiveCallIdlePlaysNow() {
        XCTAssertEqual(route(audioPlaying: false), .playNow)
    }

    func testLiveCallWhilePlayingQueuesNext() {
        // Symptom 1: a follow-up mid-speech must queue and play next, not fall to
        // unread voicemail.
        XCTAssertEqual(route(audioPlaying: true), .queueNext)
    }

    func testLiveCallOnTargetNeverRoutesToVoicemailRegardlessOfAudio() {
        // Symptom 2: a live call's own updates never become voicemail, whether or
        // not audio happens to be playing.
        XCTAssertNotEqual(route(audioPlaying: false), .voicemail)
        XCTAssertNotEqual(route(audioPlaying: true), .voicemail)
    }

    // MARK: Not live

    func testNotOnCallIsVoicemail() {
        XCTAssertEqual(route(liveCallActive: false, audioPlaying: false), .voicemail)
        XCTAssertEqual(route(liveCallActive: false, audioPlaying: true), .voicemail)
    }

    // MARK: Off target / wrong source

    func testUnwatchedNonTargetSessionIsVoicemailEvenOnCall() {
        XCTAssertEqual(route(sessionIsCallTarget: false), .voicemail)
    }

    func testNonLiveAgentSourceIsVoicemail() {
        XCTAssertEqual(route(eventIsFromLiveAgent: false), .voicemail)
    }

    // MARK: Do-not-disturb (INF-377 forward wiring)

    func testSettingsOverlayOpenDivertsLiveCallToVoicemail() {
        XCTAssertEqual(route(audioPlaying: false, settingsOverlayOpen: true), .voicemail)
        XCTAssertEqual(route(audioPlaying: true, settingsOverlayOpen: true), .voicemail)
    }

    func testSettingsOverlayDefaultsClosedSoLiveCallStillSpeaks() {
        // The parameter defaults false: current callers get live playback until
        // INF-377 supplies the input.
        XCTAssertEqual(
            LivePlaybackRouter.route(
                liveCallActive: true,
                eventIsFromLiveAgent: true,
                sessionIsCallTarget: true,
                audioPlaying: false
            ),
            .playNow
        )
    }
}
