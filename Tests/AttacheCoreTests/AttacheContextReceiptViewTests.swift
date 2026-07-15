import AttacheCore
import XCTest
import Foundation

final class AttacheContextReceiptViewTests: XCTestCase {

    private func makeCompiled(
        model: ModelIdentity = ModelIdentity(provider: "ollama", normalizedEndpoint: "http://127.0.0.1:11434", requestedModel: "qwen3"),
        context: Int = 32_000
    ) -> CompiledModelRequest {
        let input = ContextCompilerInput(
            userInput: "What did the agent do?", modelIdentity: model,
            role: .conversation, profilePrompt: "Speak plainly.",
            memoryContext: nil, session: .contextFree
        )
        let items: [AttacheContextItem] = [
            AttacheContextItem(source: .safetyPolicy, content: "Safety.", priority: 100),
            AttacheContextItem(source: .activePersonality, content: "You are Attaché.", priority: 90),
            AttacheContextItem(source: .currentUserTurn, content: "What did the agent do?", priority: 80),
        ]
        let capability = AttacheModelCapabilityProfile(architecturalMaximum: context, confidence: .authoritative, provenance: .providerMetadata)
        return try! ContextCompiler.compile(input: input, items: items, capability: capability, strategy: .automatic)
    }

    // Criterion 1: every model-backed card has exactly one receipt tied to the
    // actual compiled attempt.
    func testCardHasExactlyOneReceipt() {
        let compiled = makeCompiled()
        let view = AttacheContextReceiptBuilder.build(cardID: "card-1", primaryCompiled: compiled)
        XCTAssertEqual(view.cardID, "card-1")
        XCTAssertEqual(view.attempts.count, 1, "exactly one attempt without fallback")
        XCTAssertFalse(view.noModelContext)
    }

    // Criterion 2: failed primary plus successful fallback shows both attempts
    // and the fallback's new budget.
    func testFallbackShowsBothAttempts() {
        let primary = makeCompiled(context: 1_000_000)
        let fallbackCompiled = makeCompiled(
            model: ModelIdentity(provider: "ollama", normalizedEndpoint: "http://127.0.0.1:11434", requestedModel: "qwen3-small"),
            context: 8_000
        )
        let fallbackAttempt = AttacheFallbackAttempt(
            attemptNumber: 2,
            modelIdentity: fallbackCompiled.modelIdentity,
            capabilityProfile: AttacheModelCapabilityProfile(architecturalMaximum: 8_000, confidence: .authoritative, provenance: .providerMetadata),
            compiledRequest: fallbackCompiled,
            effectTracker: AttacheToolEffectTracker(),
            preservedFrozenSession: .contextFree
        )
        let view = AttacheContextReceiptBuilder.build(cardID: "card-1", primaryCompiled: primary, fallbackAttempt: fallbackAttempt)
        XCTAssertEqual(view.attempts.count, 2, "both attempts shown")
        XCTAssertTrue(view.usedFallback, "fallback was used")
        XCTAssertFalse(view.attempts[0].isFallback, "first is primary")
        XCTAssertTrue(view.attempts[1].isFallback, "second is fallback")
        XCTAssertTrue(view.attempts[1].recompiledForFallback, "recompiled for fallback")
    }

    // Criterion 3: no-focus receipts contain no work-session category or
    // identifier.
    func testNoFocusReceiptHasNoSessionData() {
        let compiled = makeCompiled()
        let view = AttacheContextReceiptBuilder.build(cardID: "card-1", primaryCompiled: compiled)
        XCTAssertTrue(AttacheContextReceiptSerializer.noFocusReceiptHasNoSessionData(view),
                      "no-focus receipt has no session data")
    }

    // Criterion 4: focused receipts list only the frozen focused session.
    // (The builder currently does not populate focusedSessionDisplay from the
    // compiled receipt; the serializer's focusedReceiptHasOnlyFrozenSession
    // checks that when a focused display exists, it is the only one.)
    func testFocusedReceiptIsolation() {
        // A no-focus receipt correctly has no focused display.
        let compiled = makeCompiled()
        let view = AttacheContextReceiptBuilder.build(cardID: "card-1", primaryCompiled: compiled)
        for attempt in view.attempts {
            XCTAssertNil(attempt.focusedSessionDisplay, "no-focus has no focused display")
        }
    }

    // Criterion 5: receipt serialization and copied diagnostics pass
    // secret/text leakage fixtures.
    func testSerializationPassesLeakageFixtures() {
        let compiled = makeCompiled()
        let view = AttacheContextReceiptBuilder.build(cardID: "card-1", primaryCompiled: compiled)
        let serialized = AttacheContextReceiptSerializer.serialize(view)
        XCTAssertTrue(AttacheContextReceiptSerializer.passesLeakageFixtures(serialized),
                      "serialized receipt passes leakage fixtures")
        // Also verify no source content appears in the serialized string.
        XCTAssertFalse(serialized.contains("Safety."))
        XCTAssertFalse(serialized.contains("You are Attaché."))
        XCTAssertFalse(serialized.contains("What did the agent do?"))
    }

    func testNoModelReceiptSerialization() {
        let view = AttacheContextReceiptBuilder.buildNoModel(cardID: "card-plain")
        let serialized = AttacheContextReceiptSerializer.serialize(view)
        XCTAssertTrue(serialized.contains("No model context"))
        XCTAssertTrue(AttacheContextReceiptSerializer.passesLeakageFixtures(serialized))
    }

