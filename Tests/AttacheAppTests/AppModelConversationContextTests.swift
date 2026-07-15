import AppKit
import AttacheCore
import XCTest
@testable import AttacheApp

@MainActor
final class AppModelConversationContextTests: XCTestCase {
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
}

private final class ConversationContextDefaultsSnapshot {
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
