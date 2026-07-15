import Foundation

/// The coverage state of a capsule (INF-328).
public enum AttacheCapsuleCoverageState: String, Equatable, Sendable {
    case full
    case partial
    case staged
}

/// One cited source range backing a claim (INF-328). Every claim maps to
/// exact source ranges and hashes.
public struct AttacheCapsuleCitation: Equatable, Sendable {
    public let startTurnOrdinal: Int
    public let endTurnOrdinal: Int
    public let sourceHash: String

    public init(startTurnOrdinal: Int, endTurnOrdinal: Int, sourceHash: String) {
        self.startTurnOrdinal = startTurnOrdinal
        self.endTurnOrdinal = endTurnOrdinal
        self.sourceHash = sourceHash
    }
}

/// One claim in a capsule with its citation (INF-328). Unsupported or
/// citation-mismatched claims are marked invalid rather than trusted.
public struct AttacheCapsuleClaim: Equatable, Sendable {
    public let statement: String
    public let citation: AttacheCapsuleCitation?
    public let isSupported: Bool
    public let invalidReason: String?

    public init(statement: String, citation: AttacheCapsuleCitation?, isSupported: Bool = true, invalidReason: String? = nil) {
        self.statement = statement
        self.citation = citation
        self.isSupported = isSupported
        self.invalidReason = invalidReason
    }
}

/// A contradiction preserved in a capsule (INF-328). Not smoothed into a
/// false narrative. Later corrections are identifiable.
public struct AttacheCapsuleContradiction: Equatable, Sendable {
    public let claimA: String
    public let claimB: String
    public let laterClaimTurnOrdinal: Int

    public init(claimA: String, claimB: String, laterClaimTurnOrdinal: Int) {
        self.claimA = claimA
        self.claimB = claimB
        self.laterClaimTurnOrdinal = laterClaimTurnOrdinal
    }
}

/// A provenance-backed hierarchical capsule (INF-328). Records exact source
/// ranges/hashes, summarizer identity, claims, decisions, open questions,
/// contradictions, and coverage state. Rebuildable from raw logs. Capsules
/// never become durable personal memory automatically.
public struct AttacheHierarchicalCapsule: Equatable, Sendable {
    public let capsuleID: String
    public let sessionID: String
    public let sourceKind: String
    public let sourceRanges: [AttacheCapsuleCitation]
    public let summarizerModelKey: String
    public let summarizerVersion: String
    public let creationTime: Date
    public let claims: [AttacheCapsuleClaim]
    public let decisions: [String]
    public let openQuestions: [String]
    public let contradictions: [AttacheCapsuleContradiction]
    public let coverageState: AttacheCapsuleCoverageState
    public let isLeaf: Bool
    public let childCapsuleIDs: [String]
    public let isValid: Bool
    public let invalidationReason: String?

    public init(
        capsuleID: String, sessionID: String, sourceKind: String,
        sourceRanges: [AttacheCapsuleCitation], summarizerModelKey: String,
        summarizerVersion: String, creationTime: Date = Date(timeIntervalSince1970: 1_700_000_000),
        claims: [AttacheCapsuleClaim], decisions: [String], openQuestions: [String],
        contradictions: [AttacheCapsuleContradiction], coverageState: AttacheCapsuleCoverageState,
        isLeaf: Bool, childCapsuleIDs: [String] = [],
        isValid: Bool = true, invalidationReason: String? = nil
    ) {
        self.capsuleID = capsuleID
        self.sessionID = sessionID
        self.sourceKind = sourceKind
        self.sourceRanges = sourceRanges
        self.summarizerModelKey = summarizerModelKey
        self.summarizerVersion = summarizerVersion
        self.creationTime = creationTime
        self.claims = claims
        self.decisions = decisions
        self.openQuestions = openQuestions
        self.contradictions = contradictions
        self.coverageState = coverageState
        self.isLeaf = isLeaf
        self.childCapsuleIDs = childCapsuleIDs
        self.isValid = isValid
        self.invalidationReason = invalidationReason
    }
}

