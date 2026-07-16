import Foundation

/// The opt-in memory proposal mode (INF-324). Existing users upgrade to Off;
/// fresh users choose during onboarding; skipping leaves it Off.
public enum AttacheMemoryProposalMode: String, Equatable, Sendable, Codable {
    case off
    case suggest
    case automatic

    /// True when any proposals or writes are allowed (INF-324).
    public var allowsProposals: Bool { self != .off }

    /// True when low-sensitivity high-confidence facts may auto-persist
    /// (INF-324). Sensitive or ambiguous items still require confirmation.
    public var allowsAutomaticWrite: Bool { self == .automatic }
}

/// A proposed memory record before acceptance (INF-324). The model proposes;
/// local policy decides whether anything is stored. Carries provenance so the
/// user can review where it came from.
public struct AttacheMemoryProposal: Codable, Equatable, Sendable {
    public let id: String
    public let statement: String
    public let type: AttacheMemoryType
    public let scope: AttacheMemoryScope
    public let sourceKind: AttacheMemorySourceKind
    public let sourceLocator: String?
    public let confidence: AttacheCapabilityConfidence
    public let sensitivity: AttacheMemorySensitivity
    public let egress: AttacheMemoryEgress
    public let requiresConfirmation: Bool

    public init(
        id: String, statement: String, type: AttacheMemoryType,
        scope: AttacheMemoryScope = .global,
        sourceKind: AttacheMemorySourceKind = .modelProposed,
        sourceLocator: String? = nil,
        confidence: AttacheCapabilityConfidence = .inferred,
        sensitivity: AttacheMemorySensitivity = .low,
        egress: AttacheMemoryEgress = .localOnly,
        requiresConfirmation: Bool = true
    ) {
        self.id = id
        self.statement = statement
        self.type = type
        self.scope = scope
        self.sourceKind = sourceKind
        self.sourceLocator = sourceLocator
        self.confidence = confidence
        self.sensitivity = sensitivity
        self.egress = egress
        self.requiresConfirmation = requiresConfirmation
    }
}

/// A typed proposal rejection reason (INF-324).
public enum AttacheMemoryProposalRejection: String, Equatable, Sendable {
    case secret
    case credential
    case financialAccount
    case privateReasoning
    case transientMood
    case guess
    case inferredProtectedTrait
    case medicalLegal
    case sessionContentNotRestated
    case duplicate
    case modeOff
}

/// The disposition of a proposal (INF-324).
public enum AttacheMemoryProposalDisposition: Equatable, Sendable {
    case queuedForReview
    case autoStored(record: AttacheMemoryRecord)
    case rejected(reason: AttacheMemoryProposalRejection)
    case ignored
}

/// A review queue item (INF-324). The user can edit, accept, reject, forget,
/// or undo.
public struct AttacheMemoryReviewItem: Equatable, Sendable {
    public let proposal: AttacheMemoryProposal
    public let disposition: AttacheMemoryProposalDisposition

    public init(proposal: AttacheMemoryProposal, disposition: AttacheMemoryProposalDisposition) {
        self.proposal = proposal
        self.disposition = disposition
    }
}

/// The pure proposal validator (INF-324). Rejects secrets, credentials,
/// financial account data, private reasoning, transient moods, guesses,
/// inferred protected traits, medical/legal conclusions, and work-session
/// content not explicitly restated by the user.
public enum AttacheMemoryProposalValidator {

    public static let secretPatterns = AttacheMemorySecretFilter.secretPatterns
    public static let protectedTraitMarkers = ["autistic", "adhd", "depressed", "anxiety", "bipolar",
                                                "disabled", "lgbt", "gay", "trans", "religion", "political"]
    public static let transientMarkers = ["today i feel", "right now", "at this moment",
                                           "temporarily", "just for today", "mood"]
    public static let medicalLegalMarkers = ["diagnosis", "prescribed", "lawsuit", "sued",
                                              "medical condition", "legal advice", "attorney"]
    public static let financialMarkers = ["account number", "routing number", "credit card",
                                           "bank account", "ssn", "social security"]

    /// Validate a proposal (INF-324). Returns a rejection reason if the
    /// proposal must not be stored, or nil if it passes validation.
    public static func validate(_ proposal: AttacheMemoryProposal) -> AttacheMemoryProposalRejection? {
        let lower = proposal.statement.lowercased()
        // Financial account data gets its precise reason before the broader
        // secret filter, including unlabeled SSNs, cards, routing numbers, and
        // IBANs detected structurally.
        if financialMarkers.contains(where: { lower.contains($0) })
            || AttacheMemorySecretFilter.containsFinancialAccountData(proposal.statement) {
            return .financialAccount
        }
        // Secrets and credentials.
        if AttacheMemorySecretFilter.shouldReject(proposal.statement) {
            return secretPatterns.contains { lower.contains($0) } ? .credential : .secret
        }
        // Inferred protected traits.
        if protectedTraitMarkers.contains(where: { lower.contains($0) }) {
            // Only reject if it's inferred/guessed, not if the user stated it.
            if proposal.confidence == .inferred || proposal.confidence == .guessed {
                return .inferredProtectedTrait
            }
        }
        // Transient moods.
        if transientMarkers.contains(where: { lower.contains($0) }) { return .transientMood }
        // Medical/legal conclusions.
        if medicalLegalMarkers.contains(where: { lower.contains($0) }) { return .medicalLegal }
        // Private reasoning.
        if lower.contains("i think the agent") || lower.contains("the model should") {
            return .privateReasoning
        }
        // Guesses.
        if proposal.confidence == .guessed { return .guess }
        // Work-session content not restated.
        if lower.contains("the agent said") || lower.contains("from the transcript") {
            return .sessionContentNotRestated
        }
        return nil
    }
}

/// The pure proposal processor (INF-324). Decides what happens to a proposal
/// based on the mode and validation. Off mode: nothing. Suggest mode: queue
/// for review. Automatic mode: persist low-sensitivity high-confidence,
/// sensitive/ambiguous still require confirmation.
public enum AttacheMemoryProposalProcessor {

    /// Process a proposal according to the mode (INF-324).
    public static func process(
        _ proposal: AttacheMemoryProposal,
        mode: AttacheMemoryProposalMode,
        existingRecords: [AttacheMemoryRecord]
    ) -> AttacheMemoryProposalDisposition {
        // Off: no proposals, no writes.
        guard mode.allowsProposals else { return .ignored }

        // Validate first, regardless of mode.
        if let rejection = AttacheMemoryProposalValidator.validate(proposal) {
            return .rejected(reason: rejection)
        }

        // Check for duplicates against existing active records.
        if isDuplicate(proposal, existing: existingRecords) {
            return .rejected(reason: .duplicate)
        }

        // Suggest: always queue for review.
        if mode == .suggest {
            return .queuedForReview
        }

        // Automatic: persist low-sensitivity high-confidence.
        // Sensitive or ambiguous still require confirmation.
        if mode == .automatic {
            // A model can propose a memory but can never authorize its own
            // durable write, even if it marks the proposal authoritative or
            // clears a confirmation flag. Automatic writes are limited to
            // explicit user-originated records that do not require review.
            if !proposal.requiresConfirmation,
               proposal.sourceKind != .modelProposed,
               proposal.sensitivity == .low,
               proposal.confidence == .authoritative {
                let record = AttacheMemoryRecord(
                    id: proposal.id, statement: proposal.statement,
                    type: proposal.type, scope: proposal.scope,
                    sourceKind: proposal.sourceKind, sourceLocator: proposal.sourceLocator,
                    confidence: proposal.confidence, sensitivity: proposal.sensitivity,
                    egress: proposal.egress
                )
                return .autoStored(record: record)
            }
            // Sensitive or ambiguous: still needs confirmation.
            return .queuedForReview
        }

        return .queuedForReview
    }

    /// True when the proposal duplicates an existing active record (INF-324).
    public static func isDuplicate(
        _ proposal: AttacheMemoryProposal, existing: [AttacheMemoryRecord]
    ) -> Bool {
        existing.contains { record in
            record.status == .active
                && AttacheMemorySelector.lexicalOverlap(record.statement, proposal.statement) > 0.85
        }
    }
}

/// The pure memory consolidator (INF-324). Consolidates duplicates through
/// supersession, not destructive rewriting. Detects contradictions and decays
/// confidence for stale time-sensitive facts.
public enum AttacheMemoryConsolidator {

    /// Detect duplicate active records and produce supersession actions
    /// (INF-324). Duplicates are superseded, not deleted.
    public static func detectDuplicates(_ records: [AttacheMemoryRecord]) -> [(supersede: String, by: String)] {
        let active = records.filter { $0.status == .active }
        var actions: [(String, String)] = []
        var seen: Set<String> = []
        for i in 0..<active.count {
            if seen.contains(active[i].id) { continue }
            for j in (i+1)..<active.count {
                if seen.contains(active[j].id) { continue }
                if AttacheMemorySelector.lexicalOverlap(active[i].statement, active[j].statement) > 0.85 {
                    // Supersede the older one with the newer one.
                    let (older, newer) = active[i].updatedAt < active[j].updatedAt
                        ? (active[i], active[j])
                        : (active[j], active[i])
                    actions.append((supersede: older.id, by: newer.id))
                    seen.insert(older.id)
                }
            }
        }
        return actions
    }

    /// Detect contradictions among active records (INF-324). Contradictions
    /// are surfaced for user review, not silently resolved.
    public static func detectContradictions(_ records: [AttacheMemoryRecord]) -> [(groupID: String, recordIDs: [String])] {
        let active = records.filter { $0.status == .active }
        var groups: [(String, [String])] = []
        var used: Set<String> = []
        for i in 0..<active.count {
            if used.contains(active[i].id) { continue }
            var group: [AttacheMemoryRecord] = [active[i]]
            for j in (i+1)..<active.count {
                if used.contains(active[j].id) { continue }
                let overlap = AttacheMemorySelector.lexicalOverlap(
                    AttacheMemorySelector.removingNegation(from: active[i].statement),
                    AttacheMemorySelector.removingNegation(from: active[j].statement)
                )
                if overlap >= 0.4,
                   AttacheMemorySelector.hasNegation(active[i].statement)
                    != AttacheMemorySelector.hasNegation(active[j].statement) {
                    group.append(active[j])
                    used.insert(active[j].id)
                }
            }
            if group.count > 1 {
                let groupID = "contradiction-\(active[i].id)"
                used.insert(active[i].id)
                groups.append((groupID, group.map { $0.id }))
            }
        }
        return groups
    }

    /// Decay confidence for stale time-sensitive records (INF-324). A reminder
    /// or time-sensitive fact whose updatedAt is older than the threshold
    /// should be flagged for review.
    public static func detectStaleTimeSensitive(
        _ records: [AttacheMemoryRecord],
        maxAgeDays: Double = 30,
        now: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> [String] {
        records.filter { record in
            record.status == .active
                && (record.type == .reminder || record.type == .projectTopic)
                && now.timeIntervalSince(record.updatedAt) > maxAgeDays * 86_400
        }.map { $0.id }
    }
}

/// The undo support (INF-324). Corrections supersede old facts and can be
/// undone by restoring the superseded record.
public enum AttacheMemoryUndo {

    /// Undo a supersession by restoring the superseded record (INF-324).
    public static func undoSupersede(
        supersededID: String, records: [AttacheMemoryRecord]
    ) -> AttacheMemoryRecord? {
        guard let record = records.first(where: { $0.id == supersededID }) else { return nil }
        return AttacheMemoryRecord(
            id: record.id, statement: record.statement, type: record.type,
            scope: record.scope, sourceKind: record.sourceKind,
            sourceLocator: record.sourceLocator, confidence: record.confidence,
            sensitivity: record.sensitivity, egress: record.egress,
            createdAt: record.createdAt, updatedAt: record.updatedAt,
            lastUsedAt: record.lastUsedAt, status: .active, supersededByID: nil
        )
    }
}
