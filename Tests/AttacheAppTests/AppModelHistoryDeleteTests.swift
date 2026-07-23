import AppKit
import AttacheCore
import XCTest
@testable import AttacheApp

/// History multi-select permanent delete (`AppModel.deleteHistoryCards(ids:)`)
/// and a guard that the existing single-item / whole-conversation right-click
/// delete (`deleteConversationHistory(containing:)`) still behaves.
@MainActor
final class AppModelHistoryDeleteTests: XCTestCase {
    private func heardEvent(id: String, conversationID: String? = nil) -> NormalizedEvent {
        var metadata: [String: String] = ["attache_summary": "Summary \(id)"]
        if let conversationID { metadata["attache_conversation_id"] = conversationID }
        return NormalizedEvent(
            source: SourceKind.generic.rawValue,
            eventType: "attache.conversation.reply",
            externalSessionID: "session-\(id)",
            title: "Reply \(id)",
            text: "Body \(id)",
            metadata: metadata
        )
    }

    // MARK: deleteHistoryCards removes exactly the given ids

    func testDeleteHistoryCardsRemovesExactlyTheGivenIdsAndLeavesOthers() throws {
        _ = NSApplication.shared
        let store = try CardStore.inMemory()
        let a = try store.insertEvent(heardEvent(id: "a"), status: .heard)
        let b = try store.insertEvent(heardEvent(id: "b"), status: .heard)
        let c = try store.insertEvent(heardEvent(id: "c"), status: .heard)
        let model = AppModel(store: store)

        model.deleteHistoryCards(ids: [a.id, c.id])

        let remaining = try store.fetchCards(includeArchived: true).map(\.id)
        XCTAssertEqual(remaining, [b.id])
        // Published history reflects the delete immediately.
        XCTAssertEqual(model.historyCards.map(\.id), [b.id])
    }

    func testDeleteHistoryCardsLeavesUnreadInboxCardsUntouched() throws {
        _ = NSApplication.shared
        let store = try CardStore.inMemory()
        let heard = try store.insertEvent(heardEvent(id: "heard"), status: .heard)
        let unread = try store.insertEvent(heardEvent(id: "unread"), status: .unread)
        let model = AppModel(store: store)

        model.deleteHistoryCards(ids: [heard.id])

        let remaining = try store.fetchCards(includeArchived: true).map(\.id)
        XCTAssertEqual(remaining, [unread.id], "the unread inbox card must survive a history delete")
        XCTAssertTrue(model.historyCards.isEmpty)
    }

    func testDeleteHistoryCardsIsPerCardNotPerConversation() throws {
        _ = NSApplication.shared
        let store = try CardStore.inMemory()
        // Two cards in the same conversation; delete only one of them.
        let convo = "convo-1"
        let first = try store.insertEvent(heardEvent(id: "first", conversationID: convo), status: .heard)
        let second = try store.insertEvent(heardEvent(id: "second", conversationID: convo), status: .heard)
        let model = AppModel(store: store)

        model.deleteHistoryCards(ids: [first.id])

        let remaining = try store.fetchCards(includeArchived: true).map(\.id)
        XCTAssertEqual(remaining, [second.id],
                       "multi-select delete must remove exactly the checked card, not the whole conversation")
    }

    func testDeleteHistoryCardsWithEmptyIdsIsNoOp() throws {
        _ = NSApplication.shared
        let store = try CardStore.inMemory()
        let a = try store.insertEvent(heardEvent(id: "a"), status: .heard)
        let model = AppModel(store: store)

        model.deleteHistoryCards(ids: [])

        XCTAssertEqual(try store.fetchCards(includeArchived: true).map(\.id), [a.id])
    }

    // MARK: existing single-item / conversation right-click delete still works

    func testDeleteConversationHistoryStillDeletesWholeConversation() throws {
        _ = NSApplication.shared
        let store = try CardStore.inMemory()
        let convo = "convo-9"
        let first = try store.insertEvent(heardEvent(id: "first", conversationID: convo), status: .heard)
        _ = try store.insertEvent(heardEvent(id: "second", conversationID: convo), status: .heard)
        let survivor = try store.insertEvent(heardEvent(id: "survivor"), status: .heard)
        let model = AppModel(store: store)

        model.deleteConversationHistory(containing: first)

        let remaining = try store.fetchCards(includeArchived: true).map(\.id)
        XCTAssertEqual(remaining, [survivor.id],
                       "right-click delete of a card in a conversation still removes the whole conversation")
    }

    func testDeleteConversationHistoryLegacyCardDeletesOnlyThatCard() throws {
        _ = NSApplication.shared
        let store = try CardStore.inMemory()
        // No conversation id: legacy path deletes only the selected card.
        let a = try store.insertEvent(heardEvent(id: "a"), status: .heard)
        let b = try store.insertEvent(heardEvent(id: "b"), status: .heard)
        let model = AppModel(store: store)

        model.deleteConversationHistory(containing: a)

        XCTAssertEqual(try store.fetchCards(includeArchived: true).map(\.id), [b.id])
    }
}
