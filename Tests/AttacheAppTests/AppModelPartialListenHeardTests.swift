import AppKit
import AttacheCore
import XCTest
@testable import AttacheApp

/// The inbox -> History lifecycle: a voicemail the user listened to past the
/// heard threshold moves from the unread inbox into History even when playback
/// ended early (Escape, starting another card, hang-up), not only on a full
/// finish. The threshold decision itself is proven purely in
/// `PlaybackReliabilityTests`; these drive the AppModel wiring the controller's
/// `onCardReachedHeardThreshold` callback feeds.
@MainActor
final class AppModelPartialListenHeardTests: XCTestCase {
    private func agentEvent(sessionID: String) -> NormalizedEvent {
        NormalizedEvent(
            source: SourceKind.codex.rawValue,
            eventType: "agent_message",
            externalSessionID: sessionID,
            title: "Update",
            text: "The migration finished and the tests are green."
        )
    }

    /// A card listened to past the threshold and then stopped leaves the unread
    /// inbox and enters History (the exact data source the ⌘Y palette reads).
    func testPartialListenMovesUnreadCardToHistory() throws {
        _ = NSApplication.shared
        let store = try CardStore.inMemory()
        let card = try store.insertEvent(agentEvent(sessionID: "partial-\(UUID().uuidString)"))
        let model = AppModel(store: store)
        model.reloadCards()

        XCTAssertEqual(model.unreadCount, 1)
        XCTAssertTrue(model.historyCards.isEmpty)
        XCTAssertTrue(model.historyCards(for: .all).isEmpty)

        // The controller reports the card past the threshold on an early-exit path
        // (stop / preemption / hang-up). This is what SpeechPlaybackController.stop()
        // invokes when the high-water fraction cleared HeardThreshold.
        model.playback.onCardReachedHeardThreshold?(card.id)

        XCTAssertEqual(model.unreadCount, 0, "a partial listen past the threshold leaves the inbox")
        XCTAssertTrue(model.unreadCards.isEmpty)
        XCTAssertEqual(model.cards.first(where: { $0.id == card.id })?.status, .heard)
        XCTAssertEqual(model.historyCards.map(\.id), [card.id], "the card is now History")
        XCTAssertEqual(
            model.historyCards(for: .all).map(\.id), [card.id],
            "the ⌘Y History palette's data source renders the heard card"
        )
        XCTAssertEqual(model.historyCount(for: .all), 1)
    }

    /// A below-threshold card is never reported by the controller, so it stays an
    /// unread voicemail (nothing is lost when playback stops early).
    func testBelowThresholdCardStaysUnread() throws {
        _ = NSApplication.shared
        let store = try CardStore.inMemory()
        let card = try store.insertEvent(agentEvent(sessionID: "below-\(UUID().uuidString)"))
        let model = AppModel(store: store)
        model.reloadCards()

        XCTAssertEqual(model.unreadCount, 1)
        // No onCardReachedHeardThreshold call: the controller only fires it once the
        // high-water fraction clears the threshold. The card remains unread.
        XCTAssertEqual(model.cards.first(where: { $0.id == card.id })?.status, .unread)
        XCTAssertEqual(model.unreadCount, 1)
        XCTAssertTrue(model.historyCards.isEmpty)
    }

    /// The partial-listen callback is a no-op on a card already filed heard, so a
    /// focused-call card (filed heard directly at intake, never an unread step) is
    /// never disturbed by a late threshold report.
    func testPartialListenIsNoOpOnAlreadyHeardCard() throws {
        _ = NSApplication.shared
        let store = try CardStore.inMemory()
        let card = try store.insertEvent(
            agentEvent(sessionID: "heard-\(UUID().uuidString)"),
            status: .heard
        )
        let model = AppModel(store: store)
        model.reloadCards()

        XCTAssertEqual(model.unreadCount, 0)
        XCTAssertEqual(model.historyCards.map(\.id), [card.id])

        // A stray threshold report for an already-heard card must not error or
        // change anything.
        model.playback.onCardReachedHeardThreshold?(card.id)

        XCTAssertEqual(model.unreadCount, 0)
        XCTAssertEqual(model.cards.first(where: { $0.id == card.id })?.status, .heard)
        XCTAssertEqual(model.historyCards.map(\.id), [card.id])
    }
}
