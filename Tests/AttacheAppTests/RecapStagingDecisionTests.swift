import AttacheCore
import XCTest
@testable import AttacheApp

/// INF-353: the cost-preview notice must appear above thresholds (more than
/// 40 items, or a plan with more than one stage) and never below them. This
/// exercises `RecapStaging.decision(for:budgetPlan:)` directly, free of
/// `AppModel`/`UserDefaults`/the presentation service, so it is fast and
/// touches no shared state.
final class RecapStagingDecisionTests: XCTestCase {
    private func item(_ id: String, session: String, text: String = "A brief update.") -> RecapStageItem {
        RecapStageItem(id: id, sessionTitle: session, summaryText: text, createdAt: Date())
    }

    private func generousBudgetPlan() -> AttacheContextBudgetPlan {
        AttacheContextBudgetPlan(
            effectiveHardLimit: 128_000,
            outputReserve: 512,
            toolReserve: 256,
            safetyMargin: 256,
            retrievalReserve: 512,
            framingOverhead: 32,
            currentUserInputTokens: 20,
            remainingEvidenceBudget: 100_000,
            strategy: .automatic,
            unknownCapacity: false,
            estimatorFamily: "unicode-fallback",
            estimatorVersion: 2
        )
    }

    private func tightBudgetPlan() -> AttacheContextBudgetPlan {
        AttacheContextBudgetPlan(
            effectiveHardLimit: 2_000,
            outputReserve: 256,
            toolReserve: 128,
            safetyMargin: 128,
            retrievalReserve: 128,
            framingOverhead: 16,
            currentUserInputTokens: 20,
            remainingEvidenceBudget: 256,
            strategy: .automatic,
            unknownCapacity: false,
            estimatorFamily: "unicode-fallback",
            estimatorVersion: 2
        )
    }

    // Below both thresholds: a handful of items with a generous budget stays
    // a single stage and needs no cost preview. Matches "recap with 3 items
    // behaves exactly as before."
    func testBelowBothThresholdsNeedsNoCostPreview() {
        let items = (0..<3).map { item("i\($0)", session: "S\($0)") }

        let decision = RecapStaging.decision(for: items, budgetPlan: generousBudgetPlan())

        XCTAssertFalse(decision.needsCostPreview)
        XCTAssertTrue(decision.plan.isSingleStage)
        XCTAssertEqual(decision.plan.estimatedCallCount, 1)
    }

    // Above the item-count threshold even with a generous budget: previews.
    func testAboveItemCountThresholdNeedsCostPreviewEvenWithASingleStage() {
        let items = (0..<41).map { item("i\($0)", session: "S\($0 % 3)", text: "x") }

        let decision = RecapStaging.decision(for: items, budgetPlan: generousBudgetPlan())

        XCTAssertTrue(items.count > RecapStaging.costPreviewItemCountThreshold)
        XCTAssertTrue(decision.needsCostPreview)
    }

    // Exactly at the threshold: still no preview (threshold is "exceeds 40").
    func testExactlyAtItemCountThresholdNeedsNoCostPreview() {
        let items = (0..<RecapStaging.costPreviewItemCountThreshold).map { item("i\($0)", session: "S\($0 % 3)", text: "x") }

        let decision = RecapStaging.decision(for: items, budgetPlan: generousBudgetPlan())

        XCTAssertFalse(decision.needsCostPreview)
    }

    // Below the item-count threshold but a tight budget forces multiple
    // stages: previews on stage count alone.
    func testMultiStagePlanNeedsCostPreviewEvenBelowItemCountThreshold() {
        let items = (0..<10).map { i in
            item("i\(i)", session: "S\(i)", text: String(repeating: "detail ", count: 200))
        }

        let decision = RecapStaging.decision(for: items, budgetPlan: tightBudgetPlan())

        XCTAssertLessThanOrEqual(items.count, RecapStaging.costPreviewItemCountThreshold)
        XCTAssertGreaterThan(decision.plan.stages.count, 1)
        XCTAssertTrue(decision.needsCostPreview)
    }

    // No items: no preview (playInboxRecap's own empty guard runs first, but
    // the decision function itself should stay inert too).
    func testEmptyItemsNeedsNoCostPreview() {
        let decision = RecapStaging.decision(for: [], budgetPlan: generousBudgetPlan())

        XCTAssertFalse(decision.needsCostPreview)
        XCTAssertTrue(decision.plan.stages.isEmpty)
    }
}
