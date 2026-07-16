import AttacheCore
import Foundation

/// The direct-chat material frozen into one request. Exact recent turns retain
/// their roles; older turns become locally generated, untrusted context items.
/// Both collections are scoped to one call ID.
struct AttacheDirectChatSnapshotContext: Equatable {
    let exactMessages: [AttacheChatMessage]
    let exactMessageSources: [AttachePrebuiltMessageSource]
    let summaryItems: [AttacheContextItem]
    let plan: AttacheDirectChatSummaryPlan
}

/// Production adapter for INF-316's pure summary planner and SQLite store.
/// Summary generation is deliberately local and extractive, so maintaining a
/// long voice conversation never creates a hidden model request or new egress.
final class AttacheDirectChatRuntime {
    static let localSummarizerIdentity = "attache.local-direct-chat-summary.v2"
    private static let excerptCharacterLimit = 320

    private let store: AttacheDirectChatSummaryStore
    private let estimator = AttacheFallbackTokenEstimator()

    init(databaseURL: URL) {
        store = AttacheDirectChatSummaryStore(databaseURL: databaseURL)
        // App restart is a hard call boundary. A crash or force-quit cannot run
        // the normal endCall cleanup, so remove every orphaned extractive
        // capsule before this process can serve a new conversation.
        store.deleteAll()
    }

    /// A hang-up is a hard context boundary. Capsules are useful only inside
    /// their originating call, so erase them immediately instead of retaining
    /// hidden conversation excerpts that can never be reused.
    func endCall(_ callID: UUID) {
        _ = store.delete(callID: callID.uuidString)
    }

