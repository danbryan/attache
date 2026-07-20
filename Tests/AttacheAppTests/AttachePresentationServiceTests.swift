import AttacheCore
import XCTest
@testable import AttacheApp

/// Regression coverage for a real production bug (INF-264 follow-up): a
/// persisted `reasoningEffort` of `"none"` was sent to the LLM API as a
/// literal `"reasoning_effort": "none"` field, and a model that rejects the
/// field outright (rather than accepting an off-like value) returned
/// `HTTP 400: This model does not support 'reasoning_effort'`. The fix folds
/// `"none"` into the same "omit the field" bucket as `"default"`.
final class AttachePresentationServiceTests: XCTestCase {
    func testLiveFollowUpRefusesContextFreeSessionHistory() {
        let service = AttachePresentationService(environment: [:])
        let card = testCard(externalSessionID: "focused-session")
        let snapshot = AttacheRequestSnapshot(
            role: .liveFollowUp,
            personality: Personality.builtIns[0],
            profilePrompt: "Test",
            userInput: "What changed?",
            session: .contextFree,
            modelSettings: nil,
            contextItems: [],
            contextStrategy: .automatic
        )
        let completed = expectation(description: "authorization rejected")

        service.answerFollowUpQuestion(card: card, danQuestion: "What changed?", snapshot: snapshot) { result in
            guard case .failure(let error) = result,
                  case .unauthorizedContext = error as? AttachePresentationError else {
                XCTFail("Expected unauthorizedContext, got \(result)")
                completed.fulfill()
                return
            }
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
    }

    func testLiveFollowUpPromptIsBoundToFocusedSessionEvidence() {
        let focused = AttacheFocusedSession(
            sessionID: "focused-session",
            sourceKind: SourceKind.codex.rawValue,
            displayTitle: "Focused",
            workingDirectory: "/tmp/project",
            authorizationEpoch: AttacheFocusEpoch(7)
        )
        let snapshot = AttacheRequestSnapshot(
            role: .liveFollowUp,
            personality: Personality.builtIns[0],
            profilePrompt: "Test",
            userInput: "What changed?",
            session: .focused(focused),
            modelSettings: nil,
            contextItems: [],
            contextStrategy: .automatic
        )
        let message = AttacheChatMessage(role: "user", content: "Stored session evidence and question")

        let sources = AttacheProductionRequestBroker.prebuiltMessageSources(
            snapshot: snapshot,
            messages: [message]
        )

        let evidence = sources.first { $0.source == .retrievedTranscriptEvidence }
        XCTAssertEqual(evidence?.message, message)
        XCTAssertEqual(evidence?.authorization, .focused(focused))
    }

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
        XCTAssertNil(AttachePresentationService.reasoningEffortPayloadValue("none", provider: .codexCLI))
    }

    /// The plain/verbatim readback path speaks the raw event text with no model
    /// in the loop, so it must sanitize the SPOKEN string (also what captions
    /// render) while leaving the card's underlying raw text fully intact.
    func testPlainReadbackSanitizesSpokenTextButKeepsRawURL() {
        let url = "https://notion.so/really/long/link/that/should/not/be/spelled/out"
        let event = NormalizedEvent(
            source: SourceKind.codex.rawValue,
            eventType: "assistant.completed",
            title: "Update",
            text: "Docs live at \(url) for reference."
        )
        let presented = AttachePresentationService.eventWithPlainReadbackPresentation(event)
        let spoken = EventNormalizer.storedSpokenText(for: presented)
        XCTAssertFalse(spoken.contains("http"))
        XCTAssertFalse(spoken.contains("notion"))
        XCTAssertTrue(spoken.contains("a link"))
        // The card's underlying raw text keeps the full URL untouched.
        XCTAssertTrue(presented.text.contains(url))
    }

    private func testCard(externalSessionID: String) -> VoicemailCard {
        VoicemailCard(
            id: "card", sourceID: "source", sourceKind: SourceKind.codex.rawValue,
            sourceDisplayName: "Codex", sessionID: "session", externalSessionID: externalSessionID,
            projectPath: "/tmp/project", sessionTitle: "Focused", kind: .update,
            rawText: "Private stored session history", summary: "Private history",
            spokenText: "Private history", status: .heard, createdAt: Date(), heardAt: Date(),
            metadataJSON: "{}", durationMs: 0, alignment: nil
        )
    }
}
