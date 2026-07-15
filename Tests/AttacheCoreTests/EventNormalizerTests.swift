import AttacheCore
import XCTest

final class EventNormalizerTests: XCTestCase {
    func testDecodesSpecPayload() throws {
        let json =
            """
            {
              "source": "codex",
              "event_type": "assistant.completed",
              "external_session_id": "session-1",
              "project_path": "/tmp/demo",
              "title": "Build finished",
              "text": "The build completed and the app launched.",
              "metadata": {
                "turn_id": "turn-1",
                "cwd": "/tmp/demo"
              }
            }
            """

        let event = try EventNormalizer.decode(data: Data(json.utf8))

        XCTAssertEqual(event.source, "codex")
        XCTAssertEqual(event.eventType, "assistant.completed")
        XCTAssertEqual(event.externalSessionID, "session-1")
        XCTAssertEqual(event.metadata["cwd"], "/tmp/demo")
    }

    func testSummaryCompactsLongText() {
        let event = NormalizedEvent(
            source: "codex",
            eventType: "assistant.completed",
            title: "Long",
            text: String(repeating: "word ", count: 80)
        )

        XCTAssertLessThanOrEqual(EventNormalizer.summary(for: event).count, 183)
    }

    func testPresentationOverridesKeepSummaryAndSpokenTextSeparate() {
        let event = NormalizedEvent(
            source: "codex",
            eventType: "assistant.completed",
            title: "Long",
            text: "First sentence only. Second sentence should still be available for speech.",
            metadata: [
                "companion_summary": "Short card summary",
                "companion_spoken_text": "Full attache spoken update with the second sentence preserved."
            ]
        )

        XCTAssertEqual(EventNormalizer.storedSummary(for: event), "Short card summary")
        XCTAssertEqual(
            EventNormalizer.storedSpokenText(for: event, summary: "Short card summary"),
            "Full attache spoken update with the second sentence preserved."
        )
    }
}
