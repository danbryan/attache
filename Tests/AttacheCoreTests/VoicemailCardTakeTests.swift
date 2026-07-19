import AttacheCore
import XCTest

/// T6 (INF-299): a card links back to the original it re-narrates via metadata,
/// with no schema migration.
final class VoicemailCardTakeTests: XCTestCase {
    private func card(metadataJSON: String) -> VoicemailCard {
        VoicemailCard(
            id: "c1", sourceID: "s", sourceKind: "codex", sourceDisplayName: "Codex",
            sessionID: nil, externalSessionID: nil, projectPath: nil, sessionTitle: nil,
            kind: .update, rawText: "raw", summary: "sum", spokenText: "spoken",
            status: .unread, createdAt: Date(timeIntervalSince1970: 0), heardAt: nil,
            metadataJSON: metadataJSON, durationMs: 0, alignment: nil
        )
    }

    func testTakeOfAndProducerFromMetadata() {
        let c = card(metadataJSON: #"{"attache_take_of":"orig-1","attache_personality_name":"Cowboy"}"#)
        XCTAssertEqual(c.takeOf, "orig-1")
        XCTAssertTrue(c.isAnotherTake)
        XCTAssertEqual(c.producedByPersonalityName, "Cowboy")
    }

    func testOrdinaryCardIsNotATake() {
        let c = card(metadataJSON: #"{"attache_personality_name":"Explainer"}"#)
        XCTAssertNil(c.takeOf)
        XCTAssertFalse(c.isAnotherTake)
        XCTAssertEqual(c.producedByPersonalityName, "Explainer")
    }

    func testMalformedMetadataIsSafe() {
        let c = card(metadataJSON: "not json")
        XCTAssertNil(c.takeOf)
        XCTAssertFalse(c.isAnotherTake)
        XCTAssertNil(c.producedByPersonalityName)
        XCTAssertFalse(c.needsDecision)
    }
}
