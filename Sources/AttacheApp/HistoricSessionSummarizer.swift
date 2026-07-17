import AttacheCore
import Foundation

/// The entry point for INF-370 "Summarize any historic session into a
/// voicemail card, across all supported sources". Composes existing
/// machinery rather than inventing a parallel pipeline: session discovery and
/// focus grants (INF-315, `SessionContextRuntime`), the whole-session
/// exhaustive-review coordinator (INF-329, `AttacheExhaustiveReviewCoordinator`),
/// and the card store. Works for any indexed session regardless of watch
/// state, including fully historic ones the user was never listening to.
struct HistoricSessionSummaryRequest: Equatable {
    let sessionID: String
    let sourceKind: String
    let displayTitle: String
    let workingDirectory: String?
}

enum HistoricSessionSummaryOutcome: Equatable {
    case card(VoicemailCard)
    /// Ephemeral (don't-record) playback: speak the result but never persist
    /// a card. No INF-357 don't-record registry exists on this branch (see
    /// the INF-370 Linear comment); `Options.persistCard = false` exercises
    /// this path directly so a future registry integration only needs to set
    /// that flag, not add a new outcome case.
    case ephemeral(spokenText: String)
    case failedClosed(reason: String)
}

/// Drives one historic-session summary request end to end. Read-only:
/// exhaustive review stages carry no effectful tools (INF-329), and this
/// summarizer never touches the frozen agent-send destinations.
final class HistoricSessionSummarizer {
    private let runtime: SessionContextRuntime
    private let cardStore: CardStore

    init(runtime: SessionContextRuntime, cardStore: CardStore) {
        self.runtime = runtime
        self.cardStore = cardStore
    }

    struct Options {
        var strategy: AttacheContextStrategy = .automatic
        var modelKey: String
        var capability: AttacheModelCapabilityProfile
        var egressClass: String
        var provider: String
        var reasoningLevel: String?
        var profilePrompt: String = AttachePersonality.defaultProfilePrompt
        var memoryContext: String?
        var spokenLanguageName: String?
        /// False routes to `.ephemeral` instead of persisting a card (the
        /// don't-record path, INF-370 step 5).
        var persistCard: Bool = true
    }

    /// Runs one stage against the frozen evidence for that stage's episodes
    /// and returns the stage's summary text. The real implementation is a
    /// presentation-model call; tests inject a fake.
    typealias StageRunner = (_ evidence: String, _ stage: AttacheReviewStage) async throws -> String
    /// Runs the final synthesis turn given the built prompt.
    typealias Synthesizer = (_ prompt: AttachePresentationPrompt) async throws -> String
    /// Polled before and after each stage; true cancels the remaining run.
    typealias CancelCheck = () -> Bool

