import XCTest
@testable import AttacheApp

final class CaptionLanguageTests: XCTestCase {
    func testCaptionLanguageListCoversTheFriendsAudience() {
        let ids = Set(AttacheCaptionLanguage.all.map(\.id))
        for required in ["ko", "es", "pt", "pl", "de", "nb", "th"] {
            XCTAssertTrue(ids.contains(required), "missing \(required)")
        }
    }
}
