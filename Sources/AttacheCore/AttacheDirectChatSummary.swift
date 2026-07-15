import Foundation
import CryptoKit
import SQLite3

/// One turn in a direct Attaché conversation (INF-316). The raw card is the
/// local source of truth; summaries are derived from turns and invalidated
/// when a turn's content hash changes.
public struct AttacheDirectChatTurn: Equatable, Sendable {
    public enum Role: String, Equatable, Sendable {
        case user
        case attache
    }

    public let id: String
    public let role: Role
    public let content: String
    public let turnIndex: Int
    public let contentHash: String

    public init(id: String, role: Role, content: String, turnIndex: Int) {
        self.id = id
        self.role = role
        self.content = content
        self.turnIndex = turnIndex
        self.contentHash = AttacheDirectChatTurn.hash(content)
    }

    public static func hash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A correction that supersedes an older claim (INF-316). Later corrections
/// win over older summary claims. The exact recent correction is always
/// preferred over the older capsule.
public struct AttacheDirectChatCorrection: Equatable, Sendable {
    public let turnIndex: Int
    public let supersedesClaim: String
    public let correctedClaim: String

    public init(turnIndex: Int, supersedesClaim: String, correctedClaim: String) {
        self.turnIndex = turnIndex
        self.supersedesClaim = supersedesClaim
        self.correctedClaim = correctedClaim
    }
}

/// A stable segment of a direct conversation (INF-316). A contiguous turn
/// range with a combined content hash so a capsule can be invalidated when any
/// source turn changes.
public struct AttacheDirectChatSegment: Equatable, Sendable {
    public let id: String
    public let startTurnIndex: Int
    public let endTurnIndex: Int
    public let turnIDs: [String]
    public let combinedHash: String

    public init(id: String, startTurnIndex: Int, endTurnIndex: Int, turnIDs: [String]) {
        self.id = id
        self.startTurnIndex = startTurnIndex
        self.endTurnIndex = endTurnIndex
        self.turnIDs = turnIDs
        self.combinedHash = AttacheDirectChatTurn.hash(turnIDs.joined(separator: "|"))
    }
}

/// A neutral, provenance-backed summary capsule of one segment (INF-316).
/// Captures established facts, decisions, open questions, corrections, and
/// unresolved commitments. Neutral tone: never in a personality's voice, never
/// leaking another personality's prompt. Separate from durable personal
/// memory: a conversational detail does not become a remembered fact merely
/// because it appears here.
public struct AttacheDirectChatSummaryCapsule: Equatable, Sendable {
    public let id: String
    public let segmentID: String
    public let startTurnIndex: Int
    public let endTurnIndex: Int
    public let sourceHash: String
    public let establishedFacts: [String]
    public let decisions: [String]
    public let openQuestions: [String]
    public let corrections: [AttacheDirectChatCorrection]
    public let unresolvedCommitments: [String]
    public let summarizerVersion: String
    public let modelIdentityKey: String
    public let receipt: ContextReceipt
    public let createdAt: Date
    public let invalidated: Bool

    public init(
        id: String, segmentID: String, startTurnIndex: Int, endTurnIndex: Int,
        sourceHash: String, establishedFacts: [String], decisions: [String],
        openQuestions: [String], corrections: [AttacheDirectChatCorrection],
        unresolvedCommitments: [String], summarizerVersion: String,
        modelIdentityKey: String, receipt: ContextReceipt,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000), invalidated: Bool = false
    ) {
        self.id = id
        self.segmentID = segmentID
        self.startTurnIndex = startTurnIndex
        self.endTurnIndex = endTurnIndex
        self.sourceHash = sourceHash
        self.establishedFacts = establishedFacts
        self.decisions = decisions
        self.openQuestions = openQuestions
        self.corrections = corrections
        self.unresolvedCommitments = unresolvedCommitments
        self.summarizerVersion = summarizerVersion
        self.modelIdentityKey = modelIdentityKey
        self.receipt = receipt
        self.createdAt = createdAt
        self.invalidated = invalidated
    }
}

