import XCTest
@testable import AttacheApp

/// Regression coverage for a real production bug (INF-264 follow-up): a
/// persisted `reasoningEffort` of `"none"` was sent to the LLM API as a
/// literal `"reasoning_effort": "none"` field, and a model that rejects the
/// field outright (rather than accepting an off-like value) returned
/// `HTTP 400: This model does not support 'reasoning_effort'`. The fix folds
/// `"none"` into the same "omit the field" bucket as `"default"`.
final class CompanionPresentationServiceTests: XCTestCase {
    func testNoneIsOmittedJustLikeDefault() {
        XCTAssertNil(CompanionPresentationService.normalizedReasoningEffort("none"))
        XCTAssertNil(CompanionPresentationService.normalizedReasoningEffort("default"))
    }

    func testOmissionIsCaseInsensitiveAndTrimsWhitespace() {
        XCTAssertNil(CompanionPresentationService.normalizedReasoningEffort("None"))
        XCTAssertNil(CompanionPresentationService.normalizedReasoningEffort("DEFAULT"))
        XCTAssertNil(CompanionPresentationService.normalizedReasoningEffort("  none  "))
    }

    func testEmptyOrMissingValueIsOmitted() {
        XCTAssertNil(CompanionPresentationService.normalizedReasoningEffort(nil))
        XCTAssertNil(CompanionPresentationService.normalizedReasoningEffort(""))
        XCTAssertNil(CompanionPresentationService.normalizedReasoningEffort("   "))
    }

    func testARealEffortLevelPassesThroughVerbatim() {
        XCTAssertEqual(CompanionPresentationService.normalizedReasoningEffort("high"), "high")
        XCTAssertEqual(CompanionPresentationService.normalizedReasoningEffort("low"), "low")
    }
}
