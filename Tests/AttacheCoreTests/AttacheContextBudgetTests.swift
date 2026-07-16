import AttacheCore
import XCTest

final class AttacheContextBudgetTests: XCTestCase {

    private func profile(context: Int?, confidence: AttacheCapabilityConfidence = .authoritative) -> AttacheModelCapabilityProfile {
        AttacheModelCapabilityProfile(architecturalMaximum: context, confidence: confidence, provenance: .providerMetadata)
    }

    // MARK: - Fallback estimator (acceptance 5: CJK/emoji/code not underestimated)

    func testCJKIsNotDangerouslyUnderestimated() {
        let estimator = AttacheFallbackTokenEstimator()
        // 20 CJK characters should count as ~20 tokens, not ~5 (4 chars/token).
        let cjk = String(repeating: "文", count: 20)
        XCTAssertGreaterThanOrEqual(estimator.estimate(text: cjk), 20,
                                    "CJK must count ~1 token per char, not be under-counted as 4 chars/token.")
    }

    func testEmojiIsDense() {
        let estimator = AttacheFallbackTokenEstimator()
        let emoji = String(repeating: "🚀", count: 10)
        XCTAssertGreaterThanOrEqual(estimator.estimate(text: emoji), 10)
    }

    func testCombiningDiacriticsAreDense() {
        let estimator = AttacheFallbackTokenEstimator()
        let combined = "cafe\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}"
        XCTAssertGreaterThan(estimator.estimate(text: combined), 1, "combining marks should not collapse to near-zero.")
    }

    func testFallbackRetainsProseBaselineForLowEntropyASCII() {
        let estimator = AttacheFallbackTokenEstimator()
        let latin = String(repeating: "a", count: 40)
        XCTAssertEqual(estimator.estimate(text: latin), 10)
    }

    func testMinifiedJSONURLsBase64AndRandomIdentifiersUseByteEnvelope() {
        let estimator = AttacheFallbackTokenEstimator()
        let json = "{\"key\":\"" + String(repeating: "x", count: 200) + "\"}"
        let url = "https://example.com/" + String(repeating: "p", count: 200)
        let base64 = String(repeating: "A9+/", count: 100) + "=="
        let identifiers = (0..<100).map { "id\($0)_f7A9bC2dE4" }.joined(separator: ",")
        XCTAssertGreaterThan(estimator.estimate(text: json), 50)
        XCTAssertGreaterThan(estimator.estimate(text: url), 50)
        XCTAssertEqual(estimator.estimate(text: base64), base64.utf8.count)
        XCTAssertGreaterThanOrEqual(
            estimator.estimate(text: identifiers),
            Int(Double(identifiers.utf8.count) * 0.9)
        )
    }

    func testDenseUnicodeAndEmojiSequencesUseUTF8ByteEnvelope() {
        let estimator = AttacheFallbackTokenEstimator()
        let samples = [
            String(repeating: "文", count: 100),
            String(repeating: "👨‍👩‍👧‍👦", count: 40),
            String(repeating: "🇺🇸", count: 60),
            String(repeating: "e\u{0301}", count: 100)
        ]
        for sample in samples {
            XCTAssertGreaterThanOrEqual(
                estimator.estimate(text: sample),
                sample.unicodeScalars.filter { $0.value > 0x7F }.reduce(0) { $0 + $1.utf8.count }
            )
            XCTAssertGreaterThanOrEqual(estimator.estimate(text: sample), sample.unicodeScalars.count)
        }
    }

    // MARK: - Plans within hard limits (acceptance 1)

    func testPlansStayWithinHardLimits() throws {
        for context in [8_000, 64_000, 1_000_000, 10_000_000] {
            let plan = try ContextBudgetPlanner.plan(
                capability: profile(context: context), strategy: .maximumCoverage,
                role: .conversation, currentUserInput: "What did the agent do?"
            )
            XCTAssertNotNil(plan.effectiveHardLimit)
            XCTAssertEqual(plan.effectiveHardLimit, context)
            XCTAssertLessThanOrEqual(plan.totalReserved + (plan.remainingEvidenceBudget ?? 0), context,
                                     "Plan for \(context) must stay within the hard limit.")
        }
    }

