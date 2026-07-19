import AttacheCore
import XCTest
@testable import AttacheApp

/// T6 (INF-299): the presented event for an "another take" links to the original
/// and records the target as the producing personality, and that linkage
/// survives a round trip through the card store.
final class AnotherTakeEventTests: XCTestCase {
    private func makeCard(id: String, sessionID: String?, project: String?) -> VoicemailCard {
        VoicemailCard(
            id: id, sourceID: "s", sourceKind: "codex", sourceDisplayName: "Codex",
            sessionID: nil, externalSessionID: sessionID, projectPath: project, sessionTitle: "Deploy",
            kind: .update, rawText: "deploy details", summary: "deploy", spokenText: "The herd is through.",
            status: .heard, createdAt: Date(timeIntervalSince1970: 0), heardAt: nil,
            metadataJSON: "{}", durationMs: 0, alignment: nil
        )
    }

    func testAnotherTakeEventLinksToOriginalAndRecordsTarget() {
        let original = makeCard(id: "orig-1", sessionID: "sess-9", project: "/tmp/p")
        let target = Personality(id: "builtin.bigPicture", name: "Big Picture", prompt: "p", character: .robot)
        let event = AttachePresentationService.anotherTakeEvent(
            from: original, targetPersonality: target,
            summary: "Where it stands", spoken: "Bottom line, you shipped.", needsDecision: false
        )
        XCTAssertEqual(event.metadata["attache_take_of"], "orig-1")
        XCTAssertEqual(event.metadata["attache_personality_id"], "builtin.bigPicture")
        XCTAssertEqual(event.metadata["attache_personality_name"], "Big Picture")
        XCTAssertEqual(event.metadata["attache_spoken_text"], "Bottom line, you shipped.")
        XCTAssertEqual(event.metadata["attache_summary"], "Where it stands")
        XCTAssertEqual(event.metadata["attache_presentation_strategy"], "another-take")
        XCTAssertEqual(event.externalSessionID, "sess-9")
        XCTAssertEqual(event.projectPath, "/tmp/p")
        XCTAssertEqual(event.text, "deploy details")
        XCTAssertNil(event.metadata["attache_needs_decision"])
    }

    func testAnotherTakeEventFlagsNeedsDecision() {
        let original = makeCard(id: "o", sessionID: nil, project: nil)
        let target = Personality(id: "p", name: "P", prompt: "x")
        let event = AttachePresentationService.anotherTakeEvent(
            from: original, targetPersonality: target, summary: "s", spoken: "sp", needsDecision: true
        )
        XCTAssertEqual(event.metadata["attache_needs_decision"], "1")
    }

    func testAnotherTakeStaysLinkedToSavedConversationForDeletion() {
        var original = makeCard(id: "conversation-reply", sessionID: nil, project: nil)
        original.metadataJSON = #"{"attache_conversation_id":"call-1","attache_conversation_user_turn":"Explain this","attache_conversation_context_v1":"[]"}"#
        let target = Personality(id: "custom.colt", name: "Colt", prompt: "p")

        let event = AttachePresentationService.anotherTakeEvent(
            from: original,
            targetPersonality: target,
            summary: "A second view",
            spoken: "Here is another angle.",
            needsDecision: false
        )

        XCTAssertEqual(event.metadata["attache_conversation_id"], "call-1")
        XCTAssertEqual(event.metadata["attache_conversation_user_turn"], "Explain this")
        XCTAssertEqual(event.metadata["attache_conversation_context_v1"], "[]")
    }

    func testInsertedAnotherTakeCardCarriesTakeOfThroughStore() throws {
        let store = try CardStore.inMemory()
        let original = makeCard(id: "orig-1", sessionID: "sess-9", project: "/tmp/p")
        let target = Personality(id: "builtin.bigPicture", name: "Big Picture", prompt: "p", character: .robot)
        let event = AttachePresentationService.anotherTakeEvent(
            from: original, targetPersonality: target,
            summary: "Where it stands", spoken: "Bottom line, you shipped.", needsDecision: false
        )
        let card = try store.insertEvent(event)
        XCTAssertEqual(card.takeOf, "orig-1")
        XCTAssertTrue(card.isAnotherTake)
        XCTAssertEqual(card.producedByPersonalityName, "Big Picture")
        XCTAssertEqual(card.spokenText, "Bottom line, you shipped.")
    }
}
