import AppKit
import AttacheCore
import XCTest
@testable import AttacheApp

@MainActor
final class AppModelConversationContextTests: XCTestCase {
    func testContextFreeConversationDoesNotInheritSelectedCardOrSessionMetadata() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let defaultsSnapshot = ConversationContextDefaultsSnapshot(
            keys: [
                AttachePreferenceKey.attachedCodexSessionID,
                AttachePreferenceKey.watchedSessions,
                AttachePreferenceKey.codexSourceEnabled,
                AttachePreferenceKey.claudeCodeSourceEnabled
            ],
            defaults: defaults
        )
        defer { defaultsSnapshot.restore() }
        defaults.set(false, forKey: AttachePreferenceKey.codexSourceEnabled)
        defaults.set(false, forKey: AttachePreferenceKey.claudeCodeSourceEnabled)

        let store = try CardStore.inMemory()
        _ = try store.insertEvent(NormalizedEvent(
            source: SourceKind.codex.rawValue,
            eventType: "assistant.completed",
            externalSessionID: "hidden-recent-session",
            projectPath: "/private/hidden-project",
            title: "Secret redesign topic",
            text: "Secret agent reply that must not enter a context-free call.",
            metadata: ["companion_summary": "Secret session summary"]
        ))

        let model = AppModel(store: store)
        XCTAssertNotNil(model.selectedCard, "precondition: a selected voicemail exists")

        model.startConversation()
        defer { model.endConversation() }

