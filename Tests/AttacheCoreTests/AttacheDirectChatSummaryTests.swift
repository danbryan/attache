import AttacheCore
import XCTest
import Foundation

final class AttacheDirectChatSummaryTests: XCTestCase {

    private func makeTurns(_ count: Int, prefix: String = "turn") -> [AttacheDirectChatTurn] {
        (0..<count).map { i in
            AttacheDirectChatTurn(
                id: "t\(i)", role: i % 2 == 0 ? .user : .attache,
                content: "\(prefix) \(i) " + String(repeating: "x", count: 200),
                turnIndex: i
            )
        }
    }

    private func makeReceipt() -> ContextReceipt {
        ContextReceipt(
            includedSources: ["recentDirectChatTurns"], omittedSources: ["olderChatSummary"],
            truncatedSources: [], totalEstimatedTokens: 100, remainingBudget: 50,
            modelIdentityKey: "ollama|qwen3", strategyKind: "automatic",
            stagedProcessingRequired: false
        )
    }

    // Criterion 1: synthetic histories far beyond 8K compile within plan while
    // preserving the latest turn, active personality, key decisions, and open
    // questions.
    func testLongHistoryCompilesWithinPlan() {
        let turns = makeTurns(100) // ~20K tokens of content
        let plan = AttacheDirectChatSummaryPlanner.plan(
            turns: turns, strategy: .automatic, budgetTokens: 4_000
        )
        // The exact suffix must be bounded: it fits within the suffix budget.
        let suffixTurns = Array(turns[plan.exactSuffixStartIndex..<turns.count])
        XCTAssertLessThan(suffixTurns.count, turns.count, "older turns are summarized, not all exact")
        XCTAssertGreaterThan(plan.segmentsToSummarize.count, 0, "older turns become segments")
        // The latest turn is always in the suffix.
        XCTAssertTrue(suffixTurns.contains(where: { $0.turnIndex == turns.last!.turnIndex }),
                      "latest turn preserved")
    }

    // Criterion 2: a 1M Maximum coverage plan includes more raw history than
    // an 8K Efficient plan.
    func testMaximumCoverageIncludesMoreRawHistoryThanEfficient() {
        let turns = makeTurns(50)
        let efficient = AttacheDirectChatSummaryPlanner.plan(
            turns: turns, strategy: .efficient, budgetTokens: 8_000
        )
        let maximum = AttacheDirectChatSummaryPlanner.plan(
            turns: turns, strategy: .maximumCoverage, budgetTokens: 1_000_000
        )
        // Maximum coverage starts the exact suffix earlier (more raw turns).
        XCTAssertLessThanOrEqual(
            maximum.exactSuffixStartIndex, efficient.exactSuffixStartIndex,
            "Maximum includes more raw history than Efficient"
        )
        // On a 1M model, Maximum may keep everything exact (no segments).
        let maximumSuffixCount = turns.count - maximum.exactSuffixStartIndex
        let efficientSuffixCount = turns.count - efficient.exactSuffixStartIndex
        XCTAssertGreaterThanOrEqual(maximumSuffixCount, efficientSuffixCount,
                                    "Maximum suffix is at least as large as Efficient")
    }

    // Criterion 3: summaries cite exact turn ranges/hashes and can be rebuilt
    // from raw cards.
    func testCapsulesCiteTurnRangesAndHashes() {
        let turns = makeTurns(20)
        let plan = AttacheDirectChatSummaryPlanner.plan(
            turns: turns, strategy: .efficient, budgetTokens: 1_000
        )
        XCTAssertGreaterThan(plan.segmentsToSummarize.count, 0)
        for segment in plan.segmentsToSummarize {
            XCTAssertLessThanOrEqual(segment.startTurnIndex, segment.endTurnIndex)
            XCTAssertFalse(segment.combinedHash.isEmpty, "segment has a content hash")
            XCTAssertFalse(segment.turnIDs.isEmpty, "segment cites its source turn IDs")
        }
        // A capsule built from a segment cites the same range and hash.
        let segment = plan.segmentsToSummarize[0]
        let capsule = AttacheDirectChatSummaryCapsule(
            id: "cap-1", segmentID: segment.id,
            startTurnIndex: segment.startTurnIndex, endTurnIndex: segment.endTurnIndex,
            sourceHash: segment.combinedHash,
            establishedFacts: ["fact A"], decisions: ["decide B"],
            openQuestions: ["question C"], corrections: [],
            unresolvedCommitments: ["commit D"],
            summarizerVersion: AttacheDirectChatSummaryPlanner.summarizerVersion,
            modelIdentityKey: "ollama|qwen3", receipt: makeReceipt()
        )
        XCTAssertEqual(capsule.startTurnIndex, segment.startTurnIndex)
        XCTAssertEqual(capsule.endTurnIndex, segment.endTurnIndex)
        XCTAssertEqual(capsule.sourceHash, segment.combinedHash)
    }