/// The plan for compiling a long direct conversation (INF-316). Strategy-
/// dependent: Maximum coverage keeps more raw recent turns; Efficient relies
/// on capsules sooner. Falls back to a bounded exact suffix with a visible
/// continuity limitation when summarization is unavailable.
public struct AttacheDirectChatSummaryPlan: Equatable, Sendable {
    public let exactSuffixStartIndex: Int
    public let segmentsToSummarize: [AttacheDirectChatSegment]
    public let strategyKind: AttacheContextStrategyKind
    public let fallbackBounded: Bool
    public let continuityLimitationNote: String?

    public init(
        exactSuffixStartIndex: Int,
        segmentsToSummarize: [AttacheDirectChatSegment],
        strategyKind: AttacheContextStrategyKind,
        fallbackBounded: Bool = false,
        continuityLimitationNote: String? = nil
    ) {
        self.exactSuffixStartIndex = exactSuffixStartIndex
        self.segmentsToSummarize = segmentsToSummarize
        self.strategyKind = strategyKind
        self.fallbackBounded = fallbackBounded
        self.continuityLimitationNote = continuityLimitationNote
    }
}

/// The pure rolling-summary planner (INF-316). Decides which turns stay exact
/// and which segments summarize, based on the strategy and the budget. The
/// raw cards remain the source of truth; this only plans the compiled view.
public enum AttacheDirectChatSummaryPlanner {

    public static let summarizerVersion = "attache.direct-chat.summary.v1"
    public static let segmentSize = 8

    /// Plan a compiled view of the conversation (INF-316). The exact suffix
    /// length scales with strategy: Maximum keeps more raw turns, Efficient
    /// keeps fewer and relies on capsules sooner. When the conversation fits
    /// entirely within the suffix budget, no segments are summarized.
    public static func plan(
        turns: [AttacheDirectChatTurn],
        strategy: AttacheContextStrategy,
        budgetTokens: Int,
        estimator: TokenEstimating = AttacheFallbackTokenEstimator()
    ) -> AttacheDirectChatSummaryPlan {
        guard !turns.isEmpty else {
            return AttacheDirectChatSummaryPlan(
                exactSuffixStartIndex: 0, segmentsToSummarize: [],
                strategyKind: strategy.kind
            )
        }
        let suffixMultiplier: Double
        switch strategy.kind {
        case .maximumCoverage: suffixMultiplier = 1.0
        case .automatic: suffixMultiplier = 0.75
        case .efficient: suffixMultiplier = 0.5
        case .custom: suffixMultiplier = 0.75
        }
        // The exact suffix is the most recent turns that fit within the
        // strategy-scaled suffix budget. Older turns become segments.
        let suffixBudget = Int(Double(budgetTokens) * suffixMultiplier)
        var suffixStart = turns.count
        var suffixTokens = 0
        for i in stride(from: turns.count - 1, through: 0, by: -1) {
            let tokens = estimator.estimate(text: turns[i].content)
            if suffixTokens + tokens > suffixBudget {
                break
            }
            suffixTokens += tokens
            suffixStart = i
        }
        // Older turns before the suffix become segments of segmentSize each.
        let olderTurns = Array(turns[0..<suffixStart])
        let segments = makeSegments(from: olderTurns, segmentSize: segmentSize)
        return AttacheDirectChatSummaryPlan(
            exactSuffixStartIndex: suffixStart,
            segmentsToSummarize: segments,
            strategyKind: strategy.kind
        )
    }

