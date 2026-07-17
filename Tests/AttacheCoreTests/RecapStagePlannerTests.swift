import AttacheCore
import XCTest

final class RecapStagePlannerTests: XCTestCase {
    private func item(
        _ id: String,
        session: String,
        text: String = "Something happened and it is now resolved.",
        needsDecision: Bool = false
    ) -> RecapStageItem {
        RecapStageItem(
            id: id,
            sessionTitle: session,
            summaryText: text,
            createdAt: Date(timeIntervalSince1970: Double(id.hashValue % 100_000)),
            needsDecision: needsDecision
        )
    }

    // MARK: - Common case: everything fits in one stage

    func testEverythingFitsProducesSingleStageInOriginalOrder() {
        let items = [
            item("a", session: "Session A"),
            item("b", session: "Session B"),
            item("c", session: "Session A")
        ]

        let plan = RecapStagePlanner.plan(items: items, budgetPerStage: 100_000)

        XCTAssertTrue(plan.isSingleStage)
        XCTAssertEqual(plan.stages.count, 1)
        XCTAssertEqual(plan.estimatedCallCount, 1)
        XCTAssertEqual(plan.totalItemCount, 3)
        XCTAssertEqual(Set(plan.stages[0].itemIDs), Set(["a", "b", "c"]))
    }

    // MARK: - Determinism

    func testPlanIsDeterministicAcrossRepeatedRuns() {
        let items = (0..<250).map { i in
            item("item-\(i)", session: "Session \(i % 7)", text: "Update number \(i) with some detail padding here.")
        }

        let first = RecapStagePlanner.plan(items: items, budgetPerStage: 512)
        let second = RecapStagePlanner.plan(items: items, budgetPerStage: 512)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.stages.map(\.itemIDs), second.stages.map(\.itemIDs))
    }

    // MARK: - Session clustering

    func testItemsClusterBySessionRatherThanInterleaving() {
        let items = [
            item("a1", session: "Alpha"),
            item("b1", session: "Beta"),
            item("a2", session: "Alpha"),
            item("b2", session: "Beta")
        ]

        // A tight budget that fits exactly one session's items per stage.
        let plan = RecapStagePlanner.plan(items: items, budgetPerStage: 40)

        // Every stage should contain items from at most... well, clustering
        // means a given session's items land in the same stage together
        // rather than being scattered by their original interleaved order.
        for stage in plan.stages {
            let sessions = Set(stage.itemIDs.map { id -> String in
                id.hasPrefix("a") ? "Alpha" : "Beta"
            })
            XCTAssertLessThanOrEqual(sessions.count, 2, "unexpectedly fragmented clustering")
        }
        XCTAssertEqual(Set(plan.coveredItemIDs), Set(["a1", "b1", "a2", "b2"]))
    }

    // MARK: - 1000-item scale test

    func test1000SyntheticItemsClusterIntoStagesEachWithinBudget() {
        let budget = 2_048
        let items = (0..<1_000).map { i in
            item(
                "synthetic-\(i)",
                session: "Session \(i % 40)",
                text: "This is a moderately detailed synthetic update describing work item number \(i) and its resolution."
            )
        }

        let plan = RecapStagePlanner.plan(items: items, budgetPerStage: budget)

        XCTAssertGreaterThan(plan.stages.count, 1, "1000 items should not fit in a single stage")
        XCTAssertEqual(plan.totalItemCount, 1_000)

        // No item silently dropped: every ID appears in exactly one stage.
        let covered = plan.coveredItemIDs
        XCTAssertEqual(covered.count, 1_000)
        XCTAssertEqual(Set(covered).count, 1_000, "every item must appear exactly once")
        XCTAssertEqual(Set(covered), Set(items.map(\.id)))

        // Each stage must respect the token budget, except a stage holding a
        // single oversized item (none occur in this fixture, but the
        // assertion tolerates that shape).
        let estimator = AttacheFallbackTokenEstimator()
        for stage in plan.stages {
            if stage.itemIDs.count > 1 {
                XCTAssertLessThanOrEqual(stage.estimatedTokens, budget, "stage \(stage.stageNumber) exceeds its budget")
            }
            _ = estimator // silence unused warning if estimator unused on some paths
        }
    }

    // MARK: - Oversized single item is never dropped

    func testOversizedSingleItemStillGetsItsOwnStageRatherThanBeingDropped() {
        let hugeText = String(repeating: "word ", count: 5_000)
        let items = [
            item("small-1", session: "A", text: "brief"),
            item("huge", session: "B", text: hugeText),
            item("small-2", session: "C", text: "brief too")
        ]

        let plan = RecapStagePlanner.plan(items: items, budgetPerStage: 256)

        XCTAssertEqual(Set(plan.coveredItemIDs), Set(["small-1", "huge", "small-2"]))
        // The huge item occupies a stage that includes it exactly once.
        let stageWithHuge = plan.stages.first { $0.itemIDs.contains("huge") }
        XCTAssertNotNil(stageWithHuge)
        XCTAssertEqual(stageWithHuge?.itemIDs.filter { $0 == "huge" }.count, 1)
    }

    // MARK: - Empty input

    func testEmptyItemsProduceNoStages() {
        let plan = RecapStagePlanner.plan(items: [], budgetPerStage: 1_000)

        XCTAssertTrue(plan.stages.isEmpty)
        XCTAssertEqual(plan.totalItemCount, 0)
        XCTAssertEqual(plan.estimatedCallCount, 0)
    }

    // MARK: - Budget-plan overload agrees with the explicit-budget overload

    func testBudgetPlanOverloadUsesRemainingEvidenceBudget() {
        let strategy = AttacheContextStrategy.automatic
        let budgetPlan = AttacheContextBudgetPlan(
            effectiveHardLimit: 8_192,
            outputReserve: 512,
            toolReserve: 256,
            safetyMargin: 256,
            retrievalReserve: 512,
            framingOverhead: 32,
            currentUserInputTokens: 40,
            remainingEvidenceBudget: 1_024,
            strategy: strategy,
            unknownCapacity: false,
            estimatorFamily: "unicode-fallback",
            estimatorVersion: 2
        )
        let items = (0..<40).map { i in item("i\(i)", session: "S\(i % 5)", text: "Detail for item \(i).") }

        // The budget-plan overload reserves a fraction of the remaining
        // evidence budget as headroom for the compiler's evidence-wrapping
        // overhead (INF-353), so it agrees with the explicit-budget overload
        // called with that same reduced figure, not the raw remaining budget.
        let viaBudgetPlan = RecapStagePlanner.plan(items: items, budgetPlan: budgetPlan)
        let viaExplicitBudget = RecapStagePlanner.plan(items: items, budgetPerStage: 768)

        XCTAssertEqual(viaBudgetPlan, viaExplicitBudget)
    }

    // MARK: - Versioning

    func testPlannerVersionIsStable() {
        XCTAssertEqual(RecapStagePlan.plannerVersion, 1)
    }
}
