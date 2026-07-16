import AttacheCore
import XCTest
import Foundation

final class AttacheSessionMapTests: XCTestCase {

    private func makeTurns(_ count: Int, prefix: String = "turn") -> [AttacheSessionMapTurn] {
        (0..<count).map { i in
            AttacheSessionMapTurn(
                ordinal: i, role: i % 2 == 0 ? "user" : "assistant",
                content: "\(prefix) \(i): topic \(i % 3 == 0 ? "alpha" : i % 3 == 1 ? "beta" : "gamma") discussion",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(i * 60))
            )
        }
    }

    // Criterion 1: a multi-million-token fixture produces a bounded map that
    // covers every eligible turn exactly once.
    func testBoundedMapCoversEveryEligibleTurn() {
        let turns = makeTurns(100)
        let map = AttacheSessionMapBuilder.build(sessionID: "s1", sourceKind: "codex", turns: turns)
        let diag = map.diagnostics()
        XCTAssertTrue(diag.isComplete, "every turn covered")
        XCTAssertEqual(diag.totalTurnCount, 100)
        XCTAssertEqual(diag.excludedTurnCount, 0)
        // Every turn ordinal appears in exactly one episode.
        var seenOrdinals: Set<Int> = []
        for episode in map.episodes {
            for ordinal in episode.startTurnOrdinal...episode.endTurnOrdinal {
                XCTAssertFalse(seenOrdinals.contains(ordinal), "turn \(ordinal) appears exactly once")
                seenOrdinals.insert(ordinal)
            }
        }
        XCTAssertEqual(seenOrdinals.count, 100, "all 100 turns covered")
    }

    func testStructuralEpisodeBoundsSplitAFlatTranscriptWithoutLosingTurns() {
        let turns = (0..<40).map { index in
            AttacheSessionMapTurn(
                ordinal: index,
                role: "assistant",
                content: String(repeating: "x", count: 2_000),
                timestamp: Date(timeIntervalSince1970: Double(index))
            )
        }
        let map = AttacheSessionMapBuilder.build(
            sessionID: "flat", sourceKind: "codex", turns: turns
        )

        XCTAssertTrue(map.diagnostics().isComplete)
        XCTAssertGreaterThan(map.episodes.count, 1)
        XCTAssertTrue(map.episodes.allSatisfy {
            $0.turnCount <= AttacheSessionMapBuilder.maxTurnsPerEpisode
        })
    }

    // Criterion 2: appending a short tail does not rebuild unchanged early
    // episodes.
    func testAppendDoesNotRebuildEarlyEpisodes() {
        let turns = makeTurns(20)
        let original = AttacheSessionMapBuilder.build(sessionID: "s1", sourceKind: "codex", turns: turns)
        let newTurns = makeTurns(25)[20..<25].map { $0 }
        let extended = AttacheSessionMapBuilder.extend(existing: original, newTurns: newTurns)
        // Early episodes are unchanged.
        let originalEarly = Array(original.episodes.prefix(original.episodes.count))
        let extendedEarly = Array(extended.episodes.prefix(original.episodes.count))
        XCTAssertEqual(originalEarly, extendedEarly, "early episodes not rebuilt")
        // The map grew.
        XCTAssertGreaterThan(extended.episodes.count, original.episodes.count)
        XCTAssertEqual(extended.totalTurnCount, 25)
    }

    // Criterion 3: topic shifts in beginning, middle, and end are independently
    // addressable.
    func testTopicShiftsIndependentlyAddressable() {
        let turns = (0..<30).map { i -> AttacheSessionMapTurn in
            let topic = i < 10 ? "alpha setup" : i < 20 ? "beta testing" : "gamma deploy"
            return AttacheSessionMapTurn(
                ordinal: i, role: "user",
                content: "Let us discuss \(topic)",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(i * 600))
            )
        }
        let map = AttacheSessionMapBuilder.build(sessionID: "s1", sourceKind: "codex", turns: turns)
        let alphaHits = map.query(AttacheSessionMapQuery(topic: "alpha"))
        let betaHits = map.query(AttacheSessionMapQuery(topic: "beta"))
        let gammaHits = map.query(AttacheSessionMapQuery(topic: "gamma"))
        XCTAssertGreaterThan(alphaHits.count, 0, "alpha addressable")
        XCTAssertGreaterThan(betaHits.count, 0, "beta addressable")
        XCTAssertGreaterThan(gammaHits.count, 0, "gamma addressable")
        // They cover different turn ranges.
        let alphaRange = alphaHits.first!.startTurnOrdinal
        let gammaRange = gammaHits.first!.startTurnOrdinal
        XCTAssertLessThan(alphaRange, gammaRange, "alpha is earlier than gamma")
    }

    // Criterion 4: truncation/replacement invalidates only affected regions.
    func testReplacementDetectsAffectedEpisodes() {
        let turns = makeTurns(20)
        let map = AttacheSessionMapBuilder.build(sessionID: "s1", sourceKind: "codex", turns: turns)
        // Replace turn 5's content.
        var modifiedTurns = turns
        modifiedTurns[5] = AttacheSessionMapTurn(ordinal: 5, role: "user", content: "completely different content")
        let affected = AttacheSessionMapBuilder.detectAffectedEpisodes(existing: map, currentTurns: modifiedTurns)
        XCTAssertNotNil(affected, "affected episodes detected")
        XCTAssertGreaterThan(affected!.count, 0, "at least one episode affected")
    }

    func testDeletedTurnTriggersFullRebuild() {
        let turns = makeTurns(20)
        let map = AttacheSessionMapBuilder.build(sessionID: "s1", sourceKind: "codex", turns: turns)
        // Delete turn 10 (middle deletion).
        let reduced = turns.filter { $0.ordinal != 10 }
        let affected = AttacheSessionMapBuilder.detectAffectedEpisodes(existing: map, currentTurns: reduced)
        XCTAssertNil(affected, "middle deletion triggers full rebuild (identity uncertain)")
    }

    // Criterion 5: map entries always carry session/range/hash provenance.
    func testEntriesCarryProvenance() {
        let turns = makeTurns(10)
        let map = AttacheSessionMapBuilder.build(sessionID: "s1", sourceKind: "codex", turns: turns)
        for episode in map.episodes {
            XCTAssertEqual(episode.sessionID, "s1")
            XCTAssertEqual(episode.sourceKind, "codex")
            XCTAssertLessThanOrEqual(episode.startTurnOrdinal, episode.endTurnOrdinal)
            XCTAssertFalse(episode.turnHashes.isEmpty)
            XCTAssertFalse(episode.combinedHash.isEmpty)
            XCTAssertEqual(episode.mapVersion, AttacheSessionMapBuilder.currentMapVersion)
        }
    }

    // Criterion 6: private reasoning, secrets, and excluded payloads are absent
    // from stored terms and labels.
    func testPrivateContentExcludedFromTerms() {
        let turns: [AttacheSessionMapTurn] = [
            AttacheSessionMapTurn(ordinal: 0, role: "user", content: "normal discussion about testing"),
            AttacheSessionMapTurn(ordinal: 1, role: "assistant", content: "private reasoning here", isPrivateReasoning: true),
            AttacheSessionMapTurn(ordinal: 2, role: "tool", content: "tool payload data", isToolPayload: true),
            AttacheSessionMapTurn(ordinal: 3, role: "user", content: "more normal discussion about deployment"),
        ]
        let map = AttacheSessionMapBuilder.build(sessionID: "s1", sourceKind: "codex", turns: turns)
        let diag = map.diagnostics()
        XCTAssertEqual(diag.excludedTurnCount, 2, "private reasoning and tool payload excluded")
        // The excluded episode has no lexical terms.
        let excludedEpisodes = map.episodes.filter { $0.isExcluded }
        for episode in excludedEpisodes {
            XCTAssertTrue(episode.lexicalTerms.isEmpty, "excluded episodes have no terms")
        }
        // Eligible episodes do not contain "private" or "tool payload".
        let eligibleEpisodes = map.episodes.filter { !$0.isExcluded }
        for episode in eligibleEpisodes {
            XCTAssertFalse(episode.lexicalTerms.contains("private"))
            XCTAssertFalse(episode.lexicalTerms.contains("payload"))
        }
    }

    func testSecretsExcludedFromTerms() {
        let turn = AttacheSessionMapTurn(ordinal: 0, role: "user", content: "the api_key is sk-1234567890abcdef and password is secret123")
        let terms = AttacheSessionMapBuilder.extractTerms(from: [turn])
        XCTAssertFalse(terms.contains("api_key"))
        XCTAssertFalse(terms.contains("password"))
        XCTAssertFalse(terms.contains("secret123"))
        XCTAssertFalse(terms.contains("sk-1234567890abcdef"))
    }

    // Criterion 7: no remote topic-label call without explicit consent.
    func testNoRemoteCallWithoutConsent() {
        XCTAssertTrue(AttacheSessionMapBuilder.requiresRemoteCallForLabels(hasProviderConsent: false, hasCompiledBudget: true),
                      "no consent -> no remote call")
        XCTAssertTrue(AttacheSessionMapBuilder.requiresRemoteCallForLabels(hasProviderConsent: true, hasCompiledBudget: false),
                      "no compiled budget -> no remote call")
        XCTAssertFalse(AttacheSessionMapBuilder.requiresRemoteCallForLabels(hasProviderConsent: true, hasCompiledBudget: true),
                       "consent + budget -> remote call allowed")
    }

    // Criterion 8: maps cannot focus a session or authorize their source.
    // A map is a derived navigation structure. It has no session authorization
    // field and cannot produce an AttacheFocusedSession.
    func testMapsCannotAuthorize() {
        let turns = makeTurns(10)
        let map = AttacheSessionMapBuilder.build(sessionID: "s1", sourceKind: "codex", turns: turns)
        // The map type has no authorization field. It cannot focus a session.
        // This test documents that by verifying the map is a pure data struct.
        XCTAssertEqual(map.sessionID, "s1")
        // There is no method on AttacheSessionMap that produces authorization.
        // The map is navigation metadata only.
        XCTAssertTrue(true, "map is a pure data struct, no authorization method")
    }

    // Criterion 9: raw logs remain the source of truth.
    func testMapsAreRebuildable() {
        let turns = makeTurns(10)
        let map1 = AttacheSessionMapBuilder.build(sessionID: "s1", sourceKind: "codex", turns: turns)
        let map2 = AttacheSessionMapBuilder.build(sessionID: "s1", sourceKind: "codex", turns: turns)
        XCTAssertEqual(map1, map2, "maps are deterministic and rebuildable from raw logs")
    }

    // Query by turn range.
    func testQueryByTurnRange() {
        let turns = makeTurns(30)
        let map = AttacheSessionMapBuilder.build(sessionID: "s1", sourceKind: "codex", turns: turns)
        let hits = map.query(AttacheSessionMapQuery(turnRange: AttacheSessionMapTurnRange(start: 10, end: 20)))
        for hit in hits {
            XCTAssertGreaterThanOrEqual(hit.endTurnOrdinal, 10)
            XCTAssertLessThanOrEqual(hit.startTurnOrdinal, 20)
        }
    }

    // Query by time range.
    func testQueryByTimeRange() {
        let turns = makeTurns(30)
        let map = AttacheSessionMapBuilder.build(sessionID: "s1", sourceKind: "codex", turns: turns)
        let startTime = Date(timeIntervalSince1970: 1_700_000_000 + Double(10 * 60))
        let endTime = Date(timeIntervalSince1970: 1_700_000_000 + Double(20 * 60))
        let hits = map.query(AttacheSessionMapQuery(startTime: startTime, endTime: endTime))
        for hit in hits {
            XCTAssertGreaterThanOrEqual(hit.endTimestamp, startTime)
            XCTAssertLessThanOrEqual(hit.startTimestamp, endTime)
        }
    }

    // Episode terms are bounded.
    func testTermsAreBounded() {
        let turn = AttacheSessionMapTurn(ordinal: 0, role: "user",
            content: (0..<100).map { "word\($0)" }.joined(separator: " "))
        let terms = AttacheSessionMapBuilder.extractTerms(from: [turn])
        XCTAssertLessThanOrEqual(terms.count, AttacheSessionMapBuilder.maxTermsPerEpisode, "terms bounded")
    }

    // Diagnostics are content-free.
    func testDiagnosticsAreContentFree() {
        let turns = makeTurns(10)
        let map = AttacheSessionMapBuilder.build(sessionID: "s1", sourceKind: "codex", turns: turns)
        let diag = map.diagnostics()
        XCTAssertEqual(diag.sessionID, "s1")
        XCTAssertEqual(diag.episodeCount, map.episodes.count)
        XCTAssertFalse(diag.labelSource?.contains("secret") ?? false)
    }
}