    /// Fallback plan when summarization is unavailable (INF-316). A bounded
    /// exact suffix with a visible continuity limitation note, never an
    /// unbudgeted request.
    public static func fallbackPlan(
        turns: [AttacheDirectChatTurn],
        budgetTokens: Int,
        estimator: TokenEstimating = AttacheFallbackTokenEstimator()
    ) -> AttacheDirectChatSummaryPlan {
        guard !turns.isEmpty else {
            return AttacheDirectChatSummaryPlan(
                exactSuffixStartIndex: 0, segmentsToSummarize: [],
                strategyKind: .automatic, fallbackBounded: true,
                continuityLimitationNote: "Summarization unavailable. Showing a bounded recent suffix only."
            )
        }
        var suffixStart = turns.count
        var suffixTokens = 0
        for i in stride(from: turns.count - 1, through: 0, by: -1) {
            let tokens = estimator.estimate(text: turns[i].content)
            if suffixTokens + tokens > budgetTokens {
                break
            }
            suffixTokens += tokens
            suffixStart = i
        }
        return AttacheDirectChatSummaryPlan(
            exactSuffixStartIndex: suffixStart,
            segmentsToSummarize: [],
            strategyKind: .automatic,
            fallbackBounded: true,
            continuityLimitationNote: "Summarization unavailable. Older turns before the suffix are not included."
        )
    }

    static func makeSegments(from turns: [AttacheDirectChatTurn], segmentSize: Int) -> [AttacheDirectChatSegment] {
        guard !turns.isEmpty else { return [] }
        var segments: [AttacheDirectChatSegment] = []
        var idx = 0
        while idx < turns.count {
            let end = min(idx + segmentSize, turns.count)
            let slice = Array(turns[idx..<end])
            let segment = AttacheDirectChatSegment(
                id: "seg-\(slice.first!.turnIndex)-\(slice.last!.turnIndex)",
                startTurnIndex: slice.first!.turnIndex,
                endTurnIndex: slice.last!.turnIndex,
                turnIDs: slice.map { $0.id }
            )
            segments.append(segment)
            idx = end
        }
        return segments
    }
}

/// The pure summary compiler (INF-316). Builds the model-facing summary text
/// from capsules and the exact suffix. Applies corrections so later
/// corrections supersede older claims. Never mixes work-session transcript
/// evidence unless the user explicitly quoted it in the direct chat. A
/// personality switch does not rewrite history in the new tone or leak
/// another prompt: capsules are neutral.
public enum AttacheDirectChatSummaryCompiler {

    /// Build the compiled summary view (INF-316). Capsules first (oldest to
    /// newest), then the exact suffix turns. Corrections from later turns
    /// supersede earlier capsule claims.
    public static func compile(
        capsules: [AttacheDirectChatSummaryCapsule],
        exactSuffixTurns: [AttacheDirectChatTurn],
        plan: AttacheDirectChatSummaryPlan
    ) -> [AttacheChatMessage] {
        var messages: [AttacheChatMessage] = []
        // Capsules in order. Each becomes a neutral system note.
        let sortedCapsules = capsules.sorted { $0.startTurnIndex < $1.startTurnIndex }
        let allCorrections = sortedCapsules.flatMap { $0.corrections }
        for capsule in sortedCapsules {
            let applied = applyCorrections(to: capsule, allCorrections: allCorrections)
            let note = renderCapsule(applied)
            messages.append(AttacheChatMessage(role: "system", content: note))
        }
        if let limitation = plan.continuityLimitationNote {
            messages.append(AttacheChatMessage(role: "system", content: limitation))
        }
        // Exact suffix turns.
        for turn in exactSuffixTurns {
            messages.append(AttacheChatMessage(role: turn.role == .user ? "user" : "assistant", content: turn.content))
        }
        return messages
    }

