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

        state.setMemoryMode(.on)

        XCTAssertEqual(state.memoryMode, .on)
        XCTAssertTrue(state.memoryChoiceWasExplicit)
        let restored = AttacheContextUIState(defaults: defaults)
        XCTAssertEqual(restored.memoryMode, .on)
        XCTAssertTrue(restored.memoryChoiceWasExplicit)
    }

    /// The retired Suggest and Automatic persisted values both allowed capture,
    /// so a state restored from them lands On; unknown values fail closed Off.
    func testLegacyPersistedMemoryModeValuesMapOntoOnOff() {
        for (raw, expected) in [
            ("suggest", AttacheMemoryProposalMode.on),
            ("automatic", .on),
            ("on", .on),
            ("off", .off),
            ("garbage", .off)
        ] {
            defaults.set(raw, forKey: "attache.memory.proposalMode.v1")
            let restored = AttacheContextUIState(defaults: defaults)
            XCTAssertEqual(restored.memoryMode, expected, "raw value \(raw)")
            XCTAssertEqual(
                AttacheContextUIState.persistedMemoryMode(defaults: defaults),
                expected,
                "persisted lookup for raw value \(raw)"
            )
        }
    }

    func testSkippingOnboardingForcesOffWithoutPretendingUserChose() {
        let state = AttacheContextUIState(defaults: defaults)
        state.leaveMemoryOffForSkippedOnboarding()

        XCTAssertEqual(state.memoryMode, .off)
        XCTAssertFalse(state.memoryChoiceWasExplicit)
    }

    func testSkippingRerunWelcomePreservesExistingExplicitMemoryChoice() {
        let state = AttacheContextUIState(defaults: defaults)
        state.setMemoryMode(.on)

        state.leaveMemoryOffForSkippedOnboarding()

        XCTAssertEqual(state.memoryMode, .on)
        XCTAssertTrue(state.memoryChoiceWasExplicit)
        let restored = AttacheContextUIState(defaults: defaults)
        XCTAssertEqual(restored.memoryMode, .on)
        XCTAssertTrue(restored.memoryChoiceWasExplicit)
    }

    func testEditForgetAndUndoUseInjectableMemoryCallbacks() {
        let state = AttacheContextUIState(defaults: defaults)
        let saved = AttacheMemoryRecord(
            id: "memory.one",
            statement: "Dan prefers outcome-first status updates.",
            type: .preference,
            scope: .global,
            sourceKind: .userAuthored,
            sourceLocator: "direct-chat:turn-1",
            confidence: .authoritative,
            sensitivity: .low,
            egress: .localOnly
        )
        state.publishMemorySnapshot(records: [saved])

        var editedStatement: String?
        var forgottenID: String?
        var restoredID: String?
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

        state.editMemory(id: saved.id, statement: "Dan prefers short outcome-first updates.")
        XCTAssertEqual(editedStatement, "Dan prefers short outcome-first updates.")
        XCTAssertEqual(state.memoryRecords.first?.statement, "Dan prefers short outcome-first updates.")

        state.forgetMemory(id: saved.id)
        XCTAssertEqual(forgottenID, saved.id)
        XCTAssertTrue(state.memoryRecords.isEmpty)

        state.undoLastForget()
        XCTAssertEqual(restoredID, saved.id)
        XCTAssertEqual(state.memoryRecords.map(\.id), [saved.id])
    }

    func testRejectedEditLeavesPublishedMemoryStateUnchanged() {
        let state = AttacheContextUIState(defaults: defaults)
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
        state.publishMemorySnapshot(records: [saved])
        state.onEditMemory = { _, _ in nil }

        state.editMemory(id: saved.id, statement: "api_key = do-not-save")
        XCTAssertEqual(state.memoryRecords.first?.statement, saved.statement)
        XCTAssertTrue(state.memoryStatusMessage?.contains("not updated") == true)
    }

    /// The "Applies to all Attachés" authoring path: trims and forwards the
    /// statement through the injectable callback, publishes the accepted
    /// record, and surfaces a rejection without inventing a phantom row.
    func testAddGlobalMemoryUsesInjectableCallbackAndSurfacesRejection() {
        let state = AttacheContextUIState(defaults: defaults)

        state.addGlobalMemory(statement: "   ")
        XCTAssertTrue(state.memoryStatusMessage?.contains("needs some text") == true)

        var authored: String?
        state.onAddGlobalMemory = { statement in
            authored = statement
            return AttacheMemoryRecord(
                id: "memory.global-one",
                statement: statement,
                type: .userFact,
                scope: .global,
                sourceKind: .userConfirmed,
                confidence: .authoritative,
                sensitivity: .low,
                egress: .allowedRemote
            )
        }
        state.addGlobalMemory(statement: "  I always prefer metric units.  ")
        XCTAssertEqual(authored, "I always prefer metric units.")
        XCTAssertEqual(state.memoryRecords.map(\.id), ["memory.global-one"])
        XCTAssertEqual(state.memoryStatusMessage, "Memory saved for all Attachés.")

        state.onAddGlobalMemory = { _ in nil }
        state.addGlobalMemory(statement: "another statement the policy rejects")
        XCTAssertEqual(state.memoryRecords.map(\.id), ["memory.global-one"])
        XCTAssertTrue(state.memoryStatusMessage?.contains("not saved") == true)
    }

    func testFailedForgetLeavesMemoryVisibleAndEligibleForRetry() {
        let state = AttacheContextUIState(defaults: defaults)
        let saved = AttacheMemoryRecord(
            id: "saved",
            statement: "Keep this statement.",
            type: .preference
        )
        state.publishMemorySnapshot(records: [saved])
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
        state.publishMemorySnapshot(records: [saved])

        state.onDeleteAllMemory = { false }
        state.deleteAllMemory()
        XCTAssertEqual(state.memoryRecords.map(\.id), [saved.id])
        XCTAssertTrue(state.memoryStatusMessage?.contains("could not be fully deleted") == true)

        state.onDeleteAllMemory = { true }
        state.deleteAllMemory()
        XCTAssertTrue(state.memoryRecords.isEmpty)
        XCTAssertEqual(state.memoryStatusMessage, "All structured memory was deleted.")
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

}
