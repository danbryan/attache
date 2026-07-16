import Foundation

/// The status of one coverage ledger entry (INF-329).
public enum AttacheCoverageEntryStatus: String, Equatable, Sendable {
    case pending
    case processing
    case complete
    case failed
    case skipped
    case stale
    case canceled
}

/// The overall status of an exhaustive review (INF-329). Only complete may say
/// the whole eligible session was reviewed.
public enum AttacheReviewOverallStatus: String, Equatable, Sendable {
    case inProgress
    case complete
    case incomplete
    case canceled
    case stale
}

/// One entry in the coverage ledger (INF-329). One per eligible episode/range
/// with explicit excluded categories. Every eligible turn/range is covered
/// exactly once or deliberately revisited with a recorded reason.
public struct AttacheCoverageLedgerEntry: Equatable, Sendable {
    public let episodeID: String
    public let sessionID: String
    public let sourceKind: String
    public let startTurnOrdinal: Int
    public let endTurnOrdinal: Int
    public let sourceHash: String
    public private(set) var status: AttacheCoverageEntryStatus
    public private(set) var failureReason: String?
    public private(set) var receiptID: String?
    public private(set) var attemptCount: Int
    public let isExcluded: Bool
    public let exclusionReason: String?
    public private(set) var revisitReason: String?

    public init(
        episodeID: String, sessionID: String, sourceKind: String,
        startTurnOrdinal: Int, endTurnOrdinal: Int, sourceHash: String,
        status: AttacheCoverageEntryStatus = .pending,
        failureReason: String? = nil, receiptID: String? = nil,
        attemptCount: Int = 0, isExcluded: Bool = false,
        exclusionReason: String? = nil, revisitReason: String? = nil
    ) {
        self.episodeID = episodeID
        self.sessionID = sessionID
        self.sourceKind = sourceKind
        self.startTurnOrdinal = startTurnOrdinal
        self.endTurnOrdinal = endTurnOrdinal
        self.sourceHash = sourceHash
        self.status = status
        self.failureReason = failureReason
        self.receiptID = receiptID
        self.attemptCount = attemptCount
        self.isExcluded = isExcluded
        self.exclusionReason = exclusionReason
        self.revisitReason = revisitReason
    }

    public mutating func markProcessing() { status = .processing; attemptCount += 1 }
    public mutating func markComplete(receiptID: String) { status = .complete; self.receiptID = receiptID }
    public mutating func markFailed(reason: String) { status = .failed; failureReason = reason }
    public mutating func markSkipped(reason: String) { status = .skipped; failureReason = reason }
    public mutating func markStale() { status = .stale }
    public mutating func markCanceled() { status = .canceled }
    public mutating func markRevisit(reason: String) { revisitReason = reason; status = .pending }

    public var isEligible: Bool { !isExcluded }
    public var isCovered: Bool { status == .complete }
}

/// The coverage ledger (INF-329). One entry per eligible episode/range.
public struct AttacheCoverageLedger: Equatable, Sendable {
    public let sessionID: String
    public let sourceVersion: String
    public var entries: [AttacheCoverageLedgerEntry]
    public var overallStatus: AttacheReviewOverallStatus

    public init(sessionID: String, sourceVersion: String, entries: [AttacheCoverageLedgerEntry]) {
        self.sessionID = sessionID
        self.sourceVersion = sourceVersion
        self.entries = entries
        self.overallStatus = entries.isEmpty ? .complete : .inProgress
    }

    public var eligibleCount: Int { entries.filter { $0.isEligible }.count }
    public var coveredCount: Int { entries.filter { $0.isCovered }.count }
    public var failedCount: Int { entries.filter { $0.status == .failed }.count }
    public var skippedCount: Int { entries.filter { $0.status == .skipped }.count }
    public var excludedCount: Int { entries.filter { $0.isExcluded }.count }

    public var coveragePercentage: Double {
        let eligible = eligibleCount
        guard eligible > 0 else { return 1.0 }
        return Double(coveredCount) / Double(eligible)
    }

    /// Mark all non-complete entries as stale (INF-329).
    public mutating func markAllNonCompleteStale() {
        for i in entries.indices {
            if entries[i].status != .complete {
                entries[i].markStale()
            }
        }
    }

    /// A source-version change invalidates every checkpoint, including entries
    /// previously marked complete. Keeping completed entries across versions
    /// can produce a false exhaustive claim from mixed source snapshots.
    public mutating func markAllStale() {
        for i in entries.indices where entries[i].isEligible {
            entries[i].markStale()
        }
        overallStatus = .stale
    }