    /// Apply later corrections to an older capsule (INF-316). A correction
    /// whose turnIndex is later than the capsule's end turn supersedes a
    /// matching established fact.
    public static func applyCorrections(
        to capsule: AttacheDirectChatSummaryCapsule,
        allCorrections: [AttacheDirectChatCorrection]
    ) -> AttacheDirectChatSummaryCapsule {
        let laterCorrections = allCorrections.filter { $0.turnIndex > capsule.endTurnIndex }
        guard !laterCorrections.isEmpty else { return capsule }
        var facts = capsule.establishedFacts
        for correction in laterCorrections {
            if let idx = facts.firstIndex(where: { $0 == correction.supersedesClaim }) {
                facts[idx] = correction.correctedClaim
            }
        }
        return AttacheDirectChatSummaryCapsule(
            id: capsule.id, segmentID: capsule.segmentID,
            startTurnIndex: capsule.startTurnIndex, endTurnIndex: capsule.endTurnIndex,
            sourceHash: capsule.sourceHash, establishedFacts: facts,
            decisions: capsule.decisions, openQuestions: capsule.openQuestions,
            corrections: capsule.corrections, unresolvedCommitments: capsule.unresolvedCommitments,
            summarizerVersion: capsule.summarizerVersion,
            modelIdentityKey: capsule.modelIdentityKey, receipt: capsule.receipt,
            createdAt: capsule.createdAt, invalidated: capsule.invalidated
        )
    }

