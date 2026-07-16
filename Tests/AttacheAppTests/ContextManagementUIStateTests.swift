import AttacheCore
import XCTest
@testable import AttacheApp

@MainActor
final class ContextManagementUIStateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ContextManagementUIStateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testGlobalStrategyPersistsAllNamedPresets() throws {
        for strategy in [
            AttacheContextStrategy.automatic,
            .maximumCoverage,
            .efficient
        ] {
            defaults.removePersistentDomain(forName: suiteName)
            let state = AttacheContextUIState(defaults: defaults)
            state.setGlobalStrategy(strategy)

            let restored = AttacheContextUIState(defaults: defaults)
            XCTAssertEqual(restored.globalStrategy, strategy)
            XCTAssertNil(restored.strategyMigrationNotice)
        }
    }

    func testInvalidIntermediateCustomValueStaysEditableButDoesNotPersist() throws {
        let state = AttacheContextUIState(defaults: defaults)
        let intermediate = AttacheContextStrategy(
            .custom,
            custom: AttacheContextCustomPolicy(hardInputLimit: 6)
        )

        state.setGlobalStrategy(intermediate)

        XCTAssertEqual(state.globalStrategy, intermediate)
        XCTAssertEqual(
            AttacheContextUIState.persistedGlobalStrategy(defaults: defaults),
            .automatic,
            "An invalid value may remain visible while typing but must not reach request policy."
        )

        let completed = AttacheContextStrategy(
            .custom,
            custom: AttacheContextCustomPolicy(hardInputLimit: 64_000)
        )
        state.setGlobalStrategy(completed)

        XCTAssertEqual(state.globalStrategy, completed)
        XCTAssertEqual(
            AttacheContextUIState.persistedGlobalStrategy(defaults: defaults),
            completed
        )
    }

    func testInvalidLegacyCustomFallsBackVisiblyToAutomatic() throws {
        let invalid = AttacheContextStrategy(
            .custom,
            custom: AttacheContextCustomPolicy(
                hardInputLimit: 1_000,
                effectiveInputLimit: 2_000,
                outputReserve: 800,
                toolReserve: 800,
                safetyMargin: 100
            )
        )
        defaults.set(
            try JSONEncoder().encode(invalid),
            forKey: "attache.context.globalStrategy.v1"
        )

        let state = AttacheContextUIState(defaults: defaults)

        XCTAssertEqual(state.globalStrategy, .automatic)
        XCTAssertNotNil(state.strategyMigrationNotice)
        XCTAssertTrue(state.strategyMigrationNotice?.contains("legacy Custom") == true)
    }

    func testMemoryChoiceIsExplicitOnlyAfterAChoice() {
        let state = AttacheContextUIState(defaults: defaults)
        XCTAssertEqual(state.memoryMode, .off)
        XCTAssertFalse(state.memoryChoiceWasExplicit)

        state.setMemoryMode(.suggest)

        XCTAssertEqual(state.memoryMode, .suggest)
        XCTAssertTrue(state.memoryChoiceWasExplicit)
        let restored = AttacheContextUIState(defaults: defaults)
        XCTAssertEqual(restored.memoryMode, .suggest)
        XCTAssertTrue(restored.memoryChoiceWasExplicit)
    }

    func testSkippingOnboardingForcesOffWithoutPretendingUserChose() {
        let state = AttacheContextUIState(defaults: defaults)
        state.leaveMemoryOffForSkippedOnboarding()

        XCTAssertEqual(state.memoryMode, .off)
        XCTAssertFalse(state.memoryChoiceWasExplicit)
    }

    func testSkippingRerunWelcomePreservesExistingExplicitMemoryChoice() {
        let state = AttacheContextUIState(defaults: defaults)
        state.setMemoryMode(.suggest)

        state.leaveMemoryOffForSkippedOnboarding()

        XCTAssertEqual(state.memoryMode, .suggest)
        XCTAssertTrue(state.memoryChoiceWasExplicit)
        let restored = AttacheContextUIState(defaults: defaults)
        XCTAssertEqual(restored.memoryMode, .suggest)
        XCTAssertTrue(restored.memoryChoiceWasExplicit)
    }

    func testAcceptEditForgetAndUndoUseInjectableMemoryCallbacks() {
        let state = AttacheContextUIState(defaults: defaults)
        let proposal = AttacheMemoryProposal(
            id: "memory.one",
            statement: "Dan prefers concise status updates.",
            type: .preference,
            sourceKind: .modelProposed,
            sourceLocator: "direct-chat:turn-1",
            confidence: .authoritative,
            sensitivity: .low,
            egress: .localOnly
        )
        state.publishMemorySnapshot(
            records: [],
            reviewItems: [AttacheMemoryReviewItem(proposal: proposal, disposition: .queuedForReview)]
        )

        var acceptedStatement: String?
        var editedStatement: String?
        var forgottenID: String?
        var restoredID: String?
        state.onAcceptMemoryProposal = { proposal, statement in
            acceptedStatement = statement
            return AttacheMemoryRecord(
                id: proposal.id,
                statement: statement,
                type: proposal.type,
                scope: proposal.scope,
                sourceKind: .userConfirmed,
                sourceLocator: proposal.sourceLocator,
                confidence: .authoritative,
                sensitivity: proposal.sensitivity,
                egress: proposal.egress
            )
        }
        state.onEditMemory = { record, statement in
            editedStatement = statement
            var replacement = record
            replacement.statement = statement
            return replacement
        }
        state.onForgetMemory = {
            forgottenID = $0.id
            return true
        }
        state.onUndoForgetMemory = {
            restoredID = $0.id
            return true
        }

        state.acceptMemoryProposal(
            id: proposal.id,
            editedStatement: "Dan prefers outcome-first status updates."
        )
        XCTAssertEqual(acceptedStatement, "Dan prefers outcome-first status updates.")
        XCTAssertEqual(state.memoryRecords.map(\.id), [proposal.id])
        XCTAssertTrue(state.memoryReviewItems.isEmpty)

        state.editMemory(id: proposal.id, statement: "Dan prefers short outcome-first updates.")
        XCTAssertEqual(editedStatement, "Dan prefers short outcome-first updates.")
        XCTAssertEqual(state.memoryRecords.first?.statement, "Dan prefers short outcome-first updates.")

        state.forgetMemory(id: proposal.id)
        XCTAssertEqual(forgottenID, proposal.id)
        XCTAssertTrue(state.memoryRecords.isEmpty)

        state.undoLastForget()
        XCTAssertEqual(restoredID, proposal.id)
        XCTAssertEqual(state.memoryRecords.map(\.id), [proposal.id])
    }

    func testRejectedAcceptAndEditLeavePublishedMemoryStateUnchanged() {
        let state = AttacheContextUIState(defaults: defaults)
        let pending = proposal(id: "pending", type: .preference)
        let saved = AttacheMemoryRecord(
            id: "saved",
            statement: "Keep this statement.",
            type: .preference,
            scope: .global,
            sourceKind: .userConfirmed,
            sourceLocator: "direct-chat:turn-1",
            confidence: .authoritative,
            sensitivity: .low,
            egress: .localOnly
        )
        state.publishMemorySnapshot(
            records: [saved],
            reviewItems: [AttacheMemoryReviewItem(
                proposal: pending,
                disposition: .queuedForReview
            )]
        )
        state.onAcceptMemoryProposal = { _, _ in nil }
        state.onEditMemory = { _, _ in nil }

        state.acceptMemoryProposal(id: pending.id, editedStatement: "api_key = do-not-save")
        XCTAssertEqual(state.memoryReviewItems.map(\.proposal.id), [pending.id])
        XCTAssertEqual(state.memoryRecords.map(\.id), [saved.id])
        XCTAssertTrue(state.memoryStatusMessage?.contains("not saved") == true)

        state.editMemory(id: saved.id, statement: "api_key = do-not-save")
        XCTAssertEqual(state.memoryRecords.first?.statement, saved.statement)
        XCTAssertTrue(state.memoryStatusMessage?.contains("not updated") == true)
    }

    func testFailedForgetLeavesMemoryVisibleAndEligibleForRetry() {
        let state = AttacheContextUIState(defaults: defaults)
        let saved = AttacheMemoryRecord(
            id: "saved",
            statement: "Keep this statement.",
            type: .preference
        )
        state.publishMemorySnapshot(records: [saved], reviewItems: [])
        state.onForgetMemory = { _ in false }

        state.forgetMemory(id: saved.id)

        XCTAssertEqual(state.memoryRecords.map(\.id), [saved.id])
        XCTAssertNil(state.recentlyForgottenMemory)
        XCTAssertTrue(state.memoryStatusMessage?.contains("remains available") == true)
    }

    func testDeleteAllKeepsVisibleStateUntilPhysicalErasureSucceeds() {
        let state = AttacheContextUIState(defaults: defaults)
        let saved = AttacheMemoryRecord(
            id: "saved",
            statement: "Keep this visible on failure.",
            type: .userFact
        )
        let pending = proposal(id: "pending", type: .preference)
        state.publishMemorySnapshot(
            records: [saved],
            reviewItems: [AttacheMemoryReviewItem(
                proposal: pending,
                disposition: .queuedForReview
            )]
        )

        state.onDeleteAllMemory = { false }
        state.deleteAllMemory()
        XCTAssertEqual(state.memoryRecords.map(\.id), [saved.id])
        XCTAssertEqual(state.memoryReviewItems.map(\.proposal.id), [pending.id])
        XCTAssertTrue(state.memoryStatusMessage?.contains("could not be fully deleted") == true)

        state.onDeleteAllMemory = { true }
        state.deleteAllMemory()
        XCTAssertTrue(state.memoryRecords.isEmpty)
        XCTAssertTrue(state.memoryReviewItems.isEmpty)
        XCTAssertEqual(state.memoryStatusMessage, "All structured memory was deleted.")
    }

    func testRejectAndNeverRememberTypeAreDistinctActions() {
        let state = AttacheContextUIState(defaults: defaults)
        let first = proposal(id: "first", type: .reminder)
        let second = proposal(id: "second", type: .reminder)
        let other = proposal(id: "other", type: .preference)
        state.publishMemorySnapshot(
            records: [],
            reviewItems: [first, second, other].map {
                AttacheMemoryReviewItem(proposal: $0, disposition: .queuedForReview)
            }
        )

        var neverType: AttacheMemoryType?
        state.onNeverRememberMemoryType = { neverType = $0 }
        state.rejectMemoryProposal(id: first.id, neverRememberType: true)

        XCTAssertEqual(neverType, .reminder)
        XCTAssertEqual(state.memoryReviewItems.map(\.proposal.id), [other.id])
    }

    func testReceiptLookupIsTiedToExactResponseID() {
        let state = AttacheContextUIState(defaults: defaults)
        let receipt = AttacheContextReceiptBuilder.buildNoModel(cardID: "card.original")

        state.publishReceipt(receipt, responseID: "turn.reply")

        XCTAssertEqual(state.receipt(for: "turn.reply"), receipt)
        XCTAssertNil(state.receipt(for: "card.original"))
        state.removeReceipt(for: "turn.reply")
        XCTAssertNil(state.receipt(for: "turn.reply"))
    }

    func testOverflowRetryRequiresExplicitSupportedStrategyAndPreservesDraft() {
        let state = AttacheContextUIState(defaults: defaults)
        let recovery = AttacheOverflowRecovery(
            preservedDraft: "Please review the whole session.",
            suggestedStrategies: [.automatic, .efficient]
        )
        var retried: (AttacheContextStrategyKind, String)?
        state.presentOverflowRecovery(recovery) { retried = ($0, $1) }

        state.retryOverflow(using: .maximumCoverage)
        XCTAssertNil(retried)
        XCTAssertNotNil(state.overflowRecovery)

        state.retryOverflow(using: .efficient)
        XCTAssertEqual(retried?.0, .efficient)
        XCTAssertEqual(retried?.1, recovery.preservedDraft)
        XCTAssertNil(state.overflowRecovery)
    }

    func testExhaustiveReviewPreviewProgressCancelAndResume() {
        let state = AttacheContextUIState(defaults: defaults)
        let preview = AttacheExhaustiveReviewUIState(
            id: "review.one",
            sessionTitle: "Long migration",
            modelLabel: "Ollama · qwen",
            strategyLabel: "Maximum coverage",
            egressLabel: "Local",
            estimatedCalls: 8,
            estimatedSourceBytes: 48_000,
            estimatedInputTokens: 12_000,
            eligibleRanges: 12
        )
        var startCount = 0
        var cancelCount = 0
        var resumeCount = 0
        var resumedFrom: AttacheExhaustiveReviewUIState.Phase?
        state.onStartExhaustiveReview = { _ in startCount += 1 }
        state.onCancelExhaustiveReview = { _ in cancelCount += 1 }
        state.onResumeExhaustiveReview = {
            resumeCount += 1
            resumedFrom = $0.phase
        }

        state.presentExhaustiveReview(preview)
        state.startExhaustiveReview()
        XCTAssertEqual(state.exhaustiveReview?.phase, .running)
        XCTAssertEqual(startCount, 1)
        state.startExhaustiveReview()
        XCTAssertEqual(startCount, 1, "Start is idempotent once a review is running.")

        state.updateExhaustiveReview(
            phase: .running,
            coveredRanges: 5,
            eligibleRanges: 12,
            completedCalls: 3
        )
        XCTAssertEqual(state.exhaustiveReview?.coveredRanges, 5)
        XCTAssertEqual(state.exhaustiveReview?.progress ?? 0, 5.0 / 12.0, accuracy: 0.0001)

        state.cancelExhaustiveReview()
        XCTAssertEqual(state.exhaustiveReview?.phase, .canceled)
        XCTAssertEqual(cancelCount, 1)
        state.cancelExhaustiveReview()
        XCTAssertEqual(cancelCount, 1, "Cancel is idempotent once canceled.")
        state.resumeExhaustiveReview()
        XCTAssertEqual(state.exhaustiveReview?.phase, .running)
        XCTAssertEqual(resumeCount, 1)
        XCTAssertEqual(resumedFrom, .canceled)
        state.resumeExhaustiveReview()
        XCTAssertEqual(resumeCount, 1, "Resume is idempotent once running.")

        let replacement = AttacheExhaustiveReviewUIState(
            id: "review.two",
            sessionTitle: "Replacement",
            modelLabel: "Local",
            strategyLabel: "Automatic",
            egressLabel: "On-device",
            estimatedCalls: 1,
            eligibleRanges: 1
        )
        state.presentExhaustiveReview(replacement)
        state.updateExhaustiveReview(
            id: "review.one",
            phase: .complete,
            coveredRanges: 12,
            eligibleRanges: 12,
            completedCalls: 8
        )
        XCTAssertEqual(state.exhaustiveReview, replacement, "A late prior run cannot overwrite a newer preview.")
    }

    private func proposal(id: String, type: AttacheMemoryType) -> AttacheMemoryProposal {
        AttacheMemoryProposal(
            id: id,
            statement: "A durable detail named \(id).",
            type: type,
            confidence: .authoritative,
            sensitivity: .low
        )
    }
}