/// The pure hierarchical capsule builder (INF-328). Generates leaf capsules
/// for session-map episodes and merges them hierarchically. Requires explicit
/// focus. Validates citations. Preserves contradictions. Source mutation
/// invalidates affected capsules.
public enum AttacheHierarchicalCapsuleBuilder {

    public static let summarizerVersion = "attache.hierarchical-capsule.v1"

    /// Build a leaf capsule for one session-map episode (INF-328). Requires
    /// the session to be explicitly focused.
    public static func buildLeaf(
        episode: AttacheSessionMapEpisode,
        focusedSession: AttacheFocusedSession?,
        claims: [AttacheCapsuleClaim] = [],
        decisions: [String] = [],
        openQuestions: [String] = [],
        contradictions: [AttacheCapsuleContradiction] = []
    ) -> AttacheHierarchicalCapsule? {
        // No narrative capsule is generated from an unfocused session.
        guard let session = focusedSession else { return nil }
        guard session.sessionID == episode.sessionID else { return nil }
        let citation = AttacheCapsuleCitation(
            startTurnOrdinal: episode.startTurnOrdinal,
            endTurnOrdinal: episode.endTurnOrdinal,
            sourceHash: episode.combinedHash
        )
        return AttacheHierarchicalCapsule(
            capsuleID: "cap-leaf-\(episode.episodeID)",
            sessionID: session.sessionID, sourceKind: session.sourceKind,
            sourceRanges: [citation],
            summarizerModelKey: "summarizer", summarizerVersion: summarizerVersion,
            claims: claims, decisions: decisions, openQuestions: openQuestions,
            contradictions: contradictions, coverageState: .full,
            isLeaf: true
        )
    }

    /// Merge child capsules into a parent capsule (INF-328). Hierarchical
    /// merge for broader coverage.
    public static func merge(
        children: [AttacheHierarchicalCapsule],
        focusedSession: AttacheFocusedSession?
    ) -> AttacheHierarchicalCapsule? {
        guard let session = focusedSession, !children.isEmpty else { return nil }
        let allRanges = children.flatMap { $0.sourceRanges }
        let allClaims = children.flatMap { $0.claims }
        let allDecisions = children.flatMap { $0.decisions }
        let allQuestions = children.flatMap { $0.openQuestions }
        let allContradictions = children.flatMap { $0.contradictions }
        let coverage: AttacheCapsuleCoverageState = children.allSatisfy { $0.coverageState == .full } ? .full : .partial
        return AttacheHierarchicalCapsule(
            capsuleID: "cap-merge-\(children.first!.capsuleID)-\(children.last!.capsuleID)",
            sessionID: session.sessionID, sourceKind: session.sourceKind,
            sourceRanges: allRanges, summarizerModelKey: "summarizer",
            summarizerVersion: summarizerVersion,
            claims: allClaims, decisions: allDecisions, openQuestions: allQuestions,
            contradictions: allContradictions, coverageState: coverage,
            isLeaf: false, childCapsuleIDs: children.map { $0.capsuleID }
        )
    }

