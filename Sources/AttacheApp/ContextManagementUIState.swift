import AttacheCore
import Combine
import Foundation

/// App-facing state for context-management controls and disclosures.
///
/// The model pipeline owns the actual compiler, memory ledger, and exhaustive
/// review coordinator. This object is the narrow UI seam those services publish
/// into. Keeping the seam injectable lets Settings and packaged UI smoke exercise
/// the real controls without making the views reach into SQLite or provider code.
@MainActor
final class AttacheContextUIState: ObservableObject {
    static let shared = AttacheContextUIState()

    private enum Key {
        static let globalStrategy = "attache.context.globalStrategy.v1"
        static let memoryMode = "attache.memory.proposalMode.v1"
        static let memoryChoiceExplicit = "attache.memory.proposalModeExplicit.v1"
    }

    private let defaults: UserDefaults

    @Published private(set) var globalStrategy: AttacheContextStrategy
    @Published private(set) var strategyMigrationNotice: String?
    @Published private(set) var memoryMode: AttacheMemoryProposalMode
    @Published private(set) var memoryChoiceWasExplicit: Bool
    @Published private(set) var memoryRecords: [AttacheMemoryRecord] = []
    @Published private(set) var recentlyForgottenMemory: AttacheMemoryRecord?
    @Published private(set) var memoryStatusMessage: String?
    @Published private(set) var receiptsByResponseID: [String: AttacheContextReceiptView] = [:]
    @Published private(set) var overflowRecovery: AttacheOverflowRecovery?
    @Published private(set) var exhaustiveReview: AttacheExhaustiveReviewUIState?

    var onMemoryModeChange: ((AttacheMemoryProposalMode) -> Void)?
    /// Settings-authored all-Attachés memory. Returns nil when the validator,
    /// duplicate check, or storage rejected the statement.
    var onAddGlobalMemory: ((String) -> AttacheMemoryRecord?)?
    var onEditMemory: ((AttacheMemoryRecord, String) -> AttacheMemoryRecord?)?
    var onSetMemoryEgress: ((AttacheMemoryRecord, AttacheMemoryEgress) -> AttacheMemoryRecord?)?
    /// Returns true only after the active row was marked forgotten in storage.
    /// The UI must not hide a record that remains eligible for retrieval.
    var onForgetMemory: ((AttacheMemoryRecord) -> Bool)?
    /// Returns true only after the forgotten row was restored in the ledger.
    /// The UI must not resurrect a record when persistence rejects the undo.
    var onUndoForgetMemory: ((AttacheMemoryRecord) -> Bool)?
    /// Returns true only after the ledger and every legacy artifact verified
    /// physical erasure. Failure leaves the published snapshot untouched.
    var onDeleteAllMemory: (() -> Bool)?
    var onOverflowRetry: ((AttacheContextStrategyKind, String) -> Void)?
    var onStartExhaustiveReview: ((AttacheExhaustiveReviewUIState) -> Void)?
    var onCancelExhaustiveReview: ((AttacheExhaustiveReviewUIState) -> Void)?
    var onResumeExhaustiveReview: ((AttacheExhaustiveReviewUIState) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let decoded = defaults.data(forKey: Key.globalStrategy)
            .flatMap { try? JSONDecoder().decode(AttacheContextStrategy.self, from: $0) }
        let validated = Self.validatePersistedStrategy(decoded)
        globalStrategy = validated.strategy
        strategyMigrationNotice = validated.notice

        memoryMode = AttacheMemoryProposalMode.fromPersisted(
            defaults.string(forKey: Key.memoryMode)
        )
        memoryChoiceWasExplicit = defaults.bool(forKey: Key.memoryChoiceExplicit)
    }

    nonisolated static func persistedGlobalStrategy(
        defaults: UserDefaults = .standard
    ) -> AttacheContextStrategy {
        let decoded = defaults.data(forKey: Key.globalStrategy)
            .flatMap { try? JSONDecoder().decode(AttacheContextStrategy.self, from: $0) }
        return validatePersistedStrategy(decoded).strategy
    }

    nonisolated static func persistedMemoryMode(
        defaults: UserDefaults = .standard
    ) -> AttacheMemoryProposalMode {
        AttacheMemoryProposalMode.fromPersisted(defaults.string(forKey: Key.memoryMode))
    }

    nonisolated static func validatePersistedStrategy(
        _ candidate: AttacheContextStrategy?
    ) -> (strategy: AttacheContextStrategy, notice: String?) {
        guard let candidate else { return (.automatic, nil) }
        guard candidate.kind == .custom else { return (candidate, nil) }
        guard let custom = candidate.custom else {
            return (
                .automatic,
                "A legacy Custom context profile was incomplete, so Attaché restored Automatic. Review the advanced limits before saving a new override."
            )
        }
        do {
            try custom.validate()
            return (candidate, nil)
        } catch {
            return (
                .automatic,
                "A legacy Custom context profile had unsafe limits, so Attaché restored Automatic. Review the advanced limits before saving a new override."
            )
        }
    }