    func summarize(
        request: HistoricSessionSummaryRequest,
        options: Options,
        cancel: @escaping CancelCheck = { false },
        runStage: StageRunner,
        synthesize: Synthesizer
    ) async throws -> HistoricSessionSummaryOutcome {
        // Invoking the action IS the explicit user selection (INF-315 /
        // INF-370 step 2). This is an app-owned surface (a known Command-K or
        // inbox session row), not a model-driven pick, so it grants focus the
        // same way the watched-session ring or menu already does; it can
        // never grant focus for a session absent from the reconciled index,
        // so a forgotten/unindexed session is structurally unreachable here.
        guard let grant = runtime.grantAppOwnedFocus(
            sessionID: request.sessionID,
            sourceKind: request.sourceKind,
            displayTitle: request.displayTitle,
            workingDirectory: request.workingDirectory
        ) else {
            return .failedClosed(reason: "no matching indexed session for the requested id/source")
        }

        // Fail-closed re-check before any transcript byte is touched: this
        // call performs no I/O (`AttacheHistoricSessionSummaryAuthorizer` is
        // pure), so a caller can prove the failure path never opens a file.
        let authorization = AttacheHistoricSessionSummaryAuthorizer.authorize(
            requestedSessionID: request.sessionID,
            requestedSourceKind: request.sourceKind,
            grant: grant
        )
        let focusedSession: AttacheFocusedSession
        switch authorization {
        case .success(let session): focusedSession = session
        case .failure(let error): return .failedClosed(reason: "\(error)")
        }

        // opencode has no per-session transcript file (INF-362): all sessions
        // share one SQLite database, so it freezes through a dedicated path
        // that queries only this session's rows. Every other source streams
        // JSONL through the existing `freezeReviewSource`.
        let frozen: SessionContextRuntime.FrozenReviewSource
        do {
            frozen = request.sourceKind == SourceKind.opencode.rawValue
                ? try runtime.freezeReviewSourceForOpencode(focusedSession: focusedSession)
                : try runtime.freezeReviewSource(focusedSession: focusedSession)
        } catch {
            return .failedClosed(reason: "\(error)")
        }

        var ledger = AttacheExhaustiveReviewCoordinator.buildLedger(
            from: frozen.sessionMap, sourceVersion: frozen.sourceVersion
        )
        let plan = AttacheExhaustiveReviewCoordinator.buildPlan(
            map: frozen.sessionMap, modelKey: options.modelKey, capability: options.capability,
            strategy: options.strategy, egressClass: options.egressClass
        )

        var stageSummaries: [String] = []
        var callCount = 0
        stageLoop: for stage in plan.stages {
            if cancel() {
                ledger.cancelAllPendingAndProcessing()
                break stageLoop
            }
            for episodeID in stage.episodeIDs {
                guard let index = ledger.entries.firstIndex(where: { $0.episodeID == episodeID }) else { continue }
                AttacheExhaustiveReviewCoordinator.startProcessing(&ledger.entries[index])
            }
            let evidence = frozen.evidence(for: stage.episodeIDs)
            do {
                let summary = try await runStage(evidence, stage)
                callCount += 1
                stageSummaries.append(summary)
                let receiptID = "stage-\(stage.stageNumber)"
                for episodeID in stage.episodeIDs {
                    guard let index = ledger.entries.firstIndex(where: { $0.episodeID == episodeID }) else { continue }
                    AttacheExhaustiveReviewCoordinator.markComplete(&ledger.entries[index], receiptID: receiptID)
                }
            } catch {
                for episodeID in stage.episodeIDs {
                    guard let index = ledger.entries.firstIndex(where: { $0.episodeID == episodeID }) else { continue }
                    AttacheExhaustiveReviewCoordinator.markFailed(&ledger.entries[index], reason: "\(error)")
                }
            }
            if cancel() {
                ledger.cancelAllPendingAndProcessing()
                break stageLoop
            }
        }
        ledger.updateOverallStatus()
        let result = AttacheExhaustiveReviewCoordinator.buildResult(
            ledger: ledger, callCount: callCount, fallbackCount: 0
        )

        // Incompleteness honesty (INF-370 step 6): the notice, when present,
        // rides inside the source text handed to synthesis, so the spoken
        // card can never claim full coverage the ledger doesn't back.
        let sourceText = AttacheSessionSummaryLanguage.assembleSourceText(
            stageSummaries: stageSummaries, status: result.status, coveragePercentage: result.coveragePercentage
        )
        let sourceKindEnum = SourceKind(rawValue: request.sourceKind) ?? .generic
        let prompt = AttachePersonality.sessionSummarySynthesisPrompt(
            sourceText: sourceText,
            sessionTitle: request.displayTitle,
            sourceKindDisplayName: sourceKindEnum.displayName,
            profilePrompt: options.profilePrompt,
            memoryContext: options.memoryContext,
            spokenLanguageName: options.spokenLanguageName
        )
        let rawSpokenText = try await synthesize(prompt)
        let spokenText = AttachePersonality.stripDashes(rawSpokenText)

        guard options.persistCard else {
            return .ephemeral(spokenText: spokenText)
        }

        var metadata: [String: String] = [
            "kind": "session_summary",
            "coverage_status": result.status.rawValue,
            "coverage_percentage": String(format: "%.2f", result.coveragePercentage)
        ]
        let totalEstimatedTokens = plan.stages.reduce(0) { $0 + $1.estimatedTokens }
        let attempt = AttacheReceiptAttemptSummary(
            attemptNumber: 1, isFallback: false,
            modelSummary: AttacheReceiptModelSummary(
                provider: options.provider, model: options.modelKey, reasoningLevel: options.reasoningLevel,
                strategyKind: options.strategy.kind.rawValue, estimatedInputTokens: totalEstimatedTokens,
                effectiveBudget: plan.maxStageInputTokens, outputReserve: nil, toolReserve: nil,
                capabilityProvenance: options.capability.provenance.rawValue, capabilityFreshness: nil
            ),
            sourceSummaries: [
                AttacheReceiptSourceSummary(
                    source: "session_transcript", count: result.coveredRanges.count,
                    disposition: result.status == .complete ? .included : .truncated,
                    omissionReason: result.status == .complete ? nil : "partial coverage: \(result.status.rawValue)"
                )
            ],
            totalEstimatedTokens: totalEstimatedTokens,
            stagedProcessingRequired: plan.stages.count > 1,
            focusedSessionDisplay: AttacheReceiptFocusedSessionDisplay(
                displayTitle: request.displayTitle, sourceKind: request.sourceKind, authorizationTime: Date()
            ),
            recompiledForFallback: false
        )
        // Bound to a placeholder card id here; `CardStore.insertEvent`
        // re-binds it to the real, deterministic card id at insert time
        // (INF-325 contract), so history association is always correct even
        // though the id doesn't exist yet at prompt-build time.
        let receipt = AttacheContextReceiptView(cardID: "pending", attempts: [attempt])
        if let encoded = receipt.encodedMetadataValue() {
            metadata[AttacheContextReceiptView.metadataKey] = encoded
        }

        let event = NormalizedEvent(
            source: request.sourceKind,
            eventType: "session_summary",
            externalSessionID: request.sessionID,
            projectPath: request.workingDirectory,
            title: request.displayTitle,
            text: spokenText,
            metadata: metadata
        )
        let card = try cardStore.insertEvent(event)
        return .card(card)
    }
}
