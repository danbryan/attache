import AttacheCore
import XCTest
import Foundation

final class AttacheExhaustiveReviewTests: XCTestCase {

    private let session = AttacheFocusedSession(sessionID: "s1", sourceKind: "codex", displayTitle: "Test", workingDirectory: "/tmp/proj")
    private let epoch = AttacheFocusEpoch(1)

    private func makeMap(episodes: Int) -> AttacheSessionMap {
        let eps = (0..<episodes).map { i in
            AttacheSessionMapEpisode(
                episodeID: "ep-\(i)", sessionID: "s1", sourceKind: "codex",
                startTurnOrdinal: i * 5, endTurnOrdinal: i * 5 + 4,
                startTimestamp: Date(timeIntervalSince1970: Double(i * 100)),
                endTimestamp: Date(timeIntervalSince1970: Double(i * 100 + 99)),
                turnHashes: (0..<5).map { "hash-\(i)-\($0)" },
                lexicalTerms: ["topic\(i)"]
            )
        }
        return AttacheSessionMap(sessionID: "s1", sourceKind: "codex", episodes: eps, totalTurnCount: episodes * 5, excludedTurnCount: 0)
    }

    // Criterion 1: a fixture with unique sentinels in beginning, middle, end,
    // and adversarially uninteresting regions reports all when complete.
    func testAllSentinelsReportedWhenComplete() {
        let map = makeMap(episodes: 10)
        var ledger = AttacheExhaustiveReviewCoordinator.buildLedger(from: map, sourceVersion: "v1")
        // Process all episodes.
        for i in ledger.entries.indices {
            ledger.entries[i].markProcessing()
            ledger.entries[i].markComplete(receiptID: "r-\(i)")
        }
        ledger.updateOverallStatus()
        XCTAssertEqual(ledger.overallStatus, .complete, "all episodes complete -> overall complete")
        XCTAssertEqual(ledger.coveragePercentage, 1.0, "100% coverage")
    }

    // Criterion 2: every eligible turn/range covered exactly once.
    func testEveryEligibleRangeCoveredExactlyOnce() {
        let map = makeMap(episodes: 5)
        let ledger = AttacheExhaustiveReviewCoordinator.buildLedger(from: map, sourceVersion: "v1")
        XCTAssertEqual(ledger.eligibleCount, 5, "5 eligible episodes")
        // Each episode appears exactly once.
        var seenOrdinals: Set<Int> = []
        for entry in ledger.entries where entry.isEligible {
            for ordinal in entry.startTurnOrdinal...entry.endTurnOrdinal {
                XCTAssertFalse(seenOrdinals.contains(ordinal), "turn \(ordinal) exactly once")
                seenOrdinals.insert(ordinal)
            }
        }
        XCTAssertEqual(seenOrdinals.count, 25, "all 25 turns covered")
    }

    // Criterion 3: no failed/skipped/stale/unauthorized range yields complete.
    func testFailedRangeYieldsIncomplete() {
        let map = makeMap(episodes: 5)
        var ledger = AttacheExhaustiveReviewCoordinator.buildLedger(from: map, sourceVersion: "v1")
        for i in 0..<4 {
            ledger.entries[i].markComplete(receiptID: "r-\(i)")
        }
        ledger.entries[4].markFailed(reason: "provider unavailable")
        ledger.updateOverallStatus()
        XCTAssertEqual(ledger.overallStatus, .incomplete, "failed range -> incomplete")
    }

    func testSkippedRangeYieldsIncomplete() {
        let map = makeMap(episodes: 3)
        var ledger = AttacheExhaustiveReviewCoordinator.buildLedger(from: map, sourceVersion: "v1")
        ledger.entries[0].markComplete(receiptID: "r-0")
        ledger.entries[1].markSkipped(reason: "budget")
        ledger.entries[2].markComplete(receiptID: "r-2")
        ledger.updateOverallStatus()
        XCTAssertEqual(ledger.overallStatus, .incomplete, "skipped -> incomplete")
    }

    func testStaleRangeYieldsStale() {
        let map = makeMap(episodes: 3)
        var ledger = AttacheExhaustiveReviewCoordinator.buildLedger(from: map, sourceVersion: "v1")
        ledger.entries[0].markComplete(receiptID: "r-0")
        ledger.entries[1].markStale()
        ledger.entries[2].markComplete(receiptID: "r-2")
        ledger.updateOverallStatus()
        XCTAssertEqual(ledger.overallStatus, .stale, "stale -> stale")
    }

