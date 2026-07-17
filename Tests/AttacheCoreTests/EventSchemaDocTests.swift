@testable import AttacheCore
import XCTest

/// INF-359: `docs/integrations.md` documents every field `POST /events` accepts.
/// This fixture mirrors that doc's field table. If `NormalizedEvent.CodingKeys`
/// changes (a field is added, renamed, or removed) without updating both the
/// doc and this fixture, this test fails, so the doc can never silently drift
/// from the actual wire schema.
final class EventSchemaDocTests: XCTestCase {
    /// Wire field names documented in docs/integrations.md's "Event fields"
    /// table, in the same order as that table.
    static let documentedEventFields: [String] = [
        "source",
        "event_type",
        "external_session_id",
        "project_path",
        "title",
        "text",
        "metadata",
        "schema_version"
    ]

    func testDocumentedFieldsMatchNormalizedEventCodingKeys() {
        let actualFields = NormalizedEvent.CodingKeys.allCases.map { $0.rawValue }

        XCTAssertEqual(
            Set(Self.documentedEventFields),
            Set(actualFields),
            "docs/integrations.md's field list has drifted from NormalizedEvent.CodingKeys; update the doc's \"Event fields\" table and this fixture together."
        )
        XCTAssertEqual(
            Self.documentedEventFields.count,
            actualFields.count,
            "duplicate or missing field name in the documented fixture"
        )
    }
}
