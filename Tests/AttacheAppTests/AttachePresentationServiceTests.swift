import XCTest
@testable import AttacheApp

/// Regression coverage for a real production bug (INF-264 follow-up): a
/// persisted `reasoningEffort` of `"none"` was sent to the LLM API as a
/// literal `"reasoning_effort": "none"` field, and a model that rejects the
/// field outright (rather than accepting an off-like value) returned
/// `HTTP 400: This model does not support 'reasoning_effort'`. The fix folds
/// `"none"` into the same "omit the field" bucket as `"default"`.
final class AttachePresentationServiceTests: XCTestCase {
    func testNoneIsOmittedJustLikeDefault() {
        XCTAssertNil(AttachePresentationService.normalizedReasoningEffort("none"))
        XCTAssertNil(AttachePresentationService.normalizedReasoningEffort("default"))
    }

    func testOmissionIsCaseInsensitiveAndTrimsWhitespace() {
        XCTAssertNil(AttachePresentationService.normalizedReasoningEffort("None"))
        XCTAssertNil(AttachePresentationService.normalizedReasoningEffort("DEFAULT"))
        XCTAssertNil(AttachePresentationService.normalizedReasoningEffort("  none  "))
    }

    func testEmptyOrMissingValueIsOmitted() {
        XCTAssertNil(AttachePresentationService.normalizedReasoningEffort(nil))
        XCTAssertNil(AttachePresentationService.normalizedReasoningEffort(""))
        XCTAssertNil(AttachePresentationService.normalizedReasoningEffort("   "))
    }

    func testARealEffortLevelPassesThroughVerbatim() {
        XCTAssertEqual(AttachePresentationService.normalizedReasoningEffort("high"), "high")
        XCTAssertEqual(AttachePresentationService.normalizedReasoningEffort("low"), "low")
    }

    func testExplicitNoneIsSentToProvidersThatSupportDisablingReasoning() {
        XCTAssertEqual(
            AttachePresentationService.reasoningEffortPayloadValue("none", provider: .xai),
            "none"
        )
        XCTAssertEqual(
            AttachePresentationService.reasoningEffortPayloadValue("none", provider: .ollama),
            "none"
        )
    }

    func testExplicitNoneStaysOmittedForProvidersWithoutThatContract() {
        XCTAssertNil(AttachePresentationService.reasoningEffortPayloadValue("none", provider: .groq))
    }
}
