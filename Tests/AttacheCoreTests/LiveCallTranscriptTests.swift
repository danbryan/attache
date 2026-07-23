import XCTest
@testable import AttacheCore

/// Pure view-model behind the live-call running transcript (combination "B + A"):
/// ordered entries with speaker and replayable card id, the pinned latest-turn
/// card, the "N earlier" chevron count, the auto-scroll target, currently-spoken
/// highlight, and the pin/peek panel state machine.
final class LiveCallTranscriptTests: XCTestCase {

    private func entry(_ id: String, _ speaker: LiveCallSpeaker, _ text: String, card: String? = nil) -> LiveCallTranscriptEntry {
        LiveCallTranscriptEntry(id: id, speaker: speaker, text: text, replayCardID: card)
    }

    // MARK: - Ordering, speaker, replayable card id

    func testEntriesExposeOrderSpeakerAndReplayCardID() {
        let transcript = LiveCallTranscript(entries: [
            entry("u1", .user, "How's the build?"),
            entry("a1", .attache, "Green.", card: "card-1"),
            entry("u2", .user, "And the tests?"),
            entry("a2", .attache, "All passing.", card: "card-2")
        ])

        XCTAssertEqual(transcript.entries.map(\.id), ["u1", "a1", "u2", "a2"])
        XCTAssertEqual(transcript.entries.map(\.speaker), [.user, .attache, .user, .attache])
        XCTAssertEqual(transcript.entries.first(where: { $0.id == "a1" })?.replayCardID, "card-1")
        XCTAssertTrue(transcript.entries.first(where: { $0.id == "a2" })!.isReplayable)
        XCTAssertFalse(transcript.entries.first(where: { $0.id == "u1" })!.isReplayable)
    }

    // MARK: - Auto-scroll target is the newest turn

    func testNewestEntryIDIsTheLastTurn() {
        let transcript = LiveCallTranscript(entries: [
            entry("u1", .user, "One"),
            entry("a1", .attache, "Two", card: "c1")
        ])
        XCTAssertEqual(transcript.newestEntryID, "a1")
        XCTAssertNil(LiveCallTranscript().newestEntryID)
    }

    // MARK: - Pinned last-turn card tracks the latest Attaché turn

    func testPinnedEntryIsLatestAttacheTurnEvenAfterANewerUserTurn() {
        let transcript = LiveCallTranscript(entries: [
            entry("a1", .attache, "First reply", card: "c1"),
            entry("a2", .attache, "Second reply", card: "c2"),
            entry("u1", .user, "A follow-up the user just typed")
        ])
        XCTAssertEqual(transcript.pinnedEntry?.id, "a2")
        XCTAssertEqual(transcript.pinnedText, "Second reply")
    }

    func testPinnedEntryIsNilWithNoAttacheTurnYet() {
        let transcript = LiveCallTranscript(entries: [entry("u1", .user, "Hello?")])
        XCTAssertNil(transcript.pinnedEntry)
        XCTAssertNil(transcript.pinnedText)
    }

    // MARK: - "N earlier" chevron count

    func testEarlierTurnCountIsTurnsBeforeThePinnedTurn() {
        let transcript = LiveCallTranscript(entries: [
            entry("u1", .user, "Q1"),
            entry("a1", .attache, "A1", card: "c1"),
            entry("u2", .user, "Q2"),
            entry("a2", .attache, "A2", card: "c2")
        ])
        // Pinned is a2 at index 3, so three turns come before it.
        XCTAssertEqual(transcript.earlierTurnCount, 3)
    }

    func testEarlierTurnCountIsZeroWhenPinnedIsFirstTurn() {
        let transcript = LiveCallTranscript(entries: [
            entry("a1", .attache, "Only reply", card: "c1")
        ])
        XCTAssertEqual(transcript.earlierTurnCount, 0)
    }

    // MARK: - Currently-spoken highlight

    func testSpeakingEntryMatchesSpokenTextWhilePlaying() {
        let transcript = LiveCallTranscript(entries: [
            entry("a1", .attache, "The build is green.", card: "c1"),
            entry("u1", .user, "Great"),
            entry("a2", .attache, "Tests pass too.", card: "c2")
        ])
        XCTAssertEqual(
            transcript.speakingEntryID(spokenText: "  Tests pass too.  ", isPlaying: true),
            "a2"
        )
        XCTAssertNil(transcript.speakingEntryID(spokenText: "Tests pass too.", isPlaying: false))
        XCTAssertNil(transcript.speakingEntryID(spokenText: "", isPlaying: true))
        XCTAssertNil(transcript.speakingEntryID(spokenText: "not a turn", isPlaying: true))
    }

    // MARK: - Pin/peek panel state machine

    func testDefaultPanelIsClosedAndUnpinned() {
        let state = TranscriptPanelPresentation()
        XCTAssertFalse(state.isOpen)
        XCTAssertFalse(state.pinned)
        XCTAssertFalse(state.peeking)
    }

    func testOpenPeekOpensWithoutPinning() {
        var state = TranscriptPanelPresentation()
        state.openPeek()
        XCTAssertTrue(state.isOpen)
        XCTAssertTrue(state.peeking)
        XCTAssertFalse(state.pinned)
    }

    func testPinningSupersedesPeekAndPersistsAcrossCalls() {
        var state = TranscriptPanelPresentation()
        state.openPeek()
        state.setPinned(true)
        XCTAssertTrue(state.pinned)
        XCTAssertFalse(state.peeking, "pinning clears the transient peek")
        XCTAssertTrue(state.isOpen)

        // A peek never survives hang-up; the pin does.
        state.callEnded()
        XCTAssertTrue(state.isOpen)
        XCTAssertTrue(state.pinned)
    }

    func testPeekDoesNotSurviveHangUp() {
        var state = TranscriptPanelPresentation()
        state.openPeek()
        state.callEnded()
        XCTAssertFalse(state.isOpen)
        XCTAssertFalse(state.peeking)
    }

    func testShortcutTogglesOpenAndClosingUnpins() {
        var state = TranscriptPanelPresentation()
        // Closed -> peek open.
        state.toggleShortcut()
        XCTAssertTrue(state.isOpen)
        XCTAssertTrue(state.peeking)
        // Peek open -> closed.
        state.toggleShortcut()
        XCTAssertFalse(state.isOpen)

        // A pinned panel closed via the shortcut also unpins, so a deliberate
        // close is not reopened on the next call.
        state.setPinned(true)
        XCTAssertTrue(state.isOpen)
        state.toggleShortcut()
        XCTAssertFalse(state.isOpen)
        XCTAssertFalse(state.pinned)
    }

    func testUnpinningClosesWhenNotPeeking() {
        var state = TranscriptPanelPresentation(pinned: true)
        XCTAssertTrue(state.isOpen)
        state.setPinned(false)
        XCTAssertFalse(state.isOpen)
    }
}