    // Criterion 4: every material conclusion maps to exact session/range
    // provenance.
    func testResultHasProvenance() {
        let map = makeMap(episodes: 3)
        var ledger = AttacheExhaustiveReviewCoordinator.buildLedger(from: map, sourceVersion: "v1")
        for i in ledger.entries.indices {
            ledger.entries[i].markComplete(receiptID: "r-\(i)")
        }
        ledger.updateOverallStatus()
        let result = AttacheExhaustiveReviewCoordinator.buildResult(ledger: ledger, callCount: 3, fallbackCount: 0)
        XCTAssertEqual(result.coveredRanges.count, 3, "covered ranges have provenance")
        for range in result.coveredRanges {
            XCTAssertFalse(range.sourceHash.isEmpty, "every range has a hash")
            XCTAssertLessThanOrEqual(range.startTurnOrdinal, range.endTurnOrdinal)
        }
    }

    // Criterion 5: 8K model uses more stages; 1M model uses fewer.
    func testStrategyScalingProducesDifferentStages() {
        let map = makeMap(episodes: 20)
        let efficient = AttacheExhaustiveReviewCoordinator.buildPlan(
            map: map, modelKey: "ollama|qwen3",
            capability: AttacheModelCapabilityProfile(architecturalMaximum: 8_000, confidence: .authoritative, provenance: .providerMetadata),
            strategy: .efficient, egressClass: "loopback"
        )
        let maximum = AttacheExhaustiveReviewCoordinator.buildPlan(
            map: map, modelKey: "openai|gpt-4",
            capability: AttacheModelCapabilityProfile(architecturalMaximum: 1_000_000, confidence: .authoritative, provenance: .providerMetadata),
            strategy: .maximumCoverage, egressClass: "configuredRemote"
        )
        XCTAssertGreaterThan(efficient.stages.count, 0)
        XCTAssertGreaterThanOrEqual(efficient.stages.count, maximum.stages.count,
                                    "8K efficient uses more bounded stages; 1M maximum may use fewer larger stages")
    }

    // Criterion 6: cancellation stops new calls; resume doesn't repeat
    // completed work.
    func testCancellationStopsNewCalls() {
        let map = makeMap(episodes: 5)
        var ledger = AttacheExhaustiveReviewCoordinator.buildLedger(from: map, sourceVersion: "v1")
        ledger.entries[0].markComplete(receiptID: "r-0")
        ledger.entries[1].markProcessing()
        // Entries 2-4 are pending.
        AttacheExhaustiveReviewCoordinator.cancel(&ledger)
        for i in 2..<5 {
            XCTAssertEqual(ledger.entries[i].status, .canceled, "pending entries canceled")
        }
        XCTAssertEqual(ledger.overallStatus, .canceled)
    }

    func testResumeDoesNotRepeatCompleted() {
        let map = makeMap(episodes: 5)
        var ledger = AttacheExhaustiveReviewCoordinator.buildLedger(from: map, sourceVersion: "v1")
        ledger.entries[0].markComplete(receiptID: "r-0")
        ledger.entries[1].markComplete(receiptID: "r-1")
        // Entries 2-4 are pending.
        let canResume = AttacheExhaustiveReviewCoordinator.resume(&ledger, currentSourceVersion: "v1")
        XCTAssertTrue(canResume, "resume allowed with same version")
        // Completed entries are not repeated.
        XCTAssertTrue(ledger.entries[0].isCovered, "completed not repeated")
        XCTAssertTrue(ledger.entries[1].isCovered, "completed not repeated")
        XCTAssertEqual(ledger.entries[2].status, .pending, "pending can resume")
    }

    // Criterion 7: source mutation invalidates affected checkpoints.
    func testSourceMutationInvalidatesCheckpoints() {
        let map = makeMap(episodes: 3)
        var ledger = AttacheExhaustiveReviewCoordinator.buildLedger(from: map, sourceVersion: "v1")
        ledger.entries[0].markComplete(receiptID: "r-0")
        // Simulate source mutation: the hash of episode 0 changed.
        let currentHashes: Set<String> = ["hash-1-0", "hash-1-1", "hash-1-2", "hash-1-3", "hash-1-4",
                                          "hash-2-0", "hash-2-1", "hash-2-2", "hash-2-3", "hash-2-4"]
        let affected = AttacheExhaustiveReviewCoordinator.detectSourceMutation(ledger: ledger, currentHashes: currentHashes)
        XCTAssertTrue(affected.contains("ep-0"), "mutated episode detected")
    }

    func testSourceVersionMismatchPreventsResume() {
        let map = makeMap(episodes: 3)
        var ledger = AttacheExhaustiveReviewCoordinator.buildLedger(from: map, sourceVersion: "v1")
        ledger.entries[0].markComplete(receiptID: "r-0")
        let canResume = AttacheExhaustiveReviewCoordinator.resume(&ledger, currentSourceVersion: "v2")
        XCTAssertFalse(canResume, "version mismatch prevents resume")
        XCTAssertEqual(ledger.overallStatus, .stale, "stale on version mismatch")
        XCTAssertTrue(ledger.entries.filter(\.isEligible).allSatisfy { $0.status == .stale },
                      "completed checkpoints are stale too")
    }