        XCTAssertNil(model.conversationTargetSnapshot)
        XCTAssertNil(model.conversationContextSession)
        XCTAssertNil(model.conversationLatestSummary)
        XCTAssertNil(model.conversationLatestAgentReply)
        XCTAssertFalse(model.canSendToAgent)
        XCTAssertEqual(model.conversationStatus, "No session attached. I can still chat.")
    }

    func testLatestAgentContextIgnoresFiledPersonalityReplies() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let defaultsSnapshot = ConversationContextDefaultsSnapshot(
            keys: [
                AttachePreferenceKey.attachedCodexSessionID,
                AttachePreferenceKey.watchedSessions,
                AttachePreferenceKey.codexSourceEnabled
            ],
            defaults: defaults
        )
        defer { defaultsSnapshot.restore() }
        let store = try CardStore.inMemory()
        let sessionID = "conversation-context-\(UUID().uuidString)"
        let target = CodexSessionTarget(
            id: sessionID,
            title: "Context test",
            updatedAt: Date(),
            category: .activeSession,
            status: nil,
            sourceKind: .codex
        )
        defaults.set(true, forKey: AttachePreferenceKey.codexSourceEnabled)
        defaults.set(sessionID, forKey: AttachePreferenceKey.attachedCodexSessionID)
        defaults.set(try JSONEncoder().encode([target]), forKey: AttachePreferenceKey.watchedSessions)
        _ = try store.insertEvent(NormalizedEvent(
            source: SourceKind.codex.rawValue,
            eventType: "assistant.completed",
            externalSessionID: sessionID,
            projectPath: "/tmp/project",
            title: "Context test",
            text: "Agent detail one. Agent detail two. Agent detail three.",
            metadata: [
                "companion_summary": "Three agent details",
                "source_time": "2026-07-10T13:40:00.000Z"
            ]
        ))
        _ = try store.insertEvent(NormalizedEvent(
            source: SourceKind.codex.rawValue,
            eventType: "companion.conversation.reply",
            externalSessionID: sessionID,
            projectPath: "/tmp/project",
            title: "Context test",
            text: "I could not find the details.",
            metadata: [
                "companion_summary": "Attaché did not find the details",
                "companion_direct_reply": "true",
                "companion_history_kind": "direct_reply",
                "source_time": "2026-07-10T13:41:00.000Z"
            ]
        ), status: .heard)

        let storedCards = try store.fetchCards()
        XCTAssertEqual(storedCards.count, 2)
        XCTAssertEqual(storedCards.first?.externalSessionID, sessionID)

        let model = AppModel(store: store)
        XCTAssertEqual(model.cards.count, 2)
        model.startConversation()

        XCTAssertEqual(model.conversationLatestSummary, "Three agent details")
        XCTAssertEqual(
            model.conversationLatestAgentReply,
            "Agent detail one. Agent detail two. Agent detail three."
        )
    }

    func testPrivateCallDisablesHistoryMemoryAndAgentWrites() throws {
        _ = NSApplication.shared
        let model = AppModel(store: try CardStore.inMemory())

        model.startConversation(storageMode: .privateCall)

        XCTAssertTrue(model.isPrivateConversation)
        XCTAssertFalse(model.conversationSavesHistory)
        XCTAssertFalse(model.conversationAllowsMemoryProposals)
        XCTAssertFalse(model.canSendToAgent)
        XCTAssertEqual(model.conversationDestination, .attache)

        model.endConversation()

        XCTAssertFalse(model.isPrivateConversation)
        XCTAssertEqual(model.conversationStorageMode, .saved)
        XCTAssertTrue(model.conversationMessages.isEmpty)
    }

    func testDeletingConversationRemovesEveryLinkedTakeButNotOtherHistory() throws {
        _ = NSApplication.shared
        let store = try CardStore.inMemory()
        let conversationID = UUID().uuidString
        func event(text: String, time: String, id: String) -> NormalizedEvent {
            NormalizedEvent(
                source: SourceKind.generic.rawValue,
                eventType: "attache.conversation.reply",
                title: "Attaché reply",
                text: text,
                metadata: [
                    "source_time": time,
                    "companion_history_kind": "direct_reply",
                    "companion_conversation_id": id
                ]
            )
        }
        let first = try store.insertEvent(event(
            text: "First answer", time: "2026-07-16T10:00:00.000Z", id: conversationID
        ))
        _ = try store.insertEvent(event(
            text: "Another take", time: "2026-07-16T10:00:01.000Z", id: conversationID
        ))
        let keep = try store.insertEvent(event(
            text: "Other conversation", time: "2026-07-16T10:00:02.000Z", id: UUID().uuidString
        ))
        let model = AppModel(store: store)

        XCTAssertEqual(model.conversationHistoryCount(containing: first), 2)
        model.deleteConversationHistory(containing: first)

        XCTAssertEqual(try store.fetchCards(includeArchived: true).map(\.id), [keep.id])
    }

    func testAnotherTakeUsesSavedUserConversationContext() throws {
        _ = NSApplication.shared
        let context = #"[{"role":"user","text":"Explain why the launch failed."},{"role":"attache","text":"Let me inspect it."},{"role":"user","text":"Focus on the certificate error."}]"#
        let card = try CardStore.inMemory().insertEvent(NormalizedEvent(
            source: SourceKind.generic.rawValue,
            eventType: "attache.conversation.reply",
            title: "Attaché reply",
            text: "The prior personality's answer.",
            metadata: ["companion_conversation_context_v1": context]
        ))
        let model = AppModel(store: try CardStore.inMemory())

        let source = model.anotherTakeUnderlyingSource(for: card)

        XCTAssertTrue(source.contains("User: Explain why the launch failed."))
        XCTAssertTrue(source.contains("Attaché: Let me inspect it."))
        XCTAssertTrue(source.contains("User: Focus on the certificate error."))
        XCTAssertFalse(source.contains("The prior personality's answer."))
    }
}

final class ConversationContextDefaultsSnapshot {
    private let keys: [String]
    private let defaults: UserDefaults
    private let values: [String: Any]

    init(keys: [String], defaults: UserDefaults) {
        self.keys = keys
        self.defaults = defaults
        values = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        })
        keys.forEach { defaults.removeObject(forKey: $0) }
    }

    func restore() {
        keys.forEach { defaults.removeObject(forKey: $0) }
        values.forEach { defaults.set($0.value, forKey: $0.key) }
    }
}
