import XCTest
@testable import AttacheApp

final class CompanionPresentationModelServiceTests: XCTestCase {
    func testUnknownCodexModelKeepsReasoningChoices() {
        let efforts = CompanionPresentationModelService.fallbackReasoningEfforts(
            provider: .codexCLI,
            modelID: "gpt-5.6-luna"
        )

        XCTAssertTrue(efforts.contains("low"))
        XCTAssertFalse(efforts.contains("none"))
    }
}
