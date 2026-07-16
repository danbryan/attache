import AttacheCore
import Foundation
import XCTest
@testable import AttacheApp

final class AttacheDirectChatRuntimeTests: XCTestCase {
    func testStartupPurgesCapsulesOrphanedByACrashedCall() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-direct-chat-orphan-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        var writer: AttacheDirectChatSummaryStore? = AttacheDirectChatSummaryStore(databaseURL: url)
        let receipt = ContextReceipt(
            includedSources: [], omittedSources: [], truncatedSources: [],
            totalEstimatedTokens: 1, remainingBudget: 1,
            modelIdentityKey: "local", strategyKind: "automatic",
            stagedProcessingRequired: false
        )
        XCTAssertTrue(writer?.add(AttacheDirectChatSummaryCapsule(
            id: "orphan", segmentID: "orphan-segment",
            startTurnIndex: 0, endTurnIndex: 0,
            sourceHash: "orphan-hash", establishedFacts: ["orphaned private turn"],
            decisions: [], openQuestions: [], corrections: [],
            unresolvedCommitments: [], summarizerVersion: "v1",
            modelIdentityKey: "local", receipt: receipt, callID: "crashed-call"
        )) == true)
        writer = nil

        _ = AttacheDirectChatRuntime(databaseURL: url)
        let inspector = AttacheDirectChatSummaryStore(databaseURL: url)
        XCTAssertTrue(inspector.list(activeOnly: false).isEmpty)
    }

    func testLongCallUsesContentHashedCapsulesAndExactRecentSuffix() {
        let runtime = makeRuntime()
        let callID = UUID()
        let turns = makeTurns(prefix: "original", count: 28)

        let first = runtime.capture(
            turns: turns,
            callID: callID,
            strategy: .efficient,
            capability: capability(8_000),
            userInput: turns.last!.text,
            profilePrompt: "Be concise."
        )

        XCTAssertFalse(first.summaryItems.isEmpty)
        XCTAssertFalse(first.exactMessages.isEmpty)
        XCTAssertEqual(first.exactMessages.last?.content, turns.last?.text)
        XCTAssertTrue(first.summaryItems.allSatisfy { $0.source == .olderChatSummary })

        var edited = turns
        edited[0] = ConversationTurn(
            id: turns[0].id,
            role: turns[0].role,
            text: "corrected " + String(repeating: "detail ", count: 180),
            createdAt: turns[0].createdAt
        )
        let second = runtime.capture(
            turns: edited,
            callID: callID,
            strategy: .efficient,
            capability: capability(8_000),
            userInput: edited.last!.text,
            profilePrompt: "Be concise."
        )

        XCTAssertNotEqual(
            first.summaryItems.first?.provenance,
            second.summaryItems.first?.provenance,
            "changing source content must invalidate and replace the capsule"
        )
    }

    func testNewCallCannotReceivePriorCallTurnsOrCapsules() {
        let runtime = makeRuntime()
        let oldTurns = makeTurns(prefix: "old-call-secret", count: 28)
        let old = runtime.capture(
            turns: oldTurns,
            callID: UUID(),
            strategy: .efficient,
            capability: capability(8_000),
            userInput: oldTurns.last!.text,
            profilePrompt: "Be concise."
        )
        XCTAssertFalse(old.summaryItems.isEmpty)

        let newTurn = ConversationTurn(
            id: "new-turn",
            role: .user,
            text: "hello from the new call",
            createdAt: Date()
        )
        let fresh = runtime.capture(
            turns: [newTurn],
            callID: UUID(),
            strategy: .efficient,
            capability: capability(8_000),
            userInput: newTurn.text,
            profilePrompt: "Be concise."
        )

        XCTAssertTrue(fresh.summaryItems.isEmpty)
        XCTAssertEqual(fresh.exactMessages.map(\.content), [newTurn.text])
        let serialized = fresh.exactMessages.map(\.content).joined(separator: "\n")
        XCTAssertFalse(serialized.contains("old-call-secret"))
    }

    func testOversizedLatestTurnRemainsExactForCompilerOverflowHandling() {
        let runtime = makeRuntime()
        let latest = ConversationTurn(
            id: "oversized",
            role: .user,
            text: String(repeating: "x", count: 40_000),
            createdAt: Date()
        )
        let frozen = runtime.capture(
            turns: [latest],
            callID: UUID(),
            strategy: .efficient,
            capability: capability(8_000),
            userInput: latest.text,
            profilePrompt: "Be concise."
        )
        XCTAssertEqual(frozen.exactMessages.last?.content, latest.text)
    }

    func testLocalOnlyAssistantTaintTravelsWithExactSuffixAndOlderCapsule() throws {
        let runtime = makeRuntime()
        let callID = UUID()
        var turns = makeTurns(prefix: "private", count: 28)
        turns[1] = ConversationTurn(
            id: turns[1].id,
            role: .assistant,
            text: "derived from local-only memory " + String(repeating: "secret ", count: 180),
            createdAt: turns[1].createdAt,
            egress: .localOnly
        )
        turns[turns.count - 2] = ConversationTurn(
            id: turns[turns.count - 2].id,
            role: .assistant,
            text: "recent local-only answer",
            createdAt: turns[turns.count - 2].createdAt,
            egress: .localOnly
        )
        turns[turns.count - 1] = ConversationTurn(
            id: turns[turns.count - 1].id,
            role: .user,
            text: "latest user request",
            createdAt: turns[turns.count - 1].createdAt
        )

        let frozen = runtime.capture(
            turns: turns,
            callID: callID,
            strategy: .efficient,
            capability: capability(8_000),
            userInput: turns.last!.text,
            profilePrompt: "Be concise."
        )

        let recent = try XCTUnwrap(frozen.exactMessageSources.first {
            $0.message.content == "recent local-only answer"
        })
        XCTAssertEqual(recent.egress, .localOnly)
        XCTAssertTrue(frozen.summaryItems.contains { $0.egress == .localOnly })
    }

    func testLocalCapsulesPreserveDecisionsQuestionsCorrectionsAndCommitments() {
        let runtime = makeRuntime()
        var turns = makeTurns(prefix: "ordinary", count: 28)
        turns[0] = ConversationTurn(id: "turn-0", role: .user, text: "Let's use the blue design.", createdAt: Date())
        turns[1] = ConversationTurn(id: "turn-1", role: .assistant, text: "I will update it tomorrow.", createdAt: Date())
        turns[2] = ConversationTurn(id: "turn-2", role: .user, text: "Actually, I meant the green design.", createdAt: Date())
        turns[3] = ConversationTurn(id: "turn-3", role: .assistant, text: "Who should approve it?", createdAt: Date())

        let frozen = runtime.capture(
            turns: turns,
            callID: UUID(),
            strategy: .efficient,
            capability: capability(8_000),
            userInput: turns.last!.text,
            profilePrompt: "Be concise."
        )
        let rendered = frozen.summaryItems.map(\.content).joined(separator: "\n")

        XCTAssertTrue(rendered.contains("Decisions:"))
        XCTAssertTrue(rendered.contains("Corrections"))
        XCTAssertTrue(rendered.contains("Unresolved commitments:"))
        XCTAssertTrue(rendered.contains("Open questions:"))
    }

    func testPrivateCaptureBuildsContinuityWithoutWritingCapsules() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-private-direct-chat-\(UUID().uuidString).sqlite")
        addTeardownBlock {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        let runtime = AttacheDirectChatRuntime(databaseURL: url)
        let turns = makeTurns(prefix: "private-call", count: 28)

        let frozen = runtime.capture(
            turns: turns,
            callID: UUID(),
            strategy: .efficient,
            capability: capability(8_000),
            userInput: turns.last!.text,
            profilePrompt: "Be concise.",
            persistCapsules: false
        )

        XCTAssertFalse(frozen.summaryItems.isEmpty)
        XCTAssertTrue(
            AttacheDirectChatSummaryStore(databaseURL: url).list(activeOnly: false).isEmpty
        )
    }

    private func makeRuntime() -> AttacheDirectChatRuntime {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-direct-chat-test-\(UUID().uuidString).sqlite")
        addTeardownBlock {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        return AttacheDirectChatRuntime(databaseURL: url)
    }

    private func capability(_ tokens: Int) -> AttacheModelCapabilityProfile {
        AttacheModelCapabilityProfile(
            architecturalMaximum: tokens,
            outputLimit: 1_024,
            confidence: .authoritative,
            provenance: .providerMetadata
        )
    }

    private func makeTurns(prefix: String, count: Int) -> [ConversationTurn] {
        (0..<count).map { index in
            ConversationTurn(
                id: "turn-\(index)",
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "\(prefix)-\(index) " + String(repeating: "context ", count: 180),
                createdAt: Date(timeIntervalSince1970: Double(index))
            )
        }
    }
}
