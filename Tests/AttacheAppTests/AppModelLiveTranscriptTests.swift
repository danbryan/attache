import AppKit
import AttacheCore
import XCTest
@testable import AttacheApp

/// The live-call running transcript wired into AppModel (combination "B + A"):
/// the transcript projection with speaker + replayable card id, the private-call
/// clear-at-hang-up guarantee, that a normal call's turns remain in History, the
/// hang-up context boundary, the pin preference (persisted, default off), and
/// the peek-vs-pin lifecycle.
@MainActor
final class AppModelLiveTranscriptTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private var savedPin: Any?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        savedPin = defaults.object(forKey: AttachePreferenceKey.transcriptPanelPinned)
        defaults.removeObject(forKey: AttachePreferenceKey.transcriptPanelPinned)
    }

    override func tearDown() {
        if let savedPin { defaults.set(savedPin, forKey: AttachePreferenceKey.transcriptPanelPinned) }
        else { defaults.removeObject(forKey: AttachePreferenceKey.transcriptPanelPinned) }
        super.tearDown()
    }

    // MARK: - Transcript projection

    func testTranscriptExposesTurnsInOrderWithSpeakerAndReplayableCardID() throws {
        let store = try CardStore.inMemory()
        let model = AppModel(store: store)
        model.startConversation()
        defer { model.endConversation() }

        model.appendUserTurnForTesting("How's the build?")
        model.deliverAssistantReplyForTesting("Green across the board.")

        let transcript = model.liveCallTranscript
        XCTAssertEqual(transcript.entries.map(\.speaker), [.user, .attache])
        XCTAssertEqual(transcript.entries.map(\.text), ["How's the build?", "Green across the board."])
        XCTAssertEqual(transcript.pinnedText, "Green across the board.")
        XCTAssertEqual(transcript.newestEntryID, transcript.entries.last?.id)

        // The Attaché turn is replayable: its card id resolves to a real card.
        let attacheEntry = try XCTUnwrap(transcript.entries.last)
        let cardID = try XCTUnwrap(attacheEntry.replayCardID)
        XCTAssertTrue(model.cards.contains { $0.id == cardID })
        XCTAssertFalse(transcript.entries[0].isReplayable, "user turns are not replayable")
    }

    // MARK: - Private call: memory only, cleared at hang-up, no history

    func testPrivateCallKeepsTranscriptInMemoryWritesNoHistoryAndClearsAtHangUp() throws {
        let store = try CardStore.inMemory()
        let model = AppModel(store: store)
        model.startConversation(storageMode: .privateCall)
        XCTAssertTrue(model.isPrivateConversation)

        model.appendUserTurnForTesting("Secret question")
        model.deliverAssistantReplyForTesting("Secret answer")

        // Visible during the call, in memory only.
        XCTAssertEqual(model.liveCallTranscript.entries.count, 2)
        // No card written, and the Attaché turn carries no replay id.
        XCTAssertEqual(try store.fetchCards(includeArchived: true).count, 0)
        XCTAssertNil(model.liveCallTranscript.pinnedEntry?.replayCardID)

        model.endConversation()

        // Cleared at hang-up: no history, nothing lingering in view.
        XCTAssertTrue(model.liveCallTranscript.isEmpty)
        XCTAssertEqual(try store.fetchCards(includeArchived: true).count, 0)
        XCTAssertEqual(model.callHangUpNote, "Not recorded")
    }

    // MARK: - Normal call: turns remain in History

    func testNormalCallTurnsRemainInHistoryAfterHangUp() throws {
        let store = try CardStore.inMemory()
        let model = AppModel(store: store)
        model.startConversation()

        model.appendUserTurnForTesting("Q")
        model.deliverAssistantReplyForTesting("A saved answer")

        XCTAssertEqual(try store.fetchCards(includeArchived: true).count, 1)

        model.endConversation()

        // The in-view transcript clears, but the reply card stays in History.
        XCTAssertTrue(model.liveCallTranscript.isEmpty)
        XCTAssertEqual(try store.fetchCards(includeArchived: true).count, 1)
        XCTAssertEqual(model.callHangUpNote, "Saved to History")
    }

    // MARK: - Hang-up is a context boundary

    func testNewCallDoesNotInheritPriorCallsTurns() throws {
        let store = try CardStore.inMemory()
        let model = AppModel(store: store)

        model.startConversation()
        model.appendUserTurnForTesting("First call turn")
        model.deliverAssistantReplyForTesting("First call reply")
        model.endConversation()

        model.startConversation()
        defer { model.endConversation() }
        XCTAssertTrue(model.liveCallTranscript.isEmpty, "a fresh call starts with no transcript")
    }

    // MARK: - Pin preference: persisted, default off

    func testPinPreferenceDefaultsOffAndPersistsAcrossModels() throws {
        let model = AppModel(store: try CardStore.inMemory())
        XCTAssertFalse(model.transcriptPanelPinned, "pin defaults off")
        XCTAssertFalse(model.transcriptPanelOpen)

        model.setTranscriptPanelPinned(true)
        XCTAssertTrue(defaults.bool(forKey: AttachePreferenceKey.transcriptPanelPinned))

        let reloaded = AppModel(store: try CardStore.inMemory())
        XCTAssertTrue(reloaded.transcriptPanelPinned, "pin persists across models")
        XCTAssertTrue(reloaded.transcriptPanelOpen)
    }

    // MARK: - Peek vs pin lifecycle

    func testPeekOpensButDoesNotSurviveHangUpWhilePinDoes() throws {
        let model = AppModel(store: try CardStore.inMemory())

        model.startConversation()
        model.showTranscriptPanel()
        XCTAssertTrue(model.transcriptPanelOpen)
        XCTAssertFalse(model.transcriptPanelPinned, "chevron/menu open is a peek, not a pin")

        model.endConversation()
        XCTAssertFalse(model.transcriptPanelOpen, "a peek never survives hang-up")

        // Pinned stays open across the next call boundary.
        model.setTranscriptPanelPinned(true)
        model.startConversation()
        defer { model.endConversation() }
        XCTAssertTrue(model.transcriptPanelOpen)
        model.endConversation()
        XCTAssertTrue(model.transcriptPanelOpen, "pin persists across calls")
        model.startConversation()
    }

    func testShortcutTogglesOpenAndClosed() throws {
        let model = AppModel(store: try CardStore.inMemory())
        model.startConversation()
        defer { model.endConversation() }

        XCTAssertFalse(model.transcriptPanelOpen)
        model.toggleTranscriptPanel()
        XCTAssertTrue(model.transcriptPanelOpen)
        model.toggleTranscriptPanel()
        XCTAssertFalse(model.transcriptPanelOpen)
    }
}
