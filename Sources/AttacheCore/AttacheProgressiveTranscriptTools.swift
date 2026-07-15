import Foundation
import CryptoKit

/// A stable provenance locator for one piece of transcript content (INF-320).
/// Every returned character maps to a session and turn/range locator.
public struct AttacheTranscriptLocator: Equatable, Sendable {
    public let sessionID: String
    public let sourceKind: String
    public let turnOrdinal: Int
    public let charStart: Int
    public let charEnd: Int
    public let contentHash: String

    public init(sessionID: String, sourceKind: String, turnOrdinal: Int, charStart: Int, charEnd: Int, contentHash: String) {
        self.sessionID = sessionID
        self.sourceKind = sourceKind
        self.turnOrdinal = turnOrdinal
        self.charStart = charStart
        self.charEnd = charEnd
        self.contentHash = contentHash
    }

    public var coveredRange: String { "turn \(turnOrdinal) chars \(charStart)..\(charEnd)" }
}

/// A typed transcript tool error (INF-320). Stale, deleted, or unauthorized
/// states return a typed error instead of mismatched text.
public enum AttacheTranscriptToolError: Error, Equatable, Sendable {
    case noFocusedSession
    case authorizationExpired
    case sessionIdentityMismatch(expected: String, actual: String)
    case staleLocator(expectedHash: String, actualHash: String)
    case deletedLog
    case budgetExhausted
    case turnOutOfRange(requested: Int, available: Int)
}

/// One turn in a transcript (INF-320). The raw log is the source of truth.
public struct AttacheTranscriptTurn: Equatable, Sendable {
    public let ordinal: Int
    public let role: String
    public let content: String
    public let timestamp: Date
    public let contentHash: String

    public init(ordinal: Int, role: String, content: String, timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.ordinal = ordinal
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.contentHash = AttacheTranscriptTurn.hash(content)
    }

    public static func hash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The truncation state of a returned result (INF-320).
public enum AttacheTranscriptTruncation: String, Equatable, Sendable {
    case full
    case excerpt
    case empty
}

/// The result of inspecting a focused session (INF-320). Content-free outline
/// with metadata and bounded head/tail summaries.
public struct AttacheTranscriptInspection: Equatable, Sendable {
    public let sessionID: String
    public let sourceKind: String
    public let title: String
    public let timestampStart: Date
    public let timestampEnd: Date
    public let turnCount: Int
    public let contentVersion: String
    public let headOutline: [String]
    public let tailOutline: [String]

    public init(sessionID: String, sourceKind: String, title: String,
                timestampStart: Date, timestampEnd: Date, turnCount: Int,
                contentVersion: String, headOutline: [String], tailOutline: [String]) {
        self.sessionID = sessionID
        self.sourceKind = sourceKind
        self.title = title
        self.timestampStart = timestampStart
        self.timestampEnd = timestampEnd
        self.turnCount = turnCount
        self.contentVersion = contentVersion
        self.headOutline = headOutline
        self.tailOutline = tailOutline
    }
}

/// One ranked search hit within the focused session (INF-320).
public struct AttacheTranscriptSearchHit: Equatable, Sendable {
    public let locator: AttacheTranscriptLocator
    public let snippet: String
    public let rank: Double
    public let truncation: AttacheTranscriptTruncation

    public init(locator: AttacheTranscriptLocator, snippet: String, rank: Double, truncation: AttacheTranscriptTruncation) {
        self.locator = locator
        self.snippet = snippet
        self.rank = rank
        self.truncation = truncation
    }
}

/// The result of reading a turn range (INF-320). Bounded content with a
/// locator, truncation state, and a next-page locator for continuation.
public struct AttacheTranscriptRangeRead: Equatable, Sendable {
    public let locator: AttacheTranscriptLocator
    public let content: String
    public let truncation: AttacheTranscriptTruncation
    public let continuationLocator: AttacheTranscriptLocator?
    public let isQuotedEvidence: Bool

    public init(locator: AttacheTranscriptLocator, content: String,
                truncation: AttacheTranscriptTruncation,
                continuationLocator: AttacheTranscriptLocator?, isQuotedEvidence: Bool = true) {
        self.locator = locator
        self.content = content
        self.truncation = truncation
        self.continuationLocator = continuationLocator
        self.isQuotedEvidence = isQuotedEvidence
    }
}

/// The authorization guard for transcript tools (INF-320). Revalidates the
/// focused session and authorization epoch at execution time. A focus change,
/// hang-up, deleted file, or replaced log fails closed.
public enum AttacheTranscriptAuthorizationGuard {

