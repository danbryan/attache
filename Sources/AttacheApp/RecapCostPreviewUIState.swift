import AttacheCore
import Foundation

/// A pending cost-preview notice for a recap that exceeds the "just do it"
/// thresholds (INF-353): more than 40 items, or a `RecapStagePlanner` plan
/// with more than one stage. Mirrors `AttacheExhaustiveReviewUIState`'s
/// preview-phase shape, scoped to what the recap banner needs to render.
struct RecapCostPreviewUIState: Equatable, Identifiable {
    let id: String
    let itemCount: Int
    let sessionCount: Int
    let estimatedCalls: Int
}

/// The staged recap `AppModel.playInboxRecap` deferred pending an explicit
/// Start/Not now decision from `RecapCostPreviewUIState`.
struct PendingRecapExecution {
    let cards: [VoicemailCard]
    let plan: RecapStagePlan
    let personality: Personality?
}

/// The pure decision of whether a recap needs the cost-preview notice before
/// spending any model calls (INF-353). Free of `AppModel`/`UserDefaults`/the
/// presentation service so it is directly unit-testable: "cost preview
/// appears above thresholds and not below."
enum RecapStaging {
    /// Above this item count, a recap always previews first even if the
    /// planner still finds a single stage that fits (a very large inbox with
    /// short items could otherwise slip through as one huge call).
    static let costPreviewItemCountThreshold = 40

    struct Decision: Equatable {
        let plan: RecapStagePlan
        let sessionCount: Int
        let needsCostPreview: Bool
    }

    static func decision(for items: [RecapStageItem], budgetPlan: AttacheContextBudgetPlan) -> Decision {
        let plan = RecapStagePlanner.plan(items: items, budgetPlan: budgetPlan)
        let sessionCount = AttachePersonality.recapSessionCount(items.map(\.sessionTitle))
        let needsCostPreview = items.count > costPreviewItemCountThreshold || !plan.isSingleStage
        return Decision(plan: plan, sessionCount: sessionCount, needsCostPreview: needsCostPreview)
    }
}