    // Criterion 4: later corrections supersede older summary claims.
    func testLaterCorrectionsSupersedeOlderClaims() {
        let olderCapsule = AttacheDirectChatSummaryCapsule(
            id: "cap-1", segmentID: "seg-0-7", startTurnIndex: 0, endTurnIndex: 7,
            sourceHash: "hash1", establishedFacts: ["the deadline is Friday"],
            decisions: [], openQuestions: [], corrections: [],
            unresolvedCommitments: [], summarizerVersion: "v1",
            modelIdentityKey: "ollama|qwen3", receipt: makeReceipt()
        )
        let laterCorrection = AttacheDirectChatCorrection(
            turnIndex: 10, supersedesClaim: "the deadline is Friday",
            correctedClaim: "the deadline is Monday"
        )
        let applied = AttacheDirectChatSummaryCompiler.applyCorrections(
            to: olderCapsule, allCorrections: [laterCorrection]
        )
        XCTAssertTrue(applied.establishedFacts.contains("the deadline is Monday"),
                      "later correction supersedes older claim")
        XCTAssertFalse(applied.establishedFacts.contains("the deadline is Friday"),
                       "older claim is replaced")
    }

    func testEarlierCorrectionDoesNotSupersedeLaterCapsule() {
        let laterCapsule = AttacheDirectChatSummaryCapsule(
            id: "cap-2", segmentID: "seg-8-15", startTurnIndex: 8, endTurnIndex: 15,
            sourceHash: "hash2", establishedFacts: ["the deadline is Monday"],
            decisions: [], openQuestions: [], corrections: [],
            unresolvedCommitments: [], summarizerVersion: "v1",
            modelIdentityKey: "ollama|qwen3", receipt: makeReceipt()
        )
        let earlierCorrection = AttacheDirectChatCorrection(
            turnIndex: 3, supersedesClaim: "the deadline is Monday",
            correctedClaim: "the deadline is Friday"
        )
        let applied = AttacheDirectChatSummaryCompiler.applyCorrections(
            to: laterCapsule, allCorrections: [earlierCorrection]
        )
        XCTAssertTrue(applied.establishedFacts.contains("the deadline is Monday"),
                      "earlier correction does not supersede a later capsule")
    }

