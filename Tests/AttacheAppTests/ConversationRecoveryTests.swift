import XCTest
@testable import AttacheApp
@testable import AttacheCore

final class ConversationRecoveryTests: XCTestCase {

    // MARK: - CLI text-marker fallback (no HTTP status available)

    func testUsageLimitOffersModelSwitchAndPreservesPrompt() {
        let recovery = ConversationRecovery.classify(
            errorMessage: "codex exited with code 1: You've hit your usage limit. Try again later.",
            failedPrompt: "Explain the update",
            isCLIProvider: true
        )

        XCTAssertEqual(recovery.category, .usageOrRateLimit)
        XCTAssertTrue(recovery.offersModelSwitch)
        XCTAssertEqual(recovery.failedPrompt, "Explain the update")
    }

    func testUnavailableModelOffersModelSwitch() {
        let recovery = ConversationRecovery.classify(
            errorMessage: "The selected model is unavailable.",
            failedPrompt: "Summarize this",
            isCLIProvider: true
        )

        XCTAssertEqual(recovery.category, .modelUnavailable)
        XCTAssertTrue(recovery.offersModelSwitch)
    }

    func testAuthenticationFailureDoesNotOfferMisleadingModelSwitch() {
        let recovery = ConversationRecovery.classify(
            errorMessage: "Authentication required. Please log in.",
            failedPrompt: "Summarize this",
            isCLIProvider: true
        )

        XCTAssertEqual(recovery.category, .other)
        XCTAssertFalse(recovery.offersModelSwitch)
    }

    func testCLIMarkersAreIgnoredForNonCLIProviders() {
        // Same text a CLI provider would emit, but the caller did not mark it
        // as a CLI failure (e.g. it's an HTTP provider's response body with no
        // status attached). Markers must not be consulted.
        let recovery = ConversationRecovery.classify(
            errorMessage: "You've hit your usage limit. Try again later.",
            failedPrompt: "Explain the update"
        )

        XCTAssertEqual(recovery.category, .other)
    }

    // MARK: - Structural: HTTP status codes

    func test429ClassifiesAsUsageOrRateLimit() {
        let recovery = ConversationRecovery.classify(
            errorMessage: "LLM request failed with HTTP 429: rate limited",
            failedPrompt: "Summarize this",
            httpStatus: 429
        )

        XCTAssertEqual(recovery.category, .usageOrRateLimit)
        XCTAssertTrue(recovery.offersModelSwitch)
    }

    func test402ClassifiesAsUsageOrRateLimit() {
        let recovery = ConversationRecovery.classify(
            errorMessage: "LLM request failed with HTTP 402: payment required",
            failedPrompt: "Summarize this",
            httpStatus: 402
        )

        XCTAssertEqual(recovery.category, .usageOrRateLimit)
        XCTAssertTrue(recovery.offersModelSwitch)
    }

    func test404ClassifiesAsModelUnavailable() {
        let recovery = ConversationRecovery.classify(
            errorMessage: "LLM request failed with HTTP 404: not found",
            failedPrompt: "Summarize this",
            httpStatus: 404
        )

        XCTAssertEqual(recovery.category, .modelUnavailable)
        XCTAssertTrue(recovery.offersModelSwitch)
    }

    func test400WithModelMarkerClassifiesAsModelUnavailable() {
        let recovery = ConversationRecovery.classify(
            errorMessage: "LLM request failed with HTTP 400: model_not_found",
            failedPrompt: "Summarize this",
            httpStatus: 400
        )

        XCTAssertEqual(recovery.category, .modelUnavailable)
    }

    func test400WithoutModelMarkerDoesNotClassifyAsModelUnavailable() {
        let recovery = ConversationRecovery.classify(
            errorMessage: "LLM request failed with HTTP 400: malformed request body",
            failedPrompt: "Summarize this",
            httpStatus: 400
        )

        XCTAssertEqual(recovery.category, .other)
    }

    func test401ClassifiesAsAuthAndNeverOffersModelSwitch() {
        let recovery = ConversationRecovery.classify(
            errorMessage: "LLM request failed with HTTP 401: unauthorized",
            failedPrompt: "Summarize this",
            httpStatus: 401
        )

        XCTAssertEqual(recovery.category, .auth)
        XCTAssertFalse(recovery.offersModelSwitch)
    }

    func test403ClassifiesAsAuthAndNeverOffersModelSwitch() {
        let recovery = ConversationRecovery.classify(
            errorMessage: "LLM request failed with HTTP 403: forbidden",
            failedPrompt: "Summarize this",
            httpStatus: 403
        )

        XCTAssertEqual(recovery.category, .auth)
        XCTAssertFalse(recovery.offersModelSwitch)
    }

    func test5xxClassifiesAsTransient() {
        for status in [500, 502, 503, 504] {
            let recovery = ConversationRecovery.classify(
                errorMessage: "LLM request failed with HTTP \(status): server error",
                failedPrompt: "Summarize this",
                httpStatus: status
            )

            XCTAssertEqual(recovery.category, .transient, "status \(status) should classify as transient")
        }
    }

    // MARK: - Structural: URLError transport failures

    func testTimeoutClassifiesAsTransient() {
        let recovery = ConversationRecovery.classify(
            errorMessage: "The request timed out.",
            failedPrompt: "Summarize this",
            urlErrorCode: .timedOut
        )

        XCTAssertEqual(recovery.category, .transient)
    }

    func testConnectionLostClassifiesAsTransient() {
        let recovery = ConversationRecovery.classify(
            errorMessage: "The network connection was lost.",
            failedPrompt: "Summarize this",
            urlErrorCode: .networkConnectionLost
        )

        XCTAssertEqual(recovery.category, .transient)
    }

    // MARK: - Precedence

    func testHTTPStatusTakesPrecedenceOverCLIMarkersWhenBothPresent() {
        // A CLI-marked failure that also happens to carry a status (e.g. a
        // future CLI mode that surfaces one) should classify structurally,
        // not by text, since the status is more precise.
        let recovery = ConversationRecovery.classify(
            errorMessage: "quota exceeded",
            failedPrompt: "Summarize this",
            httpStatus: 401,
            isCLIProvider: true
        )

        XCTAssertEqual(recovery.category, .auth)
    }
}
