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

    func testDecodeAcceptsAbsentSchemaVersion() throws {
        let json =
            """
            {
              "source": "codex",
              "event_type": "assistant.completed",
              "title": "Build finished",
              "text": "No schema_version field at all.",
              "metadata": {}
            }
            """

        let event = try EventNormalizer.decode(data: Data(json.utf8))

        XCTAssertEqual(event.schemaVersion, 1)
    }

    func testDecodeAcceptsExplicitSchemaVersionOne() throws {
        let json =
            """
            {
              "source": "codex",
              "event_type": "assistant.completed",
              "title": "Build finished",
              "text": "Explicit schema_version 1.",
              "metadata": {},
              "schema_version": 1
            }
            """

        let event = try EventNormalizer.decode(data: Data(json.utf8))

        XCTAssertEqual(event.schemaVersion, 1)
    }

    func testDecodeRejectsUnsupportedSchemaVersion() {
        let json =
            """
            {
              "source": "codex",
              "event_type": "assistant.completed",
              "title": "Build finished",
              "text": "Schema version 2 is not understood yet.",
              "metadata": {},
              "schema_version": 2
            }
            """

        XCTAssertThrowsError(try EventNormalizer.decode(data: Data(json.utf8))) { error in
            guard let normalizerError = error as? EventNormalizerError,
                  case .unsupportedSchemaVersion(let requested, let supported) = normalizerError else {
                XCTFail("expected EventNormalizerError.unsupportedSchemaVersion, got \(error)")
                return
            }
            XCTAssertEqual(requested, 2)
            XCTAssertEqual(supported, 1)
            XCTAssertEqual(
                normalizerError.errorDescription,
                "Unsupported schema_version 2; this server supports schema_version 1."
            )
        }
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
                "attache_summary": "Short card summary",
                "attache_spoken_text": "Full attache spoken update with the second sentence preserved."
            ]
        )

        XCTAssertEqual(EventNormalizer.storedSummary(for: event), "Short card summary")
        XCTAssertEqual(
            EventNormalizer.storedSpokenText(for: event, summary: "Short card summary"),
            "Full attache spoken update with the second sentence preserved."
        )
    }
}