    // Criterion 5: deletion/edit invalidates only affected derived summaries.
    func testInvalidateBySourceHashOnlyAffectsMatching() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-chat-summary-\(UUID().uuidString).sqlite")
        let store = AttacheDirectChatSummaryStore(databaseURL: tmp)
        let cap1 = AttacheDirectChatSummaryCapsule(
            id: "cap-1", segmentID: "seg-0-7", startTurnIndex: 0, endTurnIndex: 7,
            sourceHash: "hash-A", establishedFacts: ["fact A"], decisions: [],
            openQuestions: [], corrections: [], unresolvedCommitments: [],
            summarizerVersion: AttacheDirectChatSummaryPlanner.summarizerVersion,
            modelIdentityKey: "ollama|qwen3", receipt: makeReceipt()
        )
        let cap2 = AttacheDirectChatSummaryCapsule(
            id: "cap-2", segmentID: "seg-8-15", startTurnIndex: 8, endTurnIndex: 15,
            sourceHash: "hash-B", establishedFacts: ["fact B"], decisions: [],
            openQuestions: [], corrections: [], unresolvedCommitments: [],
            summarizerVersion: AttacheDirectChatSummaryPlanner.summarizerVersion,
            modelIdentityKey: "ollama|qwen3", receipt: makeReceipt()
        )
        XCTAssertTrue(store.add(cap1))
        XCTAssertTrue(store.add(cap2))
        let invalidated = store.invalidateBySourceHashes(["hash-A"])
        XCTAssertEqual(invalidated, 1, "only the capsule with hash-A is invalidated")
        let active = store.list(activeOnly: true)
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.id, "cap-2", "the unaffected capsule stays active")
        try? FileManager.default.removeItem(at: tmp)
    }

    func testInvalidateBySummarizerVersion() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-chat-summary-\(UUID().uuidString).sqlite")
        let store = AttacheDirectChatSummaryStore(databaseURL: tmp)
        let oldVersion = AttacheDirectChatSummaryCapsule(
            id: "cap-old", segmentID: "seg-0-7", startTurnIndex: 0, endTurnIndex: 7,
            sourceHash: "hash-A", establishedFacts: [], decisions: [],
            openQuestions: [], corrections: [], unresolvedCommitments: [],
            summarizerVersion: "old.v0", modelIdentityKey: "ollama|qwen3",
            receipt: makeReceipt()
        )
        let currentVersion = AttacheDirectChatSummaryCapsule(
            id: "cap-cur", segmentID: "seg-8-15", startTurnIndex: 8, endTurnIndex: 15,
            sourceHash: "hash-B", establishedFacts: [], decisions: [],
            openQuestions: [], corrections: [], unresolvedCommitments: [],
            summarizerVersion: AttacheDirectChatSummaryPlanner.summarizerVersion,
            modelIdentityKey: "ollama|qwen3", receipt: makeReceipt()
        )
        store.add(oldVersion)
        store.add(currentVersion)
        let invalidated = store.invalidateBySummarizerVersion(
            olderThan: AttacheDirectChatSummaryPlanner.summarizerVersion
        )
        XCTAssertEqual(invalidated, 1, "only the old-version capsule is invalidated")
        XCTAssertEqual(store.list(activeOnly: true).count, 1)
        try? FileManager.default.removeItem(at: tmp)
    }

    // Criterion 6: personality switches do not rewrite history in the new tone
    // or leak another prompt. Capsules are neutral.
    func testCapsulesAreNeutralAndDoNotLeakPrompts() {
        let capsule = AttacheDirectChatSummaryCapsule(
            id: "cap-1", segmentID: "seg-0-7", startTurnIndex: 0, endTurnIndex: 7,
            sourceHash: "hash", establishedFacts: ["the build is green"],
            decisions: ["ship on Friday"], openQuestions: ["who writes the notes?"],
            corrections: [], unresolvedCommitments: ["Dan finalizes the cask"],
            summarizerVersion: "v1", modelIdentityKey: "ollama|qwen3",
            receipt: makeReceipt()
        )
        let messages = AttacheDirectChatSummaryCompiler.compile(
            capsules: [capsule], exactSuffixTurns: [], plan: AttacheDirectChatSummaryPlan(
                exactSuffixStartIndex: 8, segmentsToSummarize: [], strategyKind: .automatic
            )
        )
        let rendered = messages.map { $0.content }.joined(separator: "\n")
        // The capsule is neutral: it does not speak in a personality's voice.
        XCTAssertFalse(rendered.contains("Y'all"), "no cowboy tone")
        XCTAssertFalse(rendered.contains("as your faithful"), "no personality voice")
        // It does not leak another personality's prompt.
        XCTAssertFalse(rendered.lowercased().contains("you are"), "no leaked system prompt")
        XCTAssertTrue(rendered.contains("Established facts"))
        XCTAssertTrue(rendered.contains("Open questions"))
    }

    // Criterion 7: summary failure has a bounded, disclosed fallback.
    func testFallbackPlanIsBoundedAndDisclosed() {
        let turns = makeTurns(40)
        let fallback = AttacheDirectChatSummaryPlanner.fallbackPlan(
            turns: turns, budgetTokens: 2_000
        )
        XCTAssertTrue(fallback.fallbackBounded, "fallback is bounded")
        XCTAssertNotNil(fallback.continuityLimitationNote, "fallback discloses the limitation")
        XCTAssertTrue(fallback.continuityLimitationNote?.contains("Summarization unavailable") ?? false)
        XCTAssertEqual(fallback.segmentsToSummarize.count, 0, "no segments summarized in fallback")
        // The exact suffix is bounded by the budget.
        let suffixCount = turns.count - fallback.exactSuffixStartIndex
        XCTAssertGreaterThan(suffixCount, 0)
        XCTAssertLessThan(suffixCount, turns.count, "not everything is included in fallback")
    }

    // Criterion 8: direct-chat summaries do not authorize or contain hidden
    // work-session context.
    func testSummaryDoesNotContainWorkSessionContext() {
        let capsule = AttacheDirectChatSummaryCapsule(
            id: "cap-1", segmentID: "seg-0-7", startTurnIndex: 0, endTurnIndex: 7,
            sourceHash: "hash", establishedFacts: ["a direct-chat fact"],
            decisions: [], openQuestions: [], corrections: [],
            unresolvedCommitments: [], summarizerVersion: "v1",
            modelIdentityKey: "ollama|qwen3", receipt: makeReceipt()
        )
        let suffixTurn = AttacheDirectChatTurn(
            id: "t8", role: .user, content: "what should I do next?", turnIndex: 8
        )
        let messages = AttacheDirectChatSummaryCompiler.compile(
            capsules: [capsule], exactSuffixTurns: [suffixTurn],
            plan: AttacheDirectChatSummaryPlan(
                exactSuffixStartIndex: 8, segmentsToSummarize: [], strategyKind: .automatic
            )
        )
        let rendered = messages.map { $0.content }.joined(separator: "\n")
        // No work-session transcript, path, or metadata appears.
        let forbidden = ["transcript", "/Users/dan/code", "sessionID", "read_file", "tool result"]
        for marker in forbidden {
            XCTAssertFalse(rendered.contains(marker),
                           "direct-chat summary must not contain work-session context: \(marker)")
        }
    }

    // A turn explicitly quoting session content is flagged; non-quoting turns
    // are not. This is the isolation boundary (INF-316).
    func testExplicitQuoteDetection() {
        let quoting = AttacheDirectChatTurn(
            id: "q1", role: .user,
            content: "The agent said: the test failed", turnIndex: 1
        )
        let notQuoting = AttacheDirectChatTurn(
            id: "q2", role: .user, content: "what should I do next?", turnIndex: 2
        )
        XCTAssertTrue(AttacheDirectChatSummaryCompiler.turnContainsExplicitQuote(quoting))
        XCTAssertFalse(AttacheDirectChatSummaryCompiler.turnContainsExplicitQuote(notQuoting))
    }

    // Content hashes are deterministic and change when content changes.
    func testContentHashIsDeterministicAndSensitive() {
        let turn1 = AttacheDirectChatTurn(id: "a", role: .user, content: "hello", turnIndex: 0)
        let turn2 = AttacheDirectChatTurn(id: "b", role: .user, content: "hello", turnIndex: 0)
        let turn3 = AttacheDirectChatTurn(id: "c", role: .user, content: "hello!", turnIndex: 0)
        XCTAssertEqual(turn1.contentHash, turn2.contentHash, "same content -> same hash")
        XCTAssertNotEqual(turn1.contentHash, turn3.contentHash, "different content -> different hash")
    }

    // Store round-trips a capsule.
    func testStoreRoundTripsCapsule() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-chat-summary-\(UUID().uuidString).sqlite")
        let store = AttacheDirectChatSummaryStore(databaseURL: tmp)
        let capsule = AttacheDirectChatSummaryCapsule(
            id: "cap-1", segmentID: "seg-0-7", startTurnIndex: 0, endTurnIndex: 7,
            sourceHash: "hash-A", establishedFacts: ["fact A", "fact B"],
            decisions: ["decide C"], openQuestions: ["q D"],
            corrections: [AttacheDirectChatCorrection(turnIndex: 5, supersedesClaim: "old", correctedClaim: "new")],
            unresolvedCommitments: ["commit E"], summarizerVersion: "v1",
            modelIdentityKey: "ollama|qwen3", receipt: makeReceipt()
        )
        XCTAssertTrue(store.add(capsule))
        let restored = store.list().first
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.establishedFacts, ["fact A", "fact B"])
        XCTAssertEqual(restored?.decisions, ["decide C"])
        XCTAssertEqual(restored?.corrections.first?.correctedClaim, "new")
        XCTAssertEqual(restored?.sourceHash, "hash-A")
        try? FileManager.default.removeItem(at: tmp)
    }

    // Compile produces messages in capsule-then-suffix order.
    func testCompileOrderIsCapsulesThenSuffix() {
        let cap1 = AttacheDirectChatSummaryCapsule(
            id: "cap-1", segmentID: "seg-0-7", startTurnIndex: 0, endTurnIndex: 7,
            sourceHash: "h1", establishedFacts: ["early fact"], decisions: [],
            openQuestions: [], corrections: [], unresolvedCommitments: [],
            summarizerVersion: "v1", modelIdentityKey: "k", receipt: makeReceipt()
        )
        let cap2 = AttacheDirectChatSummaryCapsule(
            id: "cap-2", segmentID: "seg-8-15", startTurnIndex: 8, endTurnIndex: 15,
            sourceHash: "h2", establishedFacts: ["later fact"], decisions: [],
            openQuestions: [], corrections: [], unresolvedCommitments: [],
            summarizerVersion: "v1", modelIdentityKey: "k", receipt: makeReceipt()
        )
        let suffix = AttacheDirectChatTurn(id: "t16", role: .user, content: "latest", turnIndex: 16)
        let messages = AttacheDirectChatSummaryCompiler.compile(
            capsules: [cap2, cap1], // intentionally out of order
            exactSuffixTurns: [suffix],
            plan: AttacheDirectChatSummaryPlan(
                exactSuffixStartIndex: 16, segmentsToSummarize: [], strategyKind: .automatic
            )
        )
        // Capsules sorted by start turn, then suffix last.
        XCTAssertTrue(messages[0].content.contains("early fact"))
        XCTAssertTrue(messages[1].content.contains("later fact"))
        XCTAssertEqual(messages.last?.content, "latest")
    }
}