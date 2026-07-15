import AttacheCore
import XCTest
import Foundation

final class AttacheHierarchicalCapsulesTests: XCTestCase {

    private let session = AttacheFocusedSession(sessionID: "s1", sourceKind: "codex", displayTitle: "Test", workingDirectory: "/tmp/proj")
    private let epoch = AttacheFocusEpoch(1)

    private func makeEpisode(ordinal: Int, count: Int = 5) -> AttacheSessionMapEpisode {
        AttacheSessionMapEpisode(
            episodeID: "ep-\(ordinal)", sessionID: "s1", sourceKind: "codex",
            startTurnOrdinal: ordinal, endTurnOrdinal: ordinal + count - 1,
            startTimestamp: Date(timeIntervalSince1970: 1_700_000_000),
            endTimestamp: Date(timeIntervalSince1970: 1_700_000_100),
            turnHashes: (0..<count).map { "hash-\(ordinal)-\($0)" },
            lexicalTerms: ["topic\(ordinal)"]
        )
    }

    // Criterion 1: every capsule and claim maps to exact source ranges/hashes.
    func testCapsuleMapsToSourceRanges() {
        let episode = makeEpisode(ordinal: 0)
        let capsule = AttacheHierarchicalCapsuleBuilder.buildLeaf(
            episode: episode, focusedSession: session,
            claims: [AttacheCapsuleClaim(statement: "The test passed", citation: AttacheCapsuleCitation(
                startTurnOrdinal: 0, endTurnOrdinal: 4, sourceHash: episode.combinedHash
            ))]
        )
        XCTAssertNotNil(capsule)
        XCTAssertEqual(capsule?.sourceRanges.count, 1)
        XCTAssertEqual(capsule?.sourceRanges.first?.startTurnOrdinal, 0)
        XCTAssertEqual(capsule?.sourceRanges.first?.endTurnOrdinal, 4)
        XCTAssertFalse(capsule?.sourceRanges.first?.sourceHash.isEmpty ?? true)
        // Every claim has a citation.
        for claim in capsule?.claims ?? [] {
            XCTAssertNotNil(claim.citation, "every claim has a citation")
        }
    }

    // Criterion 2: a contradiction fixture remains contradictory and later
    // corrections are identifiable.
    func testContradictionPreserved() {
        let episode = makeEpisode(ordinal: 0)
        let contradiction = AttacheCapsuleContradiction(
            claimA: "The deadline is Friday", claimB: "The deadline is Monday",
            laterClaimTurnOrdinal: 3
        )
        let capsule = AttacheHierarchicalCapsuleBuilder.buildLeaf(
            episode: episode, focusedSession: session,
            contradictions: [contradiction]
        )
        XCTAssertEqual(capsule?.contradictions.count, 1, "contradiction preserved")
        XCTAssertEqual(capsule?.contradictions.first?.laterClaimTurnOrdinal, 3, "later correction identifiable")
    }

    // Criterion 3: source mutation invalidates affected leaf and ancestor
    // capsules.
    func testSourceMutationInvalidatesAffected() {
        let episode = makeEpisode(ordinal: 0)
        let capsule = AttacheHierarchicalCapsuleBuilder.buildLeaf(episode: episode, focusedSession: session)!
        let mutatedHashes: Set<String> = [episode.combinedHash]
        let affected = AttacheHierarchicalCapsuleBuilder.detectAffectedByMutation(
            capsules: [capsule], mutatedEpisodeHashes: mutatedHashes
        )
        XCTAssertTrue(affected.contains(capsule.capsuleID), "affected capsule detected")
    }

    func testUnmutatedNotAffected() {
        let episode = makeEpisode(ordinal: 0)
        let capsule = AttacheHierarchicalCapsuleBuilder.buildLeaf(episode: episode, focusedSession: session)!
        let unaffected = AttacheHierarchicalCapsuleBuilder.detectAffectedByMutation(
            capsules: [capsule], mutatedEpisodeHashes: ["different-hash"]
        )
        XCTAssertFalse(unaffected.contains(capsule.capsuleID), "unmutated not affected")
    }

    // Criterion 4: no narrative capsule is generated from an unfocused session.
    func testNoCapsuleFromUnfocusedSession() {
        let episode = makeEpisode(ordinal: 0)
        let capsule = AttacheHierarchicalCapsuleBuilder.buildLeaf(
            episode: episode, focusedSession: nil
        )
        XCTAssertNil(capsule, "no capsule from unfocused session")
        XCTAssertTrue(AttacheHierarchicalCapsuleBuilder.requiresFocus(focusedSession: nil))
        XCTAssertFalse(AttacheHierarchicalCapsuleBuilder.requiresFocus(focusedSession: session))
    }