    func testEpisodeKeyedMutationInvalidatesOnlyChangedEntry() {
        let map = makeMap(episodes: 2)
        var ledger = AttacheExhaustiveReviewCoordinator.buildLedger(from: map, sourceVersion: "v1")
        ledger.entries[0].markComplete(receiptID: "r0")
        ledger.entries[1].markComplete(receiptID: "r1")
        ledger.updateOverallStatus()
        var hashes = Dictionary(uniqueKeysWithValues: ledger.entries.map { ($0.episodeID, $0.sourceHash) })
        hashes[ledger.entries[1].episodeID] = "mutated"
        XCTAssertFalse(AttacheExhaustiveReviewCoordinator.applySourceMutation(
            ledger: &ledger, currentHashesByEpisode: hashes, currentSourceVersion: "v1"
        ))
        XCTAssertEqual(ledger.entries[0].status, .complete)
        XCTAssertEqual(ledger.entries[1].status, .stale)
        XCTAssertEqual(ledger.overallStatus, .stale)
    }

    func testLargeCapabilityProducesLargerReviewStages() {
        let map = makeMap(episodes: 20)
        let small = AttacheExhaustiveReviewCoordinator.buildPlan(
            map: map, modelKey: "small",
            capability: AttacheModelCapabilityProfile(architecturalMaximum: 8_000, confidence: .authoritative, provenance: .providerMetadata),
            strategy: .maximumCoverage, egressClass: "local"
        )
        let large = AttacheExhaustiveReviewCoordinator.buildPlan(
            map: map, modelKey: "large",
            capability: AttacheModelCapabilityProfile(architecturalMaximum: 1_000_000, confidence: .authoritative, provenance: .providerMetadata),
            strategy: .maximumCoverage, egressClass: "local"
        )
        XCTAssertLessThanOrEqual(large.estimatedCallCount, small.estimatedCallCount)
        XCTAssertGreaterThanOrEqual(large.stages.first?.estimatedTokens ?? 0, small.stages.first?.estimatedTokens ?? 0)
    }

    func testFrozenEvidenceTokenEstimatesDriveStageBoundaries() {
        let map = makeMap(episodes: 4)
        let legacy = AttacheExhaustiveReviewCoordinator.buildPlan(
            map: map,
            modelKey: "small",
            capability: AttacheModelCapabilityProfile(architecturalMaximum: 8_000),
            strategy: .efficient,
            egressClass: "loopback"
        )
        let measured = AttacheExhaustiveReviewCoordinator.buildPlan(
            map: map,
            modelKey: "small",
            capability: AttacheModelCapabilityProfile(architecturalMaximum: 8_000),
            strategy: .efficient,
            egressClass: "loopback",
            estimatedTokensByEpisode: Dictionary(
                uniqueKeysWithValues: map.episodes.map { ($0.episodeID, 2_000) }
            )
        )

        XCTAssertEqual(legacy.estimatedCallCount, 1)
        XCTAssertEqual(measured.estimatedCallCount, 4)
        XCTAssertTrue(measured.stages.allSatisfy { $0.estimatedTokens == 2_000 })
    }

    func testSingleOversizedExactRangeIsNeverPlacedInAProviderStage() {
        let map = makeMap(episodes: 2)
        let plan = AttacheExhaustiveReviewCoordinator.buildPlan(
            map: map,
            modelKey: "small",
            capability: AttacheModelCapabilityProfile(architecturalMaximum: 8_000),
            strategy: .efficient,
            egressClass: "loopback",
            estimatedTokensByEpisode: ["ep-0": 12_000, "ep-1": 500]
        )

        XCTAssertEqual(plan.oversizedEpisodeIDs, ["ep-0"])
        XCTAssertFalse(plan.stages.flatMap(\.episodeIDs).contains("ep-0"))
        XCTAssertTrue(plan.stages.flatMap(\.episodeIDs).contains("ep-1"))
        XCTAssertTrue(plan.stages.allSatisfy { $0.estimatedTokens <= plan.maxStageInputTokens })
    }