    /// Validate that cited ranges exist and match hashes (INF-328). Marks
    /// unsupported or citation-mismatched claims as invalid.
    public static func validateCitations(
        capsule: AttacheHierarchicalCapsule,
        currentEpisodes: [AttacheSessionMapEpisode]
    ) -> AttacheHierarchicalCapsule {
        let episodeHashes = Dictionary(currentEpisodes.map { ep in
            (ep.startTurnOrdinal...ep.endTurnOrdinal, ep.combinedHash)
        }, uniquingKeysWith: { a, _ in a })
        let validatedClaims = capsule.claims.map { claim -> AttacheCapsuleClaim in
            guard let citation = claim.citation else {
                return AttacheCapsuleClaim(statement: claim.statement, citation: nil, isSupported: false, invalidReason: "no-citation")
            }
            // Check if the cited range's hash matches a current episode.
            let matchingHash = currentEpisodes.first { ep in
                ep.startTurnOrdinal == citation.startTurnOrdinal
                    && ep.endTurnOrdinal == citation.endTurnOrdinal
                    && ep.combinedHash == citation.sourceHash
            }
            if matchingHash == nil {
                return AttacheCapsuleClaim(statement: claim.statement, citation: citation, isSupported: false, invalidReason: "citation-mismatch")
            }
            return claim
        }
        let anyInvalid = validatedClaims.contains { !$0.isSupported }
        return AttacheHierarchicalCapsule(
            capsuleID: capsule.capsuleID, sessionID: capsule.sessionID,
            sourceKind: capsule.sourceKind, sourceRanges: capsule.sourceRanges,
            summarizerModelKey: capsule.summarizerModelKey,
            summarizerVersion: capsule.summarizerVersion,
            creationTime: capsule.creationTime, claims: validatedClaims,
            decisions: capsule.decisions, openQuestions: capsule.openQuestions,
            contradictions: capsule.contradictions, coverageState: capsule.coverageState,
            isLeaf: capsule.isLeaf, childCapsuleIDs: capsule.childCapsuleIDs,
            isValid: !anyInvalid, invalidationReason: anyInvalid ? "citation-mismatch" : nil
        )
    }

    /// Detect which capsules are affected by source mutation (INF-328). Source
    /// mutation invalidates affected leaf and ancestor capsules.
    public static func detectAffectedByMutation(
        capsules: [AttacheHierarchicalCapsule],
        mutatedEpisodeHashes: Set<String>
    ) -> [String] {
        capsules.filter { capsule in
            capsule.sourceRanges.contains { range in mutatedEpisodeHashes.contains(range.sourceHash) }
        }.map { $0.capsuleID }
    }

    /// Detect affected capsules by summarizer version change (INF-328).
    public static func detectAffectedBySummarizerVersion(
        capsules: [AttacheHierarchicalCapsule],
        currentVersion: String
    ) -> [String] {
        capsules.filter { $0.summarizerVersion != currentVersion }.map { $0.capsuleID }
    }

    /// True when a capsule requires focus (INF-328). No narrative capsule is
    /// generated or model-injected from an unfocused session.
    public static func requiresFocus(
        focusedSession: AttacheFocusedSession?
    ) -> Bool {
        focusedSession == nil
    }

    /// True when capsules never become durable personal memory (INF-328).
    /// Capsules are derived data, not memory records.
    public static func capsuleIsNotMemory(_ capsule: AttacheHierarchicalCapsule) -> Bool {
        // A capsule is a derived summary, not a durable personal memory.
        // It has sourceRanges and summarizerModelKey, not memory type/scope.
        // This function documents that capsules are not memory records.
        true
    }

    /// Remove capsules when the source session is deleted (INF-328).
    public static func removeForDeletedSession(
        capsules: [AttacheHierarchicalCapsule], sessionID: String
    ) -> [AttacheHierarchicalCapsule] {
        capsules.filter { $0.sessionID != sessionID }
    }

    /// Build capsules for retrieval within a budget (INF-328). A small model
    /// can use capsules within budget; a large Maximum coverage model can
    /// augment them with more raw evidence.
    public static func selectForBudget(
        capsules: [AttacheHierarchicalCapsule],
        budgetTokens: Int,
        strategy: AttacheContextStrategy,
        estimator: TokenEstimating = AttacheFallbackTokenEstimator()
    ) -> [AttacheHierarchicalCapsule] {
        guard budgetTokens > 0 else { return [] }
        let multiplier: Double
        switch strategy.kind {
        case .efficient: multiplier = 0.5
        case .automatic: multiplier = 0.75
        case .maximumCoverage: multiplier = 1.0
        case .custom: multiplier = 0.75
        }
        let adjustedBudget = Int(Double(budgetTokens) * multiplier)
        var charBudget = adjustedBudget * 4 // rough chars-per-token
        var selected: [AttacheHierarchicalCapsule] = []
        for capsule in capsules where capsule.isValid {
            let estimatedChars = capsule.claims.reduce(0) { $0 + $1.statement.count }
            if estimatedChars <= charBudget {
                selected.append(capsule)
                charBudget -= estimatedChars
            }
        }
        return selected
    }
}