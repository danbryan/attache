import AttacheCore
import XCTest
import Foundation

final class AttacheFallbackRecompilerTests: XCTestCase {

    private func makeInput(model: ModelIdentity, session: AttacheSessionAuthorization = .contextFree) -> ContextCompilerInput {
        ContextCompilerInput(
            userInput: "What did the agent do?",
            modelIdentity: model, role: .conversation,
            profilePrompt: "Speak plainly.", memoryContext: nil, session: session
        )
    }

    private func makeProfile(context: Int?) -> AttacheModelCapabilityProfile {
        AttacheModelCapabilityProfile(architecturalMaximum: context, confidence: .authoritative, provenance: .providerMetadata)
    }

    private func basicItems() -> [AttacheContextItem] {
        [
            AttacheContextItem(source: .safetyPolicy, content: "Safety rules.", priority: 100),
            AttacheContextItem(source: .activePersonality, content: "You are Attaché.", priority: 90),
            AttacheContextItem(source: .currentUserTurn, content: "What did the agent do?", priority: 80),
        ]
    }

    private let primaryModel = ModelIdentity(provider: "openai", normalizedEndpoint: "https://api.openai.com", requestedModel: "gpt-4")
    private let fallbackModel = ModelIdentity(provider: "ollama", normalizedEndpoint: "http://127.0.0.1:11434", requestedModel: "qwen3")

    // Criterion 1: 1M primary to 8K fallback fits 8K and preserves user turn,
    // personality, memory snapshot, and frozen session.
    func testLargeToSmallFitsAndPreserves() throws {
        let focused = AttacheFocusedSession(sessionID: "s1", sourceKind: "codex", displayTitle: "T", workingDirectory: nil)
        let snapshot = makeInput(model: primaryModel, session: .focused(focused))
        let attempt = try AttacheFallbackRecompiler.recompileForFallback(
            snapshot: snapshot, items: basicItems(),
            fallbackModel: fallbackModel,
            fallbackCapability: makeProfile(context: 8_000),
            strategy: .automatic,
            fallbackRequestIsRemote: false,
            effectTracker: AttacheToolEffectTracker(),
            attemptNumber: 1
        )
        XCTAssertLessThanOrEqual(
            attempt.compiledRequest.receipt.totalEstimatedTokens,
            attempt.compiledRequest.budgetPlan.effectiveHardLimit ?? Int.max,
            "fits 8K"
        )
        XCTAssertTrue(AttacheFallbackRecompiler.preservesFrozenIdentity(snapshot: snapshot, attempt: attempt),
                      "preserves user turn and frozen session")
        XCTAssertEqual(attempt.preservedFrozenSession, .focused(focused), "frozen session preserved")
    }

    // Criterion 2: 8K primary to 1M fallback may use the larger model's
    // strategy/capacity.
    func testSmallToLargeUsesLargerCapacity() throws {
        let focused = AttacheSessionAuthorization.focused(AttacheFocusedSession(
            sessionID: "large", sourceKind: "codex", displayTitle: "Large",
            workingDirectory: nil
        ))
        let snapshot = makeInput(model: fallbackModel, session: focused)
        var largeItems = basicItems()
        for i in 0..<20 {
            largeItems.append(AttacheContextItem(
                source: .retrievedTranscriptEvidence,
                content: String(repeating: "evidence \(i) ", count: 5_000),
                authorization: focused,
                priority: 50, treatment: .exactOnly
            ))
        }
        let attempt = try AttacheFallbackRecompiler.recompileForFallback(
            snapshot: snapshot, items: largeItems,
            fallbackModel: primaryModel,
            fallbackCapability: makeProfile(context: 1_000_000),
            strategy: .maximumCoverage,
            fallbackRequestIsRemote: false,
            effectTracker: AttacheToolEffectTracker(),
            attemptNumber: 1
        )
        // The 1M fallback can include more evidence than an 8K plan would.
        let evidenceCount = attempt.compiledRequest.receipt.includedSources.filter { $0 == "retrievedTranscriptEvidence" }.count
        XCTAssertGreaterThan(evidenceCount, 0, "larger model includes evidence")
    }

    // Criterion 3: fallback never introduces unauthorized session data.
    func testDoesNotIntroduceUnauthorizedData() throws {
        let snapshot = makeInput(model: primaryModel, session: .contextFree)
        let items = basicItems() // context-free items only
        let attempt = try AttacheFallbackRecompiler.recompileForFallback(
            snapshot: snapshot, items: items,
            fallbackModel: fallbackModel,
            fallbackCapability: makeProfile(context: 32_000),
            strategy: .automatic,
            fallbackRequestIsRemote: false,
            effectTracker: AttacheToolEffectTracker(),
            attemptNumber: 1
        )
        XCTAssertTrue(AttacheFallbackRecompiler.doesNotIntroduceUnauthorizedData(originalItems: items, attempt: attempt),
                      "fallback does not introduce unauthorized sources")
    }

    // Criterion 4: the user turn is not duplicated.
    func testUserTurnNotDuplicated() throws {
        let snapshot = makeInput(model: primaryModel)
        let attempt = try AttacheFallbackRecompiler.recompileForFallback(
            snapshot: snapshot, items: basicItems(),
            fallbackModel: fallbackModel,
            fallbackCapability: makeProfile(context: 32_000),
            strategy: .automatic,
            fallbackRequestIsRemote: false,
            effectTracker: AttacheToolEffectTracker(),
            attemptNumber: 1
        )
        XCTAssertTrue(AttacheFallbackRecompiler.userTurnNotDuplicated(attempt: attempt, userInput: snapshot.userInput),
                      "user turn appears exactly once")
    }

    // Criterion 5: context-limit failures preserve the draft and expose
    // explicit retry; they never silently change provider.
    func testContextLimitNeverAutoFallback() {
        let category = AttacheFallbackRecompiler.classifyFailure(statusCode: 400, errorBody: "context length exceeded")
        XCTAssertEqual(category, .contextLimitOverflow)
        let decision = AttacheFallbackRecompiler.shouldFallback(for: category)
        XCTAssertFalse(decision.shouldFallback, "context-limit never auto-falls back")
    }

    func testOverflowRecoveryPreservesDraft() {
        let recovery = AttacheFallbackRecompiler.overflowRecovery(preserving: "my important question")
        XCTAssertEqual(recovery.preservedDraft, "my important question", "draft preserved")
        XCTAssertTrue(recovery.requiresUserAction, "requires explicit user action")
        XCTAssertTrue(recovery.suggestedStrategies.contains(.automatic))
        XCTAssertTrue(recovery.suggestedStrategies.contains(.efficient))
    }

    // Criterion 6: authentication failures never auto-fallback.
    func testAuthFailureNeverAutoFallback() {
        let category = AttacheFallbackRecompiler.classifyFailure(statusCode: 401, errorBody: nil)
        XCTAssertEqual(category, .authenticationFailure)
        let decision = AttacheFallbackRecompiler.shouldFallback(for: category)
        XCTAssertFalse(decision.shouldFallback, "auth failure never auto-falls back")
    }

    // Criterion 7: effectful tools are never replayed.
    func testEffectfulToolsNeverReplayed() throws {
        var tracker = AttacheToolEffectTracker()
        tracker.recordEffect(toolName: "send_message", callID: "call-1")
        let snapshot = makeInput(model: primaryModel)
        let attempt = try AttacheFallbackRecompiler.recompileForFallback(
            snapshot: snapshot, items: basicItems(),
            fallbackModel: fallbackModel,
            fallbackCapability: makeProfile(context: 32_000),
            strategy: .automatic,
            fallbackRequestIsRemote: false,
            effectTracker: tracker,
            attemptNumber: 1
        )
        XCTAssertTrue(AttacheFallbackRecompiler.neverReplaysEffectfulTools(attempt: attempt),
                      "effectful tools are never replayed on fallback")
        XCTAssertTrue(attempt.effectTracker.prohibitsReplay(), "tracker prohibits replay")
    }