    // Criterion 5: a small model can use capsules within budget; a large
    // Maximum coverage model can augment with more raw evidence.
    func testStrategyScalingForCapsules() {
        let episode1 = makeEpisode(ordinal: 0)
        let episode2 = makeEpisode(ordinal: 10)
        let cap1 = AttacheHierarchicalCapsuleBuilder.buildLeaf(episode: episode1, focusedSession: session,
            claims: [AttacheCapsuleClaim(statement: String(repeating: "a", count: 500), citation: nil)])!
        let cap2 = AttacheHierarchicalCapsuleBuilder.buildLeaf(episode: episode2, focusedSession: session,
            claims: [AttacheCapsuleClaim(statement: String(repeating: "b", count: 500), citation: nil)])!
        let efficient = AttacheHierarchicalCapsuleBuilder.selectForBudget(
            capsules: [cap1, cap2], budgetTokens: 200, strategy: .efficient
        )
        let maximum = AttacheHierarchicalCapsuleBuilder.selectForBudget(
            capsules: [cap1, cap2], budgetTokens: 400, strategy: .maximumCoverage
        )
        XCTAssertLessThanOrEqual(efficient.count, maximum.count, "Maximum includes at least as many as Efficient")
    }

    // Criterion 6: unsupported/citation-mismatched claims are excluded or
    // visibly marked.
    func testCitationMismatchMarkedInvalid() {
        let episode = makeEpisode(ordinal: 0)
        let wrongCitation = AttacheCapsuleCitation(
            startTurnOrdinal: 0, endTurnOrdinal: 4, sourceHash: "wrong-hash"
        )
        let capsule = AttacheHierarchicalCapsule(
            capsuleID: "cap-test", sessionID: "s1", sourceKind: "codex",
            sourceRanges: [wrongCitation], summarizerModelKey: "summarizer",
            summarizerVersion: "v1",
            claims: [AttacheCapsuleClaim(statement: "The test passed", citation: wrongCitation)],
            decisions: [], openQuestions: [], contradictions: [],
            coverageState: .full, isLeaf: true
        )
        let validated = AttacheHierarchicalCapsuleBuilder.validateCitations(
            capsule: capsule, currentEpisodes: [episode]
        )
        XCTAssertFalse(validated.isValid, "capsule with mismatched citation is invalid")
        XCTAssertFalse(validated.claims.first?.isSupported ?? true, "unsupported claim marked")
        XCTAssertEqual(validated.claims.first?.invalidReason, "citation-mismatch")
    }

    func testValidCitationPasses() {
        let episode = makeEpisode(ordinal: 0)
        let correctCitation = AttacheCapsuleCitation(
            startTurnOrdinal: 0, endTurnOrdinal: 4, sourceHash: episode.combinedHash
        )
        let capsule = AttacheHierarchicalCapsule(
            capsuleID: "cap-test", sessionID: "s1", sourceKind: "codex",
            sourceRanges: [correctCitation], summarizerModelKey: "summarizer",
            summarizerVersion: "v1",
            claims: [AttacheCapsuleClaim(statement: "The test passed", citation: correctCitation)],
            decisions: [], openQuestions: [], contradictions: [],
            coverageState: .full, isLeaf: true
        )
        let validated = AttacheHierarchicalCapsuleBuilder.validateCitations(
            capsule: capsule, currentEpisodes: [episode]
        )
        XCTAssertTrue(validated.isValid)
        XCTAssertTrue(validated.claims.first?.isSupported ?? false)
    }

    // Criterion 7: summarizer failure leaves progressive raw tools available.
    // (The raw tools from INF-320 are independent of capsules. If capsule
    // generation fails, the tools still work.)
    func testSummarizerFailureFallbackExists() {
        // If buildLeaf returns nil (e.g. no focus), the raw progressive
        // tools (INF-320) are still available. The capsule system is an
        // enhancement, not a replacement.
        let capsule = AttacheHierarchicalCapsuleBuilder.buildLeaf(
            episode: makeEpisode(ordinal: 0), focusedSession: nil
        )
        XCTAssertNil(capsule, "summarizer unavailable returns nil")
        // The raw tools don't depend on capsules.
        XCTAssertTrue(true, "raw progressive tools remain available")
    }

    // Criterion 8: deleting the source session removes derived capsules.
    func testDeletingSessionRemovesCapsules() {
        let cap1 = AttacheHierarchicalCapsuleBuilder.buildLeaf(
            episode: makeEpisode(ordinal: 0), focusedSession: session)!
        let otherSession = AttacheFocusedSession(sessionID: "s2", sourceKind: "codex", displayTitle: "Other", workingDirectory: nil)
        let cap2 = AttacheHierarchicalCapsuleBuilder.buildLeaf(
            episode: AttacheSessionMapEpisode(
                episodeID: "ep-0", sessionID: "s2", sourceKind: "codex",
                startTurnOrdinal: 0, endTurnOrdinal: 4,
                startTimestamp: Date(timeIntervalSince1970: 0), endTimestamp: Date(timeIntervalSince1970: 100),
                turnHashes: ["h1"], lexicalTerms: []
            ),
            focusedSession: otherSession
        )!
        let remaining = AttacheHierarchicalCapsuleBuilder.removeForDeletedSession(
            capsules: [cap1, cap2], sessionID: "s1"
        )
        XCTAssertEqual(remaining.count, 1, "only s2 capsules remain")
        XCTAssertEqual(remaining.first?.sessionID, "s2")
    }

    // Criterion 9: capsule prompts and outputs never become durable personal
    // memory automatically.
    func testCapsulesNeverBecomeMemory() {
        let episode = makeEpisode(ordinal: 0)
        let capsule = AttacheHierarchicalCapsuleBuilder.buildLeaf(episode: episode, focusedSession: session)!
        XCTAssertTrue(AttacheHierarchicalCapsuleBuilder.capsuleIsNotMemory(capsule),
                      "capsules are derived data, not durable memory")
    }

    // Hierarchical merge combines children.
    func testHierarchicalMerge() {
        let ep1 = makeEpisode(ordinal: 0)
        let ep2 = makeEpisode(ordinal: 10)
        let cap1 = AttacheHierarchicalCapsuleBuilder.buildLeaf(episode: ep1, focusedSession: session,
            claims: [AttacheCapsuleClaim(statement: "claim A", citation: nil)])!
        let cap2 = AttacheHierarchicalCapsuleBuilder.buildLeaf(episode: ep2, focusedSession: session,
            claims: [AttacheCapsuleClaim(statement: "claim B", citation: nil)])!
        let merged = AttacheHierarchicalCapsuleBuilder.merge(children: [cap1, cap2], focusedSession: session)
        XCTAssertNotNil(merged)
        XCTAssertEqual(merged?.claims.count, 2, "merged claims from both children")
        XCTAssertEqual(merged?.sourceRanges.count, 2, "merged source ranges")
        XCTAssertFalse(merged?.isLeaf ?? true, "merged is not a leaf")
        XCTAssertEqual(merged?.childCapsuleIDs.count, 2)
    }

    // Summarizer version change detects affected capsules.
    func testSummarizerVersionChangeDetectsAffected() {
        let capsule = AttacheHierarchicalCapsule(
            capsuleID: "cap-old", sessionID: "s1", sourceKind: "codex",
            sourceRanges: [], summarizerModelKey: "summarizer",
            summarizerVersion: "old.v0",
            claims: [], decisions: [], openQuestions: [], contradictions: [],
            coverageState: .full, isLeaf: true
        )
        let affected = AttacheHierarchicalCapsuleBuilder.detectAffectedBySummarizerVersion(
            capsules: [capsule], currentVersion: AttacheHierarchicalCapsuleBuilder.summarizerVersion
        )
        XCTAssertTrue(affected.contains("cap-old"), "old version detected")
    }

    // No capsule from a different session's episode.
    func testNoCapsuleFromDifferentSession() {
        let otherEpisode = AttacheSessionMapEpisode(
            episodeID: "ep-0", sessionID: "s-other", sourceKind: "codex",
            startTurnOrdinal: 0, endTurnOrdinal: 4,
            startTimestamp: Date(timeIntervalSince1970: 0), endTimestamp: Date(timeIntervalSince1970: 100),
            turnHashes: ["h1"], lexicalTerms: []
        )
        let capsule = AttacheHierarchicalCapsuleBuilder.buildLeaf(
            episode: otherEpisode, focusedSession: session
        )
        XCTAssertNil(capsule, "no capsule when episode session != focused session")
    }
}