    func testLargeProfilesAllocateLargerEvidenceBudgets() throws {
        let plan8k = try ContextBudgetPlanner.plan(capability: profile(context: 8_000), strategy: .maximumCoverage, role: .conversation, currentUserInput: "hi")
        let plan1m = try ContextBudgetPlanner.plan(capability: profile(context: 1_000_000), strategy: .maximumCoverage, role: .conversation, currentUserInput: "hi")
        XCTAssertGreaterThan(plan1m.remainingEvidenceBudget ?? 0, plan8k.remainingEvidenceBudget ?? 0,
                             "A 1M context model must allocate a meaningfully larger evidence budget than 8K.")
    }

    // MARK: - Every plan accounts for reserves (acceptance 2)

    func testPlanAccountsForAllReserves() throws {
        let plan = try ContextBudgetPlanner.plan(
            capability: profile(context: 32_000), strategy: .automatic,
            role: .conversation, currentUserInput: "Tell me about the session.",
            toolDefinitionsText: "[{\"name\":\"read_file\"}]",
            bridgeWrapperText: "bridge wrapper framing"
        )
        XCTAssertGreaterThan(plan.outputReserve, 0)
        XCTAssertGreaterThan(plan.toolReserve, 0)
        XCTAssertGreaterThan(plan.safetyMargin, 0)
        XCTAssertGreaterThan(plan.retrievalReserve, 0)
        XCTAssertGreaterThan(plan.framingOverhead, 0)
        XCTAssertGreaterThan(plan.currentUserInputTokens, 0)
    }

    // MARK: - Strategy monotonicity (acceptance 3)

    func testStrategyMonotonicity() throws {
        let cap = profile(context: 64_000)
        let efficient = try ContextBudgetPlanner.plan(capability: cap, strategy: .efficient, role: .conversation, currentUserInput: "hi")
        let automatic = try ContextBudgetPlanner.plan(capability: cap, strategy: .automatic, role: .conversation, currentUserInput: "hi")
        let maximum = try ContextBudgetPlanner.plan(capability: cap, strategy: .maximumCoverage, role: .conversation, currentUserInput: "hi")
        let e = efficient.remainingEvidenceBudget ?? 0
        let a = automatic.remainingEvidenceBudget ?? 0
        let m = maximum.remainingEvidenceBudget ?? 0
        XCTAssertLessThanOrEqual(e, a, "Efficient must never allocate more than Automatic.")
        XCTAssertLessThanOrEqual(a, m, "Automatic must never allocate more than Maximum coverage.")
    }

    func testReserveInvariantsNeverExceedHardLimit() throws {
        for context in [8_000, 32_000, 128_000] {
            for strategy in [AttacheContextStrategy.efficient, .automatic, .maximumCoverage] {
                let plan = try ContextBudgetPlanner.plan(
                    capability: profile(context: context), strategy: strategy,
                    role: .conversation, currentUserInput: "a question"
                )
                XCTAssertLessThanOrEqual(plan.totalReserved, plan.effectiveHardLimit ?? Int.max,
                                         "Reserves must never exceed the hard limit.")
            }
        }
    }

    // MARK: - Unknown capacity (acceptance 4)

    func testUnknownCapacityProducesConservativeLabeledPlan() throws {
        let plan = try ContextBudgetPlanner.plan(
            capability: profile(context: nil, confidence: .unknown), strategy: .automatic,
            role: .conversation, currentUserInput: "hi"
        )
        XCTAssertTrue(plan.unknownCapacity, "Unknown capacity must be labeled, not disguised as a provider fact.")
        XCTAssertEqual(plan.effectiveHardLimit, ContextBudgetPlanner.unknownCapacityEnvelope,
                       "Unknown capacity uses the progressive envelope, not a fake hard limit.")
        XCTAssertNotNil(plan.remainingEvidenceBudget)
    }

    func testUnknownCapacityShrinksProspectiveReservesBeforeRejectingProtectedPrompt() throws {
        let protectedPrompt = String(repeating: "a", count: 20_000)
        let plan = try ContextBudgetPlanner.plan(
            capability: profile(context: nil, confidence: .unknown),
            strategy: .automatic,
            role: .conversation,
            currentUserInput: "hello",
            protectedContentText: protectedPrompt
        )
        XCTAssertLessThanOrEqual(plan.totalReserved, ContextBudgetPlanner.unknownCapacityEnvelope)
        XCTAssertGreaterThanOrEqual(plan.toolReserve, 128)
        XCTAssertGreaterThanOrEqual(plan.retrievalReserve, 128)
    }

    // MARK: - Protected-content overflow (acceptance 6)

