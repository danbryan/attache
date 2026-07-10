import XCTest
@testable import AttacheApp

final class ConversationRecoveryTests: XCTestCase {
    func testUsageLimitOffersModelSwitchAndPreservesPrompt() {
        let recovery = ConversationRecovery.classify(
            errorMessage: "codex exited with code 1: You've hit your usage limit. Try again later.",
            failedPrompt: "Explain the update"
        )

        XCTAssertEqual(recovery.category, .usageOrRateLimit)
        XCTAssertTrue(recovery.offersModelSwitch)
        XCTAssertEqual(recovery.failedPrompt, "Explain the update")
    }

    func testUnavailableModelOffersModelSwitch() {
        let recovery = ConversationRecovery.classify(
            errorMessage: "The selected model is unavailable.",
            failedPrompt: "Summarize this"
        )

        XCTAssertEqual(recovery.category, .modelUnavailable)
        XCTAssertTrue(recovery.offersModelSwitch)
    }

    func testAuthenticationFailureDoesNotOfferMisleadingModelSwitch() {
        let recovery = ConversationRecovery.classify(
            errorMessage: "Authentication required. Please log in.",
            failedPrompt: "Summarize this"
        )

        XCTAssertEqual(recovery.category, .other)
        XCTAssertFalse(recovery.offersModelSwitch)
    }
}