    /// Render a capsule as a neutral system note (INF-316). Never in a
    /// personality's voice. Provenance cites the turn range and source hash.
    static func renderCapsule(_ capsule: AttacheDirectChatSummaryCapsule) -> String {
        var lines: [String] = []
        lines.append("Summary of turns \(capsule.startTurnIndex) to \(capsule.endTurnIndex) (source hash \(String(capsule.sourceHash.prefix(8)))).")
        if !capsule.establishedFacts.isEmpty {
            lines.append("Established facts: " + capsule.establishedFacts.joined(separator: "; "))
        }
        if !capsule.decisions.isEmpty {
            lines.append("Decisions: " + capsule.decisions.joined(separator: "; "))
        }
        if !capsule.openQuestions.isEmpty {
            lines.append("Open questions: " + capsule.openQuestions.joined(separator: "; "))
        }
        if !capsule.unresolvedCommitments.isEmpty {
            lines.append("Unresolved commitments: " + capsule.unresolvedCommitments.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    /// True when a turn contains an explicit quote of work-session content
    /// (INF-316). Only explicit user quotes may carry work-session text into a
    /// direct-chat summary. This is a conservative marker check, not a content
    /// read.
    public static func turnContainsExplicitQuote(_ turn: AttacheDirectChatTurn) -> Bool {
        let lower = turn.content.lowercased()
        return lower.contains("the agent said:") || lower.contains("from the session:")
            || lower.contains("quoted from") || lower.contains("transcript:")
    }
}

/// A SQLite-backed store of direct-chat summary capsules (INF-316). Persists
/// capsules with their provenance so they can be invalidated when a source
/// turn is edited or deleted, or when the summarizer version changes.
/// Content-free diagnostics. 0600 file permissions.
public final class AttacheDirectChatSummaryStore: @unchecked Sendable {
    public static let currentSchemaVersion = 1
    private let dbURL: URL
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(databaseURL: URL) {
        self.dbURL = databaseURL
        openOrCreate()
    }

    deinit { if let handle { sqlite3_close(handle) } }

    private func openOrCreate() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if sqlite3_open(dbURL.path, &handle) != SQLITE_OK {
            handle = nil
            return
        }
        chmod(dbURL.path, 0o600)
        execute("PRAGMA journal_mode = WAL;")
        execute("PRAGMA synchronous = NORMAL;")
        execute("""
        CREATE TABLE IF NOT EXISTS direct_chat_meta (key TEXT PRIMARY KEY, value TEXT);
        """)
        execute("""
        CREATE TABLE IF NOT EXISTS direct_chat_capsules (
            id TEXT PRIMARY KEY,
            segment_id TEXT NOT NULL,
            start_turn INTEGER NOT NULL,
            end_turn INTEGER NOT NULL,
            source_hash TEXT NOT NULL,
            facts TEXT NOT NULL,
            decisions TEXT NOT NULL,
            open_questions TEXT NOT NULL,
            corrections TEXT NOT NULL,
            commitments TEXT NOT NULL,
            summarizer_version TEXT NOT NULL,
            model_identity_key TEXT NOT NULL,
            receipt_json TEXT NOT NULL,
            created_at REAL NOT NULL,
            invalidated INTEGER NOT NULL DEFAULT 0
        );
        """)
        upsertMeta("schema_version", "\(Self.currentSchemaVersion)")
    }

    @discardableResult
    public func add(_ capsule: AttacheDirectChatSummaryCapsule) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return false }
        let sql = """
        INSERT OR REPLACE INTO direct_chat_capsules
        (id, segment_id, start_turn, end_turn, source_hash, facts, decisions,
         open_questions, corrections, commitments, summarizer_version,
         model_identity_key, receipt_json, created_at, invalidated)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, capsule.id, -1, transient)
        sqlite3_bind_text(stmt, 2, capsule.segmentID, -1, transient)
        sqlite3_bind_int64(stmt, 3, Int64(capsule.startTurnIndex))
        sqlite3_bind_int64(stmt, 4, Int64(capsule.endTurnIndex))
        sqlite3_bind_text(stmt, 5, capsule.sourceHash, -1, transient)
        sqlite3_bind_text(stmt, 6, capsule.establishedFacts.joined(separator: "\u{1F}"), -1, transient)
        sqlite3_bind_text(stmt, 7, capsule.decisions.joined(separator: "\u{1F}"), -1, transient)
        sqlite3_bind_text(stmt, 8, capsule.openQuestions.joined(separator: "\u{1F}"), -1, transient)
        sqlite3_bind_text(stmt, 9, capsule.corrections.map { "\($0.turnIndex)\u{1E}\($0.supersedesClaim)\u{1E}\($0.correctedClaim)" }.joined(separator: "\u{1F}"), -1, transient)
        sqlite3_bind_text(stmt, 10, capsule.unresolvedCommitments.joined(separator: "\u{1F}"), -1, transient)
        sqlite3_bind_text(stmt, 11, capsule.summarizerVersion, -1, transient)
        sqlite3_bind_text(stmt, 12, capsule.modelIdentityKey, -1, transient)
        let receiptData = (try? JSONEncoder().encode(capsule.receipt)) ?? Data()
        receiptData.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 13, ptr.baseAddress, Int32(receiptData.count), transient)
        }
        sqlite3_bind_double(stmt, 14, capsule.createdAt.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 15, capsule.invalidated ? 1 : 0)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    public func list(activeOnly: Bool = true) -> [AttacheDirectChatSummaryCapsule] {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return [] }
        let whereClause = activeOnly ? "WHERE invalidated = 0" : ""
        let sql = "SELECT id, segment_id, start_turn, end_turn, source_hash, facts, decisions, open_questions, corrections, commitments, summarizer_version, model_identity_key, receipt_json, created_at, invalidated FROM direct_chat_capsules \(whereClause) ORDER BY start_turn ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var results: [AttacheDirectChatSummaryCapsule] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let capsule = readCapsule(stmt) {
                results.append(capsule)
            }
        }
        return results
    }

    /// Invalidate capsules matching the given source hashes (INF-316). A card
    /// edit or deletion changes the source turn's content hash, so any capsule
    /// built from that hash is stale and is marked invalidated.
    @discardableResult
    public func invalidateBySourceHashes(_ hashes: Set<String>) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let handle, !hashes.isEmpty else { return 0 }
        let placeholders = hashes.map { _ in "?" }.joined(separator: ",")
        let sql = "UPDATE direct_chat_capsules SET invalidated = 1 WHERE source_hash IN (\(placeholders)) AND invalidated = 0;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        for (idx, hash) in hashes.enumerated() {
            sqlite3_bind_text(stmt, Int32(idx + 1), hash, -1, transient)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    /// Invalidate capsules built with an older summarizer version (INF-316).
    @discardableResult
    public func invalidateBySummarizerVersion(olderThan version: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return 0 }
        let sql = "UPDATE direct_chat_capsules SET invalidated = 1 WHERE summarizer_version != ? AND invalidated = 0;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, version, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    public func deleteAll() {
        lock.lock(); defer { lock.unlock() }
        execute("DELETE FROM direct_chat_capsules;")
    }

    private func readCapsule(_ stmt: OpaquePointer?) -> AttacheDirectChatSummaryCapsule? {
        guard let stmt else { return nil }
        let id = stringColumn(stmt, 0)
        let segmentID = stringColumn(stmt, 1)
        let startTurn = Int(sqlite3_column_int64(stmt, 2))
        let endTurn = Int(sqlite3_column_int64(stmt, 3))
        let sourceHash = stringColumn(stmt, 4)
        let facts = stringColumn(stmt, 5).split(separator: "\u{1F}").map(String.init)
        let decisions = stringColumn(stmt, 6).split(separator: "\u{1F}").map(String.init)
        let openQuestions = stringColumn(stmt, 7).split(separator: "\u{1F}").map(String.init)
        let correctionsRaw = stringColumn(stmt, 8)
        let corrections = correctionsRaw.split(separator: "\u{1F}").map { piece -> AttacheDirectChatCorrection in
            let parts = piece.split(separator: "\u{1E}", maxSplits: 2)
            return AttacheDirectChatCorrection(
                turnIndex: Int(parts[0]) ?? 0,
                supersedesClaim: parts.count > 1 ? String(parts[1]) : "",
                correctedClaim: parts.count > 2 ? String(parts[2]) : ""
            )
        }
        let commitments = stringColumn(stmt, 9).split(separator: "\u{1F}").map(String.init)
        let summarizerVersion = stringColumn(stmt, 10)
        let modelKey = stringColumn(stmt, 11)
        let receiptBytes = sqlite3_column_blob(stmt, 12)
        let receiptLen = sqlite3_column_bytes(stmt, 12)
        let receipt: ContextReceipt
        if let receiptBytes, receiptLen > 0 {
            let data = Data(bytes: receiptBytes, count: Int(receiptLen))
            receipt = (try? JSONDecoder().decode(ContextReceipt.self, from: data)) ?? ContextReceipt(
                includedSources: [], omittedSources: [], truncatedSources: [],
                totalEstimatedTokens: 0, remainingBudget: nil,
                modelIdentityKey: modelKey, strategyKind: "unknown",
                stagedProcessingRequired: false
            )
        } else {
            receipt = ContextReceipt(
                includedSources: [], omittedSources: [], truncatedSources: [],
                totalEstimatedTokens: 0, remainingBudget: nil,
                modelIdentityKey: modelKey, strategyKind: "unknown",
                stagedProcessingRequired: false
            )
        }
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13))
        let invalidated = sqlite3_column_int(stmt, 14) == 1
        return AttacheDirectChatSummaryCapsule(
            id: id, segmentID: segmentID, startTurnIndex: startTurn, endTurnIndex: endTurn,
            sourceHash: sourceHash, establishedFacts: facts, decisions: decisions,
            openQuestions: openQuestions, corrections: corrections,
            unresolvedCommitments: commitments, summarizerVersion: summarizerVersion,
            modelIdentityKey: modelKey, receipt: receipt, createdAt: createdAt,
            invalidated: invalidated
        )
    }

    private func stringColumn(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    private func upsertMeta(_ key: String, _ value: String) {
        let escaped = value.replacingOccurrences(of: "'", with: "''")
        execute("INSERT OR REPLACE INTO direct_chat_meta (key, value) VALUES ('\(key)', '\(escaped)');")
    }

    private func execute(_ sql: String) -> Bool {
        guard let handle else { return false }
        var error: UnsafeMutablePointer<Int8>? = nil
        let result = sqlite3_exec(handle, sql, nil, nil, &error)
        if error != nil { sqlite3_free(error) }
        return result == SQLITE_OK
    }
}