    public mutating func invalidateMutatedEntries(currentHashesByEpisode: [String: String]) {
        for i in entries.indices where entries[i].isEligible {
            guard currentHashesByEpisode[entries[i].episodeID] == entries[i].sourceHash else {
                entries[i].markStale()
                continue
            }
        }
        updateOverallStatus()
    }

    /// Cancel all pending and processing entries (INF-329).
    public mutating func cancelAllPendingAndProcessing() {
        for i in entries.indices {
            if entries[i].status == .pending || entries[i].status == .processing {
                entries[i].markCanceled()
            }
        }
    }

    /// Check overall completion (INF-329). No failed, skipped, stale, or
    /// unauthorized range can yield a complete result.
    public mutating func updateOverallStatus() {
        let eligible = entries.filter { $0.isEligible }
        let allCovered = eligible.allSatisfy { $0.isCovered }
        let anyFailed = eligible.contains { $0.status == .failed }
        let anyCanceled = eligible.contains { $0.status == .canceled }
        let anyStale = eligible.contains { $0.status == .stale }
        if anyStale { overallStatus = .stale }
        else if anyCanceled { overallStatus = .canceled }
        else if allCovered && !anyFailed { overallStatus = .complete }
        else { overallStatus = .incomplete }
    }
}

/// One staged review plan (INF-329). Groups episodes by budget.
public struct AttacheReviewStage: Equatable, Sendable {
    public let stageNumber: Int
    public let episodeIDs: [String]
    public let estimatedTokens: Int

    public init(stageNumber: Int, episodeIDs: [String], estimatedTokens: Int) {
        self.stageNumber = stageNumber
        self.episodeIDs = episodeIDs
        self.estimatedTokens = estimatedTokens
    }
}

/// The exhaustive review plan (INF-329).
public struct AttacheExhaustiveReviewPlan: Equatable, Sendable {
    public let sessionID: String
    public let modelKey: String
    public let strategyKind: String
    public let egressClass: String
    public let stages: [AttacheReviewStage]
    public let estimatedCallCount: Int
    public let maxStageInputTokens: Int
    public let oversizedEpisodeIDs: [String]

    public init(
        sessionID: String, modelKey: String, strategyKind: String,
        egressClass: String, stages: [AttacheReviewStage], estimatedCallCount: Int,
        maxStageInputTokens: Int, oversizedEpisodeIDs: [String] = []
    ) {
        self.sessionID = sessionID
        self.modelKey = modelKey
        self.strategyKind = strategyKind
        self.egressClass = egressClass
        self.stages = stages
        self.estimatedCallCount = estimatedCallCount
        self.maxStageInputTokens = maxStageInputTokens
        self.oversizedEpisodeIDs = oversizedEpisodeIDs
    }
}

/// The frozen identity of an in-flight review (INF-329). Prevents concurrent
/// runs from mixing sessions, personalities, models, or source versions.
public struct AttacheReviewFrozenIdentity: Equatable, Sendable {
    public let sessionID: String
    public let epoch: AttacheFocusEpoch
    public let personalityID: String
    public let modelKey: String
    public let sourceVersion: String

    public init(sessionID: String, epoch: AttacheFocusEpoch, personalityID: String, modelKey: String, sourceVersion: String) {
        self.sessionID = sessionID
        self.epoch = epoch
        self.personalityID = personalityID
        self.modelKey = modelKey
        self.sourceVersion = sourceVersion
    }

    /// True when two frozen identities would mix (INF-329).
    public func conflictsWith(_ other: AttacheReviewFrozenIdentity) -> Bool {
        sessionID != other.sessionID || epoch != other.epoch
            || personalityID != other.personalityID || modelKey != other.modelKey
            || sourceVersion != other.sourceVersion
    }
}

/// The exhaustive review result (INF-329). Content-free status with provenance.
public struct AttacheExhaustiveReviewResult: Equatable, Sendable {
    public let status: AttacheReviewOverallStatus
    public let coveragePercentage: Double
    public let coveredRanges: [AttacheCapsuleCitation]
    public let callCount: Int
    public let fallbackCount: Int
    public let omittedRanges: [String]
    public let isContentFree: Bool

    public init(
        status: AttacheReviewOverallStatus, coveragePercentage: Double,
        coveredRanges: [AttacheCapsuleCitation], callCount: Int,
        fallbackCount: Int, omittedRanges: [String]
    ) {
        self.status = status
        self.coveragePercentage = coveragePercentage
        self.coveredRanges = coveredRanges
        self.callCount = callCount
        self.fallbackCount = fallbackCount
        self.omittedRanges = omittedRanges
        self.isContentFree = true
    }
}

/// The pure exhaustive review coordinator (INF-329). Builds a coverage plan
/// from the session map, processes episodes through staged workflow, and
/// proves coverage. Never turns a partial review into a completeness claim.
public enum AttacheExhaustiveReviewCoordinator {

    /// Build a coverage ledger from a session map (INF-329). One entry per
    /// eligible episode/range with explicit excluded categories.
    public static func buildLedger(
        from map: AttacheSessionMap,
        sourceVersion: String
    ) -> AttacheCoverageLedger {
        let entries = map.episodes.map { episode in
            AttacheCoverageLedgerEntry(
                episodeID: episode.episodeID, sessionID: episode.sessionID,
                sourceKind: episode.sourceKind,
                startTurnOrdinal: episode.startTurnOrdinal,
                endTurnOrdinal: episode.endTurnOrdinal,
                sourceHash: episode.combinedHash,
                isExcluded: episode.isExcluded,
                exclusionReason: episode.exclusionReason
            )
        }
        return AttacheCoverageLedger(sessionID: map.sessionID, sourceVersion: sourceVersion, entries: entries)
    }

    /// Build a staged review plan (INF-329). Small models use more bounded
    /// stages; large models may combine more evidence.
    public static func buildPlan(
        map: AttacheSessionMap,
        modelKey: String,
        capability: AttacheModelCapabilityProfile,
        strategy: AttacheContextStrategy,
        egressClass: String,
        /// Conservative provider-bound size for each episode, calculated from
        /// the frozen evidence when available. Callers without the raw source
        /// may omit this and retain the legacy turn-count estimate.
        estimatedTokensByEpisode: [String: Int] = [:]
    ) -> AttacheExhaustiveReviewPlan {
        let eligibleEpisodes = map.episodes.filter { !$0.isExcluded }
        let ceiling = capability.declaredInputCeiling ?? ContextBudgetPlanner.unknownCapacityEnvelope
        let coverageFraction: Double
        switch strategy.kind {
        case .efficient: coverageFraction = 0.35
        case .automatic: coverageFraction = 0.55
        case .maximumCoverage: coverageFraction = 0.80
        case .custom: coverageFraction = 0.65
        }
        let customLimit = strategy.custom?.effectiveInputLimit ?? strategy.custom?.hardInputLimit
        let effectiveCeiling = min(ceiling, customLimit ?? ceiling)
        let budgetPerStage = max(512, Int(Double(effectiveCeiling) * coverageFraction))
        // Group episodes into stages by estimated token cost.
        var stages: [AttacheReviewStage] = []
        var currentEpisodes: [String] = []
        var currentTokens = 0
        var stageNumber = 1
        var oversizedEpisodeIDs: [String] = []
        for episode in eligibleEpisodes {
            let episodeTokens = max(
                1,
                estimatedTokensByEpisode[episode.episodeID] ?? episode.turnCount * 100
            )
            guard episodeTokens <= budgetPerStage else {
                oversizedEpisodeIDs.append(episode.episodeID)
                continue
            }
            if currentTokens + episodeTokens > budgetPerStage && !currentEpisodes.isEmpty {
                stages.append(AttacheReviewStage(stageNumber: stageNumber, episodeIDs: currentEpisodes, estimatedTokens: currentTokens))
                currentEpisodes = []
                currentTokens = 0
                stageNumber += 1
            }
            currentEpisodes.append(episode.episodeID)
            currentTokens += episodeTokens
        }
        if !currentEpisodes.isEmpty {
            stages.append(AttacheReviewStage(stageNumber: stageNumber, episodeIDs: currentEpisodes, estimatedTokens: currentTokens))
        }
        return AttacheExhaustiveReviewPlan(
            sessionID: map.sessionID, modelKey: modelKey,
            strategyKind: strategy.kind.rawValue, egressClass: egressClass,
            stages: stages, estimatedCallCount: stages.count,
            maxStageInputTokens: budgetPerStage,
            oversizedEpisodeIDs: oversizedEpisodeIDs
        )
    }

    /// Mark an episode as processing in the ledger (INF-329).
    public static func startProcessing(
        _ entry: inout AttacheCoverageLedgerEntry
    ) {
        entry.markProcessing()
    }

    /// Mark an episode as complete (INF-329).
    public static func markComplete(
        _ entry: inout AttacheCoverageLedgerEntry,
        receiptID: String
    ) {
        entry.markComplete(receiptID: receiptID)
    }

    /// Mark an episode as failed (INF-329).
    public static func markFailed(
        _ entry: inout AttacheCoverageLedgerEntry,
        reason: String
    ) {
        entry.markFailed(reason: reason)
    }

    /// Cancel the review (INF-329). Stops new provider calls promptly.
    public static func cancel(_ ledger: inout AttacheCoverageLedger) {
        ledger.cancelAllPendingAndProcessing()
        ledger.updateOverallStatus()
    }

    /// Resume from checkpoints (INF-329). Does not repeat completed
    /// effect-free work unnecessarily.
    public static func resume(
        _ ledger: inout AttacheCoverageLedger,
        currentSourceVersion: String
    ) -> Bool {
        // If the source version changed, the checkpoints are stale.
        guard ledger.sourceVersion == currentSourceVersion else {
            ledger.markAllStale()
            return false
        }
        // Pending entries can resume. Completed entries are not repeated.
        return true
    }

    /// Detect source mutation (INF-329). Invalidates affected checkpoints and
    /// prevents mixed-version output.
    public static func detectSourceMutation(
        ledger: AttacheCoverageLedger,
        currentHashes: Set<String>
    ) -> [String] {
        ledger.entries.filter { entry in
            entry.isCovered && !currentHashes.contains(entry.sourceHash)
        }.map { $0.episodeID }
    }

    /// Mutation-safe episode keyed comparison. A set of hashes loses episode
    /// identity and cannot distinguish swaps or duplicate hashes.
    public static func detectSourceMutation(
        ledger: AttacheCoverageLedger,
        currentHashesByEpisode: [String: String]
    ) -> [String] {
        ledger.entries.filter { entry in
            entry.isEligible && currentHashesByEpisode[entry.episodeID] != entry.sourceHash
        }.map { $0.episodeID }
    }

    @discardableResult
    public static func applySourceMutation(
        ledger: inout AttacheCoverageLedger,
        currentHashesByEpisode: [String: String],
        currentSourceVersion: String
    ) -> Bool {
        guard ledger.sourceVersion == currentSourceVersion else {
            ledger.markAllStale()
            return false
        }
        ledger.invalidateMutatedEntries(currentHashesByEpisode: currentHashesByEpisode)
        return ledger.overallStatus != .stale
    }

    /// Check if a frozen identity matches the current state (INF-329). A
    /// focus/personality/model switch does not mutate an in-flight frozen run.
    public static func frozenIdentityMatches(
        frozen: AttacheReviewFrozenIdentity,
        currentSessionID: String,
        currentEpoch: AttacheFocusEpoch,
        currentPersonalityID: String,
        currentModelKey: String,
        currentSourceVersion: String
    ) -> Bool {
        frozen.sessionID == currentSessionID
            && frozen.epoch == currentEpoch
            && frozen.personalityID == currentPersonalityID
            && frozen.modelKey == currentModelKey
            && frozen.sourceVersion == currentSourceVersion
    }

    /// Build the final result from the ledger (INF-329). Content-free. Only
    /// complete may say the whole eligible session was reviewed.
    public static func buildResult(
        ledger: AttacheCoverageLedger,
        callCount: Int,
        fallbackCount: Int
    ) -> AttacheExhaustiveReviewResult {
        var verifiedLedger = ledger
        verifiedLedger.updateOverallStatus()
        var coveredRanges: [AttacheCapsuleCitation] = []
        var omittedRanges: [String] = []
        for entry in verifiedLedger.entries {
            if entry.isCovered {
                coveredRanges.append(AttacheCapsuleCitation(
                    startTurnOrdinal: entry.startTurnOrdinal,
                    endTurnOrdinal: entry.endTurnOrdinal,
                    sourceHash: entry.sourceHash
                ))
            } else if entry.isEligible {
                omittedRanges.append("\(entry.startTurnOrdinal)..\(entry.endTurnOrdinal)")
            }
        }
        return AttacheExhaustiveReviewResult(
            status: verifiedLedger.overallStatus,
            coveragePercentage: verifiedLedger.coveragePercentage,
            coveredRanges: coveredRanges,
            callCount: callCount,
            fallbackCount: fallbackCount,
            omittedRanges: omittedRanges
        )
    }

    /// True when no effectful tool or reverse-send is available in review
    /// stages (INF-329). The review is read-only.
    public static func reviewIsEffectFree(effectTracker: AttacheToolEffectTracker) -> Bool {
        !effectTracker.hasEffectfulCalls
    }
}