    func testProtectedContentOverflowFailsAndPreservesDraft() {
        // An 8K model with a user input so large it cannot fit after reserves.
        let hugeInput = String(repeating: "x", count: 40_000)
        XCTAssertThrowsError(try ContextBudgetPlanner.plan(
            capability: profile(context: 8_000), strategy: .automatic,
            role: .conversation, currentUserInput: hugeInput
        )) { error in
            guard case .protectedContentOverflow(let draft, _, let hardLimit) = error as? AttacheBudgetFailure else {
                return XCTFail("Expected protectedContentOverflow, got \(error)")
            }
            XCTAssertEqual(draft, hugeInput, "The user draft must be preserved on overflow.")
            XCTAssertEqual(hardLimit, 8_000)
        }
    }

    // MARK: - Custom policy validation (acceptance 7)

    func testCustomPolicyValidationCatchesIncompatibleLimits() {
        let invalidCustom = AttacheContextCustomPolicy(hardInputLimit: 4_000, effectiveInputLimit: 8_000)
        let strategy = AttacheContextStrategy(.custom, custom: invalidCustom)
        XCTAssertThrowsError(try ContextBudgetPlanner.plan(
            capability: profile(context: 32_000), strategy: strategy,
            role: .conversation, currentUserInput: "hi"
        )) { error in
            guard case .invalidCustomPolicy(let policyError) = error as? AttacheBudgetFailure else {
                return XCTFail("Expected invalidCustomPolicy, got \(error)")
            }
            XCTAssertEqual(policyError, .effectiveExceedsHard(effective: 8_000, hard: 4_000))
        }
    }

    func testCustomPolicyOvercommittedReservesFail() {
        let overcommitted = AttacheContextCustomPolicy(hardInputLimit: 1_000, outputReserve: 500, toolReserve: 500, safetyMargin: 100)
        let strategy = AttacheContextStrategy(.custom, custom: overcommitted)
        XCTAssertThrowsError(try ContextBudgetPlanner.plan(
            capability: profile(context: 32_000), strategy: strategy, role: .conversation, currentUserInput: "hi"
        )) { error in
            guard case .invalidCustomPolicy(.overcommittedReserves) = error as? AttacheBudgetFailure else {
                return XCTFail("Expected overcommittedReserves, got \(error)")
            }
        }
    }

    func testValidCustomPolicyProducesPlan() throws {
        let custom = AttacheContextCustomPolicy(hardInputLimit: 32_000, effectiveInputLimit: 28_000, outputReserve: 2_048, toolReserve: 1_024, safetyMargin: 256)
        let plan = try ContextBudgetPlanner.plan(
            capability: profile(context: 64_000), strategy: AttacheContextStrategy(.custom, custom: custom),
            role: .conversation, currentUserInput: "hi"
        )
        XCTAssertEqual(plan.outputReserve, 2_048)
        XCTAssertEqual(plan.toolReserve, 1_024)
        XCTAssertEqual(plan.safetyMargin, 256)
    }

    // MARK: - Determinism (acceptance 8)

    func testPlanningIsDeterministicForEqualInputs() throws {
        let cap = profile(context: 32_000)
        let input = "What did the agent change?"
        let plan1 = try ContextBudgetPlanner.plan(capability: cap, strategy: .automatic, role: .conversation, currentUserInput: input)
        let plan2 = try ContextBudgetPlanner.plan(capability: cap, strategy: .automatic, role: .conversation, currentUserInput: input)
        XCTAssertEqual(plan1, plan2)
    }

    func testEstimatorIsVersioned() {
        let estimator = AttacheFallbackTokenEstimator()
        XCTAssertEqual(estimator.version, 2)
        XCTAssertEqual(estimator.family, "unicode-fallback")
    }

    func testCalibrationRaisesUnderestimatedFallback() {
        let base = AttacheFallbackTokenEstimator()
        let optimistic = AttacheCalibratedTokenEstimator(
            base: base,
            correction: AttacheCalibrationCorrection(
                factor: 0.5,
                sampleCount: 10,
                aggregateError: 0.5,
                isActionable: true
            )
        )
        let conservative = AttacheCalibratedTokenEstimator(
            base: base,
            correction: AttacheCalibrationCorrection(
                factor: 1.25,
                sampleCount: 10,
                aggregateError: 0.25,
                isActionable: true
            )
        )
        XCTAssertEqual(optimistic.estimate(text: "abcdef"), 2)
        XCTAssertEqual(conservative.estimate(text: "abcdef"), 3)
    }
}