    func setGlobalStrategy(_ strategy: AttacheContextStrategy) {
        // Keep an in-progress Custom value in view state so normal intermediate
        // input such as the first digit of "64000" does not collapse the editor
        // back to Automatic. Only complete, valid policies cross the persistence
        // boundary and become eligible for request compilation.
        globalStrategy = strategy
        strategyMigrationNotice = nil
        if strategy.kind == .custom {
            guard let custom = strategy.custom, (try? custom.validate()) != nil else {
                return
            }
        }
        if let data = try? JSONEncoder().encode(globalStrategy) {
            defaults.set(data, forKey: Key.globalStrategy)
        }
    }

    func dismissStrategyMigrationNotice() {
        strategyMigrationNotice = nil
    }

    func setMemoryMode(_ mode: AttacheMemoryProposalMode, explicit: Bool = true) {
        memoryMode = mode
        if explicit {
            memoryChoiceWasExplicit = true
            defaults.set(true, forKey: Key.memoryChoiceExplicit)
        }
        defaults.set(mode.rawValue, forKey: Key.memoryMode)
        onMemoryModeChange?(mode)
    }

    /// Skipping onboarding must never opt a user into capture.
    func leaveMemoryOffForSkippedOnboarding() {
        // Welcome can be reopened after setup. In that case Skip means "leave
        // my existing choice alone," not "turn memory off." A genuinely fresh
        // user has no explicit choice, so Skip still leaves the safe Off default.
        guard !memoryChoiceWasExplicit else { return }
        memoryMode = .off
        defaults.set(AttacheMemoryProposalMode.off.rawValue, forKey: Key.memoryMode)
        onMemoryModeChange?(.off)
    }

    func publishMemorySnapshot(
        records: [AttacheMemoryRecord],
        status: String? = nil
    ) {
        memoryRecords = records
        memoryStatusMessage = status
    }

    /// Adds a Settings-authored memory that every Attaché can use. The bound
    /// runtime republishes the full snapshot on success, so this only surfaces
    /// the outcome message on rejection.
    func addGlobalMemory(statement: String) {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            memoryStatusMessage = "A memory needs some text before it can be saved."
            return
        }
        guard let record = onAddGlobalMemory?(trimmed) else {
            memoryStatusMessage = "Memory was not saved because local policy rejected it or storage was unavailable."
            return
        }
        memoryRecords.removeAll { $0.id == record.id }
        memoryRecords.insert(record, at: 0)
        memoryStatusMessage = "Memory saved for all Attachés."
    }

    func editMemory(id: String, statement: String) {
        guard let index = memoryRecords.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            memoryStatusMessage = "A memory cannot be empty."
            return
        }
        let original = memoryRecords[index]
        guard let replacement = onEditMemory?(original, trimmed) else {
            memoryStatusMessage = "Memory was not updated because local policy rejected the edit or storage was unavailable."
            return
        }
        // The ledger creates a replacement record and supersedes the original.
        // Use its returned identity instead of an index captured before the
        // callback, because publishing the updated ledger may reorder the list.
        memoryRecords.removeAll { $0.id == original.id || $0.id == replacement.id }
        memoryRecords.insert(replacement, at: 0)
        memoryStatusMessage = "Memory updated."
    }

    /// Change whether one saved memory may enter a remote-bound request. The
    /// native user action is the authority; a model proposal cannot call this.
    func setMemoryEgress(id: String, egress: AttacheMemoryEgress) {
        guard let original = memoryRecords.first(where: { $0.id == id }),
              original.egress != egress else { return }
        guard let replacement = onSetMemoryEgress?(original, egress) else {
            memoryStatusMessage = "Memory privacy could not be updated. The prior setting remains active."
            return
        }
        memoryRecords.removeAll { $0.id == original.id || $0.id == replacement.id }
        memoryRecords.insert(replacement, at: 0)
        memoryStatusMessage = egress == .localOnly
            ? "Memory is now local only."
            : "Memory may now be sent to the active model when relevant."
    }

    func forgetMemory(id: String) {
        guard let record = memoryRecords.first(where: { $0.id == id }) else { return }
        guard onForgetMemory?(record) == true else {
            memoryStatusMessage = "Memory could not be forgotten. It remains available."
            return
        }
        // The persistence callback may publish a freshly ordered snapshot.
        // Remove by identity rather than an index captured before that callback.
        memoryRecords.removeAll { $0.id == record.id }
        recentlyForgottenMemory = record
        memoryStatusMessage = "Memory forgotten. It will not be used again."
    }

    func undoLastForget() {
        guard let record = recentlyForgottenMemory else { return }
        guard onUndoForgetMemory?(record) == true else {
            memoryStatusMessage = "Memory could not be restored. It remains forgotten."
            return
        }
        recentlyForgottenMemory = nil
        memoryRecords.removeAll { $0.id == record.id }
        memoryRecords.insert(record, at: 0)
        memoryStatusMessage = "Memory restored."
    }

    func deleteAllMemory() {
        guard onDeleteAllMemory?() == true else {
            memoryStatusMessage = "Structured memory could not be fully deleted. Nothing was hidden from this list; fix the storage problem and try again."
            return
        }
        memoryRecords = []
        recentlyForgottenMemory = nil
        memoryStatusMessage = "All structured memory was deleted."
    }

    func publishReceipt(_ receipt: AttacheContextReceiptView, responseID: String? = nil) {
        receiptsByResponseID[responseID ?? receipt.cardID] = receipt
    }

    func receipt(for responseID: String) -> AttacheContextReceiptView? {
        receiptsByResponseID[responseID]
    }

    func removeReceipt(for responseID: String) {
        receiptsByResponseID.removeValue(forKey: responseID)
    }

    func presentOverflowRecovery(
        _ recovery: AttacheOverflowRecovery,
        retry: ((AttacheContextStrategyKind, String) -> Void)? = nil
    ) {
        overflowRecovery = recovery
        onOverflowRetry = retry
    }

    func retryOverflow(using strategy: AttacheContextStrategyKind) {
        guard let recovery = overflowRecovery,
              recovery.suggestedStrategies.contains(strategy) else { return }
        onOverflowRetry?(strategy, recovery.preservedDraft)
        overflowRecovery = nil
    }

    func dismissOverflowRecovery() {
        overflowRecovery = nil
    }

    func presentExhaustiveReview(_ state: AttacheExhaustiveReviewUIState) {
        exhaustiveReview = state
    }

    func updateExhaustiveReview(
        id: String? = nil,
        phase: AttacheExhaustiveReviewUIState.Phase,
        coveredRanges: Int,
        eligibleRanges: Int,
        completedCalls: Int,
        omittedRanges: Int = 0
    ) {
        guard var review = exhaustiveReview else { return }
        if let id, review.id != id { return }
        review.phase = phase
        review.coveredRanges = coveredRanges
        review.eligibleRanges = eligibleRanges
        review.completedCalls = completedCalls
        review.omittedRanges = omittedRanges
        exhaustiveReview = review
    }

    func startExhaustiveReview() {
        guard var review = exhaustiveReview,
              review.phase == .preview else { return }
        review.phase = .running
        exhaustiveReview = review
        onStartExhaustiveReview?(review)
    }

    func cancelExhaustiveReview() {
        guard var review = exhaustiveReview,
              review.phase == .running else { return }
        review.phase = .canceled
        exhaustiveReview = review
        onCancelExhaustiveReview?(review)
    }

    func resumeExhaustiveReview() {
        guard var review = exhaustiveReview,
              review.phase == .canceled
                || review.phase == .incomplete
                || review.phase == .stale else { return }
        let requestedReview = review
        review.phase = .running
        exhaustiveReview = review
        // The callback needs the prior phase to distinguish a same-source
        // checkpoint resume from a stale-source restart that must be re-frozen.
        onResumeExhaustiveReview?(requestedReview)
    }

    func dismissExhaustiveReview(id: String? = nil) {
        if let id, exhaustiveReview?.id != id { return }
        exhaustiveReview = nil
    }
}

struct AttacheExhaustiveReviewUIState: Equatable, Identifiable {
    enum Phase: String, Equatable {
        case preview
        case running
        case complete
        case incomplete
        case canceled
        case stale
    }

    let id: String
    let sessionTitle: String
    let modelLabel: String
    let strategyLabel: String
    let egressLabel: String
    let estimatedCalls: Int
    let estimatedSourceBytes: Int
    let estimatedInputTokens: Int
    var phase: Phase
    var coveredRanges: Int
    var eligibleRanges: Int
    var completedCalls: Int
    var omittedRanges: Int

    init(
        id: String,
        sessionTitle: String,
        modelLabel: String,
        strategyLabel: String,
        egressLabel: String,
        estimatedCalls: Int,
        estimatedSourceBytes: Int = 0,
        estimatedInputTokens: Int = 0,
        phase: Phase = .preview,
        coveredRanges: Int = 0,
        eligibleRanges: Int,
        completedCalls: Int = 0,
        omittedRanges: Int = 0
    ) {
        self.id = id
        self.sessionTitle = sessionTitle
        self.modelLabel = modelLabel
        self.strategyLabel = strategyLabel
        self.egressLabel = egressLabel
        self.estimatedCalls = estimatedCalls
        self.estimatedSourceBytes = max(0, estimatedSourceBytes)
        self.estimatedInputTokens = max(0, estimatedInputTokens)
        self.phase = phase
        self.coveredRanges = coveredRanges
        self.eligibleRanges = eligibleRanges
        self.completedCalls = completedCalls
        self.omittedRanges = omittedRanges
    }

    var progress: Double {
        guard eligibleRanges > 0 else { return phase == .complete ? 1 : 0 }
        return min(1, max(0, Double(coveredRanges) / Double(eligibleRanges)))
    }
}