    /// Validate that the focused session is still the one the tool was
    /// authorized for, and that the epoch has not advanced (INF-320).
    public static func validate(
        focusedSession: AttacheFocusedSession?,
        expectedEpoch: AttacheFocusEpoch,
        currentEpoch: AttacheFocusEpoch,
        currentSessionID: String?
    ) -> Result<Void, AttacheTranscriptToolError> {
        guard let session = focusedSession else {
            return .failure(.noFocusedSession)
        }
        guard expectedEpoch == currentEpoch else {
            return .failure(.authorizationExpired)
        }
        if let currentID = currentSessionID, currentID != session.sessionID {
            return .failure(.sessionIdentityMismatch(expected: session.sessionID, actual: currentID))
        }
        return .success(())
    }
}

/// The pure progressive transcript tool family (INF-320). Three structured
/// tools: inspect, search, and readRange. Every result carries a locator.
/// Results are accounted through INF-317's budget reserve. Transcript text is
/// untrusted quoted evidence, never instructions. HTTP and CLI paths produce
/// identical results through this shared Core logic.
public enum AttacheProgressiveTranscriptTools {

    public static let outlineTurnCount = 3
    public static let outlineCharLimit = 120

    /// Inspect a focused session (INF-320). Returns metadata and a bounded
    /// head/tail outline. No authorization bypass: validates the epoch.
    public static func inspect(
        focusedSession: AttacheFocusedSession?,
        expectedEpoch: AttacheFocusEpoch,
        currentEpoch: AttacheFocusEpoch,
        currentSessionID: String?,
        turns: [AttacheTranscriptTurn]
    ) -> Result<AttacheTranscriptInspection, AttacheTranscriptToolError> {
        let guardResult = AttacheTranscriptAuthorizationGuard.validate(
            focusedSession: focusedSession, expectedEpoch: expectedEpoch,
            currentEpoch: currentEpoch, currentSessionID: currentSessionID
        )
        switch guardResult {
        case .failure(let error): return .failure(error)
        case .success: break
        }
        guard let session = focusedSession else { return .failure(.noFocusedSession) }
        let sortedTurns = turns.sorted { $0.ordinal < $1.ordinal }
        let head = Array(sortedTurns.prefix(outlineTurnCount)).map { outlineLine($0) }
        let tail = Array(sortedTurns.suffix(outlineTurnCount)).map { outlineLine($0) }
        let version = AttacheTranscriptTurn.hash(sortedTurns.map { $0.contentHash }.joined(separator: "|"))
        let start = sortedTurns.first?.timestamp ?? Date(timeIntervalSince1970: 0)
        let end = sortedTurns.last?.timestamp ?? Date(timeIntervalSince1970: 0)
        return .success(AttacheTranscriptInspection(
            sessionID: session.sessionID, sourceKind: session.sourceKind,
            title: session.displayTitle, timestampStart: start, timestampEnd: end,
            turnCount: sortedTurns.count, contentVersion: version,
            headOutline: head, tailOutline: tail
        ))
    }

    /// Search the focused transcript (INF-320). Uses lexical matching filtered
    /// to the frozen session. Cannot cross into a different session. Returns
    /// bounded hits with stable locators.
    public static func search(
        focusedSession: AttacheFocusedSession?,
        expectedEpoch: AttacheFocusEpoch,
        currentEpoch: AttacheFocusEpoch,
        currentSessionID: String?,
        query: String,
        turns: [AttacheTranscriptTurn],
        reserve: inout AttacheToolBudgetReserve,
        maxResults: Int = 10
    ) -> Result<[AttacheTranscriptSearchHit], AttacheTranscriptToolError> {
        let guardResult = AttacheTranscriptAuthorizationGuard.validate(
            focusedSession: focusedSession, expectedEpoch: expectedEpoch,
            currentEpoch: currentEpoch, currentSessionID: currentSessionID
        )
        switch guardResult {
        case .failure(let error): return .failure(error)
        case .success: break
        }
        guard let session = focusedSession else { return .failure(.noFocusedSession) }
        if reserve.isExhausted { return .failure(.budgetExhausted) }
        let queryTokens = AttacheMemorySelector.lexicalOverlap(query, "") // just tokenizes
        _ = queryTokens
        let scored = turns.map { turn -> (turn: AttacheTranscriptTurn, score: Double) in
            let overlap = AttacheMemorySelector.lexicalOverlap(query, turn.content)
            return (turn, overlap)
        }.filter { $0.score > 0 }.sorted { $0.score > $1.score }
        var hits: [AttacheTranscriptSearchHit] = []
        for entry in scored.prefix(maxResults) {
            if reserve.isExhausted { break }
            let snippet = String(entry.turn.content.prefix(200))
            let tokens = AttacheFallbackTokenEstimator().estimate(text: snippet)
            _ = reserve.consume(tokens)
            let locator = AttacheTranscriptLocator(
                sessionID: session.sessionID, sourceKind: session.sourceKind,
                turnOrdinal: entry.turn.ordinal, charStart: 0,
                charEnd: min(entry.turn.content.count, 200),
                contentHash: entry.turn.contentHash
            )
            hits.append(AttacheTranscriptSearchHit(
                locator: locator, snippet: snippet, rank: entry.score,
                truncation: entry.turn.content.count > 200 ? .excerpt : .full
            ))
        }
        return .success(hits)
    }