    func capture(
        turns: [ConversationTurn],
        callID: UUID,
        strategy: AttacheContextStrategy,
        capability: AttacheModelCapabilityProfile,
        userInput: String,
        profilePrompt: String
    ) -> AttacheDirectChatSnapshotContext {
        let callIDString = callID.uuidString
        let egressByTurnID = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0.egress) })
        let frozenTurns = turns.enumerated().map { index, turn in
            AttacheDirectChatTurn(
                id: turn.id,
                role: turn.role == .user ? .user : .attache,
                content: turn.text,
                turnIndex: index,
                callID: callIDString
            )
        }
        let suffixBudget = Self.suffixBudget(
            strategy: strategy,
            capability: capability,
            userInput: userInput,
            profilePrompt: profilePrompt,
            estimator: estimator
        )
        let plan = AttacheDirectChatSummaryPlanner.plan(
            turns: frozenTurns,
            strategy: strategy,
            budgetTokens: suffixBudget,
            estimator: estimator
        )

        _ = store.invalidateBySummarizerVersion(
            olderThan: AttacheDirectChatSummaryPlanner.summarizerVersion
        )
        var active = store.list().filter { $0.callID == callIDString }
        let turnByID = Dictionary(uniqueKeysWithValues: frozenTurns.map { ($0.id, $0) })
        var capsules: [AttacheDirectChatSummaryCapsule] = []

        for segment in plan.segmentsToSummarize {
            let segmentTurns = segment.turnIDs.compactMap { turnByID[$0] }
            guard segmentTurns.count == segment.turnIDs.count else { continue }

            let staleHashes = Set(active.compactMap { capsule -> String? in
                guard capsule.segmentID == segment.id,
                      capsule.sourceHash != segment.combinedHash else { return nil }
                return capsule.sourceHash
            })
            if !staleHashes.isEmpty {
                _ = store.invalidateBySourceHashes(staleHashes)
                active.removeAll { staleHashes.contains($0.sourceHash) }
            }

            if let existing = active.first(where: {
                $0.segmentID == segment.id
                    && $0.sourceHash == segment.combinedHash
                    && $0.summarizerVersion == AttacheDirectChatSummaryPlanner.summarizerVersion
            }) {
                capsules.append(existing)
                continue
            }

            let capsule = Self.makeLocalCapsule(
                segment: segment,
                turns: segmentTurns,
                strategy: strategy,
                budgetTokens: suffixBudget
            )
            if store.add(capsule) {
                active.append(capsule)
            }
            capsules.append(capsule)
        }

        let exactIDs = Set(plan.exactSuffixTurnIDs)
        let exactTurns = frozenTurns.filter { exactIDs.contains($0.id) }
        let exactMessages = exactTurns.map {
            AttacheChatMessage(
                role: $0.role == .user ? "user" : "assistant",
                content: $0.content
            )
        }
        let exactMessageSources = zip(exactTurns, exactMessages).map { turn, message in
            AttachePrebuiltMessageSource(
                message: message,
                source: .recentDirectChatTurns,
                egress: egressByTurnID[turn.id] ?? .allowedRemote
            )
        }
        let localOnlySegmentIDs = Set(plan.segmentsToSummarize.compactMap { segment in
            segment.turnIDs.contains { egressByTurnID[$0] == .localOnly } ? segment.id : nil
        })
        let summaryItems = capsules.sorted { $0.startTurnIndex < $1.startTurnIndex }.map {
            AttacheContextItem(
                source: .olderChatSummary,
                content: Self.renderLocalCapsule($0),
                provenance: "direct-chat-capsule:\($0.id)",
                egress: localOnlySegmentIDs.contains($0.segmentID) ? .localOnly : .allowedRemote,
                priority: 650,
                treatment: .headTailExcerpt
            )
        }
        return AttacheDirectChatSnapshotContext(
            exactMessages: exactMessages,
            exactMessageSources: exactMessageSources,
            summaryItems: summaryItems,
            plan: plan
        )
    }

    private static func suffixBudget(
        strategy: AttacheContextStrategy,
        capability: AttacheModelCapabilityProfile,
        userInput: String,
        profilePrompt: String,
        estimator: AttacheFallbackTokenEstimator
    ) -> Int {
        let planned = try? ContextBudgetPlanner.plan(
            capability: capability,
            strategy: strategy,
            role: .conversation,
            currentUserInput: userInput,
            estimator: estimator,
            protectedContentText: profilePrompt
        )
        // Leave room for selected durable memory, focused-session evidence,
        // and provider framing. The planner has already applied the user's
        // strategy multiplier, so this remains monotonic across modes.
        let available = planned?.remainingEvidenceBudget
            ?? ContextBudgetPlanner.unknownCapacityEnvelope / 8
        return max(256, Int(Double(available) * 0.70))
    }

    private static func makeLocalCapsule(
        segment: AttacheDirectChatSegment,
        turns: [AttacheDirectChatTurn],
        strategy: AttacheContextStrategy,
        budgetTokens: Int
    ) -> AttacheDirectChatSummaryCapsule {
        let notes = turns.map { turn in
            let speaker = turn.role == .user ? "User" : "Attaché"
            return "Turn \(turn.turnIndex + 1), \(speaker): \(boundedExcerpt(turn.content))"
        }
        let decisions = turns.compactMap { turn -> String? in
            let lower = turn.content.lowercased()
            let markers = ["we decided", "i decided", "let's ", "lets ", "the decision is", "we'll use"]
            guard markers.contains(where: lower.contains) else { return nil }
            return "Turn \(turn.turnIndex + 1): \(boundedExcerpt(turn.content))"
        }
        let openQuestions = turns.compactMap { turn -> String? in
            guard turn.content.contains("?") else { return nil }
            return "Turn \(turn.turnIndex + 1): \(boundedExcerpt(turn.content))"
        }
        let commitments = turns.compactMap { turn -> String? in
            let lower = turn.content.lowercased()
            let markers = ["i will", "i'll", "we will", "we'll", "need to", "todo", "to-do", "promise"]
            guard markers.contains(where: lower.contains) else { return nil }
            return "Turn \(turn.turnIndex + 1): \(boundedExcerpt(turn.content))"
        }
        var corrections: [AttacheDirectChatCorrection] = []
        for (index, turn) in turns.enumerated() {
            let lower = turn.content.lowercased()
            let markers = ["actually", "correction:", "i meant", "to correct that", "not what i meant"]
            guard markers.contains(where: lower.contains), index > 0 else { continue }
            corrections.append(AttacheDirectChatCorrection(
                turnIndex: turn.turnIndex,
                supersedesClaim: notes[index - 1],
                correctedClaim: notes[index]
            ))
        }
        let receipt = ContextReceipt(
            includedSources: [AttacheContextItemSource.recentDirectChatTurns.rawValue],
            omittedSources: [],
            truncatedSources: [],
            totalEstimatedTokens: AttacheFallbackTokenEstimator().estimate(
                text: notes.joined(separator: "\n")
            ),
            remainingBudget: budgetTokens,
            modelIdentityKey: localSummarizerIdentity,
            strategyKind: strategy.kind.rawValue,
            stagedProcessingRequired: false,
            includedSourceIdentifiers: turns.map { "direct-chat-turn:\($0.id)" }
        )
        let capsuleDigest = AttacheDirectChatTurn.hash(
            "\(segment.callID)|\(segment.id)|\(segment.combinedHash)"
        )
        return AttacheDirectChatSummaryCapsule(
            id: "chat-cap-\(capsuleDigest)",
            segmentID: segment.id,
            startTurnIndex: segment.startTurnIndex,
            endTurnIndex: segment.endTurnIndex,
            sourceHash: segment.combinedHash,
            establishedFacts: notes,
            decisions: decisions,
            openQuestions: openQuestions,
            corrections: corrections,
            unresolvedCommitments: commitments,
            summarizerVersion: AttacheDirectChatSummaryPlanner.summarizerVersion,
            modelIdentityKey: localSummarizerIdentity,
            receipt: receipt,
            createdAt: Date(),
            callID: segment.callID
        )
    }

    private static func renderLocalCapsule(_ capsule: AttacheDirectChatSummaryCapsule) -> String {
        var sections = ["""
        Neutral digest of direct-chat turns \(capsule.startTurnIndex + 1) through \(capsule.endTurnIndex + 1).
        Source hash: \(capsule.sourceHash)
        Conversation notes:
        \(capsule.establishedFacts.joined(separator: "\n"))
        """]
        if !capsule.decisions.isEmpty {
            sections.append("Decisions:\n" + capsule.decisions.joined(separator: "\n"))
        }
        if !capsule.openQuestions.isEmpty {
            sections.append("Open questions:\n" + capsule.openQuestions.joined(separator: "\n"))
        }
        if !capsule.corrections.isEmpty {
            sections.append("Corrections (later text supersedes the cited prior note):\n" + capsule.corrections.map {
                "Turn \($0.turnIndex + 1): \($0.correctedClaim)"
            }.joined(separator: "\n"))
        }
        if !capsule.unresolvedCommitments.isEmpty {
            sections.append("Unresolved commitments:\n" + capsule.unresolvedCommitments.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n")
    }

    private static func boundedExcerpt(_ content: String) -> String {
        let collapsed = content
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > excerptCharacterLimit else { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: excerptCharacterLimit)
        return String(collapsed[..<end]) + "…"
    }
}
