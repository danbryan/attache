import AttacheCore
import Foundation

/// Deterministic, content-free UI state used only by the packaged AX context
/// smoke. The fixture does not stand in for production wiring. A separate
/// hard gate requires AppModel to publish overflow and exhaustive-review state
/// from real request paths.
@MainActor
enum AttacheContextSmokeFixtures {
    static func installIfRequested(model: AppModel) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ATTACHE_UI_TEST"] == "1",
              environment["ATTACHE_CONTEXT_SMOKE_FIXTURES"] == "1" else {
            return
        }
        let omissions = Set(
            (environment["ATTACHE_CONTEXT_SMOKE_OMIT"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
        let state = AttacheContextUIState.shared

        if !omissions.contains("memory") {
            state.setMemoryMode(.suggest)
            let saved = AttacheMemoryRecord(
                id: "context-smoke-saved",
                statement: "Synthetic saved memory for the accessibility smoke.",
                type: .preference,
                scope: .global,
                sourceKind: .userConfirmed,
                sourceLocator: "context-smoke:fixture",
                confidence: .authoritative,
                sensitivity: .low,
                egress: .localOnly
            )
            let proposal = AttacheMemoryProposal(
                id: "context-smoke-pending",
                statement: "Synthetic pending memory for the accessibility smoke.",
                type: .standingInstruction,
                scope: .global,
                sourceKind: .modelProposed,
                sourceLocator: "context-smoke:fixture",
                confidence: .authoritative,
                sensitivity: .low,
                egress: .localOnly,
                requiresConfirmation: true
            )
            state.publishMemorySnapshot(
                records: [saved],
                reviewItems: [AttacheMemoryReviewItem(
                    proposal: proposal,
                    disposition: .queuedForReview
                )]
            )
        }

        if !omissions.contains("receipt") {
            let receipt = fixtureReceipt()
            if let encoded = receipt.encodedMetadataValue() {
                let event = NormalizedEvent(
                    source: "local",
                    eventType: "update",
                    externalSessionID: "context-smoke-receipt",
                    title: "Context smoke receipt",
                    text: "Synthetic response with a redacted fallback context receipt.",
                    metadata: [
                        "source_time": "2026-07-15T12:00:00.000Z",
                        AttacheContextReceiptView.metadataKey: encoded
                    ]
                )
                if let card = try? model.store.insertEvent(
                    event,
                    status: .heard,
                    heardAt: Date(timeIntervalSince1970: 1_752_580_800)
                ) {
                    model.reloadCards(select: card.id)
                }
            }
        }

        if !omissions.contains("overflow") {
            state.presentOverflowRecovery(AttacheOverflowRecovery(
                preservedDraft: "Synthetic preserved context-smoke draft"
            )) { _, _ in }
        }

        if !omissions.contains("review") {
            // The accessibility fixture exercises the native review state
            // machine without a real frozen session or provider. AppModel's
            // production callbacks correctly fail closed for this synthetic
            // identity, so replace only those callbacks in UI-test mode. The
            // production wiring and stale-source behavior remain covered by
            // their dedicated runtime tests.
            state.onStartExhaustiveReview = { _ in }
            state.onCancelExhaustiveReview = { _ in }
            state.onResumeExhaustiveReview = { _ in }
            state.presentExhaustiveReview(AttacheExhaustiveReviewUIState(
                id: "context-smoke-review",
                sessionTitle: "Synthetic context smoke session",
                modelLabel: "Local fixture model",
                strategyLabel: "Automatic",
                egressLabel: "On-device",
                estimatedCalls: 3,
                phase: .preview,
                coveredRanges: 0,
                eligibleRanges: 4,
                completedCalls: 0,
                omittedRanges: 0
            ))
        }
    }

    private static func fixtureReceipt() -> AttacheContextReceiptView {
        let primary = AttacheReceiptAttemptSummary(
            attemptNumber: 1,
            isFallback: false,
            modelSummary: AttacheReceiptModelSummary(
                provider: "local-fixture",
                model: "primary",
                reasoningLevel: "low",
                strategyKind: AttacheContextStrategyKind.automatic.rawValue,
                estimatedInputTokens: 420,
                effectiveBudget: 8_000,
                outputReserve: 800,
                toolReserve: 600,
                capabilityProvenance: AttacheCapabilityProvenance.providerMetadata.rawValue,
                capabilityFreshness: "2026-07-15T12:00:00Z"
            ),
            sourceSummaries: [AttacheReceiptSourceSummary(
                source: "activePersonality",
                count: 1,
                disposition: .included
            )],
            totalEstimatedTokens: 420,
            stagedProcessingRequired: false,
            focusedSessionDisplay: nil,
            recompiledForFallback: false
        )
        let fallback = AttacheReceiptAttemptSummary(
            attemptNumber: 2,
            isFallback: true,
            modelSummary: AttacheReceiptModelSummary(
                provider: "local-fixture",
                model: "fallback",
                reasoningLevel: "none",
                strategyKind: AttacheContextStrategyKind.efficient.rawValue,
                estimatedInputTokens: 280,
                effectiveBudget: 4_000,
                outputReserve: 500,
                toolReserve: 300,
                capabilityProvenance: AttacheCapabilityProvenance.providerMetadata.rawValue,
                capabilityFreshness: "2026-07-15T12:00:00Z"
            ),
            sourceSummaries: [AttacheReceiptSourceSummary(
                source: "activePersonality",
                count: 1,
                disposition: .included
            )],
            totalEstimatedTokens: 280,
            stagedProcessingRequired: false,
            focusedSessionDisplay: nil,
            recompiledForFallback: true
        )
        return AttacheContextReceiptView(
            cardID: "context-smoke-receipt",
            attempts: [primary, fallback]
        )
    }
}