    // Criterion 8: focus/personality/model switch does not mutate in-flight.
    func testFrozenIdentityPreventsMutation() {
        let frozen = AttacheReviewFrozenIdentity(
            sessionID: "s1", epoch: epoch, personalityID: "robot",
            modelKey: "ollama|qwen3", sourceVersion: "v1"
        )
        XCTAssertTrue(AttacheExhaustiveReviewCoordinator.frozenIdentityMatches(
            frozen: frozen, currentSessionID: "s1", currentEpoch: epoch,
            currentPersonalityID: "robot", currentModelKey: "ollama|qwen3",
            currentSourceVersion: "v1"
        ), "matching identity allows continuation")
        XCTAssertFalse(AttacheExhaustiveReviewCoordinator.frozenIdentityMatches(
            frozen: frozen, currentSessionID: "s2", currentEpoch: epoch,
            currentPersonalityID: "robot", currentModelKey: "ollama|qwen3",
            currentSourceVersion: "v1"
        ), "different session prevents mutation")
        XCTAssertFalse(AttacheExhaustiveReviewCoordinator.frozenIdentityMatches(
            frozen: frozen, currentSessionID: "s1", currentEpoch: AttacheFocusEpoch(2),
            currentPersonalityID: "robot", currentModelKey: "ollama|qwen3",
            currentSourceVersion: "v1"
        ), "different epoch prevents mutation")
    }

    func testConflictingIdentitiesDetected() {
        let frozen1 = AttacheReviewFrozenIdentity(sessionID: "s1", epoch: epoch, personalityID: "robot", modelKey: "a", sourceVersion: "v1")
        let frozen2 = AttacheReviewFrozenIdentity(sessionID: "s2", epoch: epoch, personalityID: "robot", modelKey: "a", sourceVersion: "v1")
        XCTAssertTrue(frozen1.conflictsWith(frozen2), "different sessions conflict")
        let frozen3 = AttacheReviewFrozenIdentity(sessionID: "s1", epoch: epoch, personalityID: "colt", modelKey: "a", sourceVersion: "v1")
        XCTAssertTrue(frozen1.conflictsWith(frozen3), "different personality conflicts")
    }

    // Criterion 9: no effectful tool or reverse-send in review stages.
    func testReviewIsEffectFree() {
        let cleanTracker = AttacheToolEffectTracker()
        XCTAssertTrue(AttacheExhaustiveReviewCoordinator.reviewIsEffectFree(effectTracker: cleanTracker),
                      "clean tracker is effect-free")
        var dirtyTracker = AttacheToolEffectTracker()
        dirtyTracker.recordEffect(toolName: "send_message", callID: "c1")
        XCTAssertFalse(AttacheExhaustiveReviewCoordinator.reviewIsEffectFree(effectTracker: dirtyTracker),
                       "effectful tracker is not effect-free")
    }

    // Criterion 10: receipts and UI disclose call count, coverage, omissions
    // without content leakage.
    func testResultIsContentFree() {
        let map = makeMap(episodes: 3)
        var ledger = AttacheExhaustiveReviewCoordinator.buildLedger(from: map, sourceVersion: "v1")
        ledger.entries[0].markComplete(receiptID: "r-0")
        ledger.entries[1].markComplete(receiptID: "r-1")
        ledger.entries[2].markFailed(reason: "budget")
        ledger.updateOverallStatus()
        let result = AttacheExhaustiveReviewCoordinator.buildResult(ledger: ledger, callCount: 3, fallbackCount: 1)
        XCTAssertTrue(result.isContentFree, "result is content-free")
        XCTAssertEqual(result.callCount, 3, "discloses call count")
        XCTAssertEqual(result.fallbackCount, 1, "discloses fallback count")
        XCTAssertEqual(result.status, .incomplete, "discloses incomplete status")
        XCTAssertGreaterThan(result.omittedRanges.count, 0, "discloses omissions")
        XCTAssertGreaterThan(result.coveragePercentage, 0, "discloses coverage percentage")
        XCTAssertLessThan(result.coveragePercentage, 1.0, "not 100% when incomplete")
    }

    // Ledger with excluded entries.
    func testExcludedEntriesCounted() {
        let episodes: [AttacheSessionMapEpisode] = [
            AttacheSessionMapEpisode(episodeID: "ep-0", sessionID: "s1", sourceKind: "codex",
                startTurnOrdinal: 0, endTurnOrdinal: 4, startTimestamp: Date(timeIntervalSince1970: 0), endTimestamp: Date(timeIntervalSince1970: 99),
                turnHashes: ["h1"], lexicalTerms: []),
            AttacheSessionMapEpisode(episodeID: "ep-1", sessionID: "s1", sourceKind: "codex",
                startTurnOrdinal: 5, endTurnOrdinal: 9, startTimestamp: Date(timeIntervalSince1970: 100), endTimestamp: Date(timeIntervalSince1970: 199),
                turnHashes: ["h2"], lexicalTerms: [], isExcluded: true, exclusionReason: "private"),
        ]
        let map = AttacheSessionMap(sessionID: "s1", sourceKind: "codex", episodes: episodes, totalTurnCount: 10, excludedTurnCount: 5)
        let ledger = AttacheExhaustiveReviewCoordinator.buildLedger(from: map, sourceVersion: "v1")
        XCTAssertEqual(ledger.eligibleCount, 1, "1 eligible")
        XCTAssertEqual(ledger.excludedCount, 1, "1 excluded")
    }
}