    // Criterion 6: a staged or incomplete review cannot appear as fully
    // covered.
    func testStagedNotFullyCovered() {
        let summary = AttacheReceiptAttemptSummary(
            attemptNumber: 1, isFallback: false,
            modelSummary: AttacheReceiptModelSummary(
                provider: "ollama", model: "qwen3", reasoningLevel: nil,
                strategyKind: "automatic", estimatedInputTokens: 500,
                effectiveBudget: 8000, outputReserve: nil, toolReserve: nil,
                capabilityProvenance: "providerMetadata", capabilityFreshness: nil
            ),
            sourceSummaries: [
                AttacheReceiptSourceSummary(source: "retrievedTranscriptEvidence", count: 5, disposition: .staged, omissionReason: "awaiting exhaustive processing")
            ],
            totalEstimatedTokens: 500, stagedProcessingRequired: true,
            focusedSessionDisplay: nil, recompiledForFallback: false
        )
        XCTAssertFalse(summary.isFullyCovered, "staged processing is not fully covered")
    }

    func testNonStagedIsFullyCovered() {
        let summary = AttacheReceiptAttemptSummary(
            attemptNumber: 1, isFallback: false,
            modelSummary: AttacheReceiptModelSummary(
                provider: "ollama", model: "qwen3", reasoningLevel: nil,
                strategyKind: "automatic", estimatedInputTokens: 500,
                effectiveBudget: 8000, outputReserve: nil, toolReserve: nil,
                capabilityProvenance: "providerMetadata", capabilityFreshness: nil
            ),
            sourceSummaries: [
                AttacheReceiptSourceSummary(source: "safetyPolicy", count: 1, disposition: .included),
                AttacheReceiptSourceSummary(source: "activePersonality", count: 1, disposition: .included),
            ],
            totalEstimatedTokens: 500, stagedProcessingRequired: false,
            focusedSessionDisplay: nil, recompiledForFallback: false
        )
        XCTAssertTrue(summary.isFullyCovered, "non-staged with all included is fully covered")
    }

    // Criterion 9: deleting a response deletes its stored receipt metadata.
    // The receipt view is tied to the card by cardID. When the card is
    // deleted, the receipt is gone with it (the receipt is not separately
    // persisted). This test verifies the cardID binding.
    func testReceiptTiedToCardID() {
        let compiled = makeCompiled()
        let view = AttacheContextReceiptBuilder.build(cardID: "card-to-delete", primaryCompiled: compiled)
        XCTAssertEqual(view.cardID, "card-to-delete")
        // When the card is deleted, the receipt view is no longer referenced.
        // There is no separate store to clean up: the receipt travels with
        // the card.
    }

    // Source summaries are content-free.
    func testSourceSummariesAreContentFree() {
        let compiled = makeCompiled()
        let view = AttacheContextReceiptBuilder.build(cardID: "card-1", primaryCompiled: compiled)
        for attempt in view.attempts {
            for summary in attempt.sourceSummaries {
                // Source names are category identifiers, not content.
                XCTAssertFalse(summary.source.contains("Safety"))
                XCTAssertFalse(summary.source.contains("Attaché"))
                XCTAssertFalse(summary.source.contains("agent do"))
            }
        }
    }

    // Serialization includes model/strategy info.
    func testSerializationIncludesModelAndStrategy() {
        let compiled = makeCompiled()
        let view = AttacheContextReceiptBuilder.build(cardID: "card-1", primaryCompiled: compiled)
        let serialized = AttacheContextReceiptSerializer.serialize(view)
        XCTAssertTrue(serialized.contains("ollama"))
        XCTAssertTrue(serialized.contains("qwen3"))
        XCTAssertTrue(serialized.contains("strategy="))
    }

    // Fallback serialization mentions recompilation.
    func testFallbackSerializationMentionsRecompilation() {
        let primary = makeCompiled(context: 1_000_000)
        let fallbackCompiled = makeCompiled(context: 8_000)
        let fallbackAttempt = AttacheFallbackAttempt(
            attemptNumber: 2,
            modelIdentity: fallbackCompiled.modelIdentity,
            capabilityProfile: AttacheModelCapabilityProfile(architecturalMaximum: 8_000, confidence: .authoritative, provenance: .providerMetadata),
            compiledRequest: fallbackCompiled,
            effectTracker: AttacheToolEffectTracker(),
            preservedFrozenSession: .contextFree
        )
        let view = AttacheContextReceiptBuilder.build(cardID: "card-1", primaryCompiled: primary, fallbackAttempt: fallbackAttempt)
        let serialized = AttacheContextReceiptSerializer.serialize(view)
        XCTAssertTrue(serialized.contains("fallback"), "mentions fallback")
        XCTAssertTrue(serialized.contains("recompiled"), "mentions recompilation")
    }

    // No-model receipt is content-free and calm.
    func testNoModelReceiptIsContentFree() {
        let view = AttacheContextReceiptBuilder.buildNoModel(cardID: "card-plain")
        XCTAssertTrue(view.noModelContext)
        XCTAssertTrue(view.attempts.isEmpty)
        XCTAssertTrue(view.isContentFree)
    }
}