    // Criterion 8: unknown fallback capacity uses an unknown-capacity plan,
    // never the primary model's limit.
    func testUnknownCapacityUsesUnknownPlan() {
        let unknownProfile = AttacheModelCapabilityProfile(architecturalMaximum: nil, confidence: .unknown, provenance: .unknown)
        XCTAssertTrue(AttacheFallbackRecompiler.unknownCapacityUsesUnknownPlan(fallbackCapability: unknownProfile),
                      "unknown capacity is flagged as unknown")
        let knownProfile = makeProfile(context: 32_000)
        XCTAssertFalse(AttacheFallbackRecompiler.unknownCapacityUsesUnknownPlan(fallbackCapability: knownProfile),
                       "known capacity is not unknown")
    }

    // Criterion 9: a new call starts with the primary again (per-call reset).
    func testFallbackStateResetsForNewTurn() {
        var state = AttacheFallbackState(maxAttempts: 5)
        XCTAssertEqual(state.currentAttemptNumber, 0)
        XCTAssertFalse(state.hasAttempted)
        // Simulate a fallback attempt.
        state.simulateAttemptNumber(2)
        // Reset for new turn.
        state.resetForNewTurn()
        XCTAssertEqual(state.currentAttemptNumber, 0, "resets to primary for new turn")
        XCTAssertFalse(state.hasAttempted)
    }

    func testFallbackStateExhaustion() {
        var state = AttacheFallbackState(maxAttempts: 3)
        XCTAssertFalse(state.isExhausted)
        state.simulateAttemptNumber(3)
        XCTAssertTrue(state.isExhausted, "exhausted after max attempts")
    }

    // Rate limit is auto-fallback eligible.
    func testRateLimitAutoFallbackEligible() {
        let category = AttacheFallbackRecompiler.classifyFailure(statusCode: 429, errorBody: nil)
        XCTAssertEqual(category, .rateLimit)
        XCTAssertTrue(AttacheFallbackRecompiler.shouldFallback(for: category).shouldFallback)
    }

    // Model unavailable is auto-fallback eligible.
    func testModelUnavailableAutoFallbackEligible() {
        let category = AttacheFallbackRecompiler.classifyFailure(statusCode: 503, errorBody: nil)
        XCTAssertEqual(category, .modelUnavailable)
        XCTAssertTrue(AttacheFallbackRecompiler.shouldFallback(for: category).shouldFallback)
    }

    // Transient transport is auto-fallback eligible.
    func testTransientTransportAutoFallbackEligible() {
        let category = AttacheFallbackRecompiler.classifyFailure(statusCode: 502, errorBody: nil)
        XCTAssertEqual(category, .transientTransport)
        XCTAssertTrue(AttacheFallbackRecompiler.shouldFallback(for: category).shouldFallback)
    }

    // Recompiled request uses the fallback model identity, not the primary's.
    func testRecompiledUsesFallbackModelIdentity() throws {
        let snapshot = makeInput(model: primaryModel)
        let attempt = try AttacheFallbackRecompiler.recompileForFallback(
            snapshot: snapshot, items: basicItems(),
            fallbackModel: fallbackModel,
            fallbackCapability: makeProfile(context: 32_000),
            strategy: .automatic,
            fallbackRequestIsRemote: false,
            effectTracker: AttacheToolEffectTracker(),
            attemptNumber: 1
        )
        XCTAssertEqual(attempt.modelIdentity, fallbackModel, "uses the fallback model identity")
        XCTAssertNotEqual(attempt.modelIdentity, primaryModel, "not the primary model")
    }

    // Recompiled budget is from the fallback capability, not the primary's.
    func testRecompiledBudgetFromFallbackCapability() throws {
        let snapshot = makeInput(model: primaryModel)
        let attempt = try AttacheFallbackRecompiler.recompileForFallback(
            snapshot: snapshot, items: basicItems(),
            fallbackModel: fallbackModel,
            fallbackCapability: makeProfile(context: 8_000),
            strategy: .efficient,
            fallbackRequestIsRemote: false,
            effectTracker: AttacheToolEffectTracker(),
            attemptNumber: 1
        )
        // The hard limit should be derived from 8K, not 1M.
        if let hardLimit = attempt.compiledRequest.budgetPlan.effectiveHardLimit {
            XCTAssertLessThanOrEqual(hardLimit, 8_000, "budget from fallback capability")
        }
    }
}