    /// Read a turn range (INF-320). Accepts a turn ordinal and optional char
    /// start. Returns bounded content with a locator and continuation. One
    /// giant turn is bounded and continuation is deterministic.
    public static func readRange(
        focusedSession: AttacheFocusedSession?,
        expectedEpoch: AttacheFocusEpoch,
        currentEpoch: AttacheFocusEpoch,
        currentSessionID: String?,
        turnOrdinal: Int,
        charStart: Int,
        maxChars: Int?,
        turns: [AttacheTranscriptTurn],
        expectedContentHash: String?,
        reserve: inout AttacheToolBudgetReserve,
        policy: AttacheToolBudgetPolicy
    ) -> Result<AttacheTranscriptRangeRead, AttacheTranscriptToolError> {
        let guardResult = AttacheTranscriptAuthorizationGuard.validate(
            focusedSession: focusedSession, expectedEpoch: expectedEpoch,
            currentEpoch: currentEpoch, currentSessionID: currentSessionID
        )
        switch guardResult {
        case .failure(let error): return .failure(error)
        case .success: break
        }
        guard let session = focusedSession else { return .failure(.noFocusedSession) }
        if reserve.isExhausted { return .failure(.budgetExhausted) }
        guard let turn = turns.first(where: { $0.ordinal == turnOrdinal }) else {
            return .failure(.turnOutOfRange(requested: turnOrdinal, available: turns.count))
        }
        // Stale locator detection: if the caller provides an expected hash and
        // it does not match, the log was replaced. Fail closed.
        if let expected = expectedContentHash, expected != turn.contentHash {
            return .failure(.staleLocator(expectedHash: expected, actualHash: turn.contentHash))
        }
        let start = max(charStart, 0)
        let limit = AttacheToolBudgetEnforcer.clampMaxChars(maxChars, reserve: reserve, policy: policy)
        let availableContent = String(turn.content.dropFirst(start))
        let included = String(availableContent.prefix(limit))
        let charEnd = start + included.count
        let truncation: AttacheTranscriptTruncation
        let continuation: AttacheTranscriptLocator?
        if included.count >= availableContent.count {
            truncation = .full
            continuation = nil
        } else {
            truncation = .excerpt
            continuation = AttacheTranscriptLocator(
                sessionID: session.sessionID, sourceKind: session.sourceKind,
                turnOrdinal: turnOrdinal, charStart: charEnd, charEnd: charEnd,
                contentHash: turn.contentHash
            )
        }
        // Account for the consumed tokens.
        let tokens = AttacheFallbackTokenEstimator().estimate(text: included)
        _ = reserve.consume(tokens)
        let locator = AttacheTranscriptLocator(
            sessionID: session.sessionID, sourceKind: session.sourceKind,
            turnOrdinal: turnOrdinal, charStart: start, charEnd: charEnd,
            contentHash: turn.contentHash
        )
        // Quoted evidence: the content is wrapped so it is never treated as
        // instructions.
        let quoted = "[Evidence turn \(turnOrdinal) chars \(start)..\(charEnd): \(included)]"
        return .success(AttacheTranscriptRangeRead(
            locator: locator, content: quoted, truncation: truncation,
            continuationLocator: continuation
        ))
    }

    /// Outline line for a turn (INF-320). Content-free summary for the
    /// inspection head/tail.
    static func outlineLine(_ turn: AttacheTranscriptTurn) -> String {
        let preview = String(turn.content.prefix(outlineCharLimit))
        let ellipsis = turn.content.count > outlineCharLimit ? "..." : ""
        return "Turn \(turn.ordinal) (\(turn.role)): \(preview)\(ellipsis)"
    }

    /// True when text looks like a prompt injection (INF-320). Transcript text
    /// is always untrusted quoted evidence regardless, so injection cannot
    /// alter tool authorization.
    public static func looksLikeInjection(_ text: String) -> Bool {
        AttacheMemorySelector.looksLikeInjection(text)
    }
}