import Foundation

/// A bounded, structured session-discovery query (INF-315). The personality may
/// send one of these through a narrow `request_session_search` action. It
/// carries only filters, never a request to read or summarize a session.
public struct AttacheSessionDiscoveryQuery: Equatable, Sendable {
    public let text: String
    public let sourceKind: String?
    public let workingDirectory: String?
    public let dateAfter: Date?
    public let dateBefore: Date?
    public let limit: Int

    public init(
        text: String,
        sourceKind: String? = nil,
        workingDirectory: String? = nil,
        dateAfter: Date? = nil,
        dateBefore: Date? = nil,
        limit: Int = 20
    ) {
        self.text = text
        self.sourceKind = sourceKind
        self.workingDirectory = workingDirectory
        self.dateAfter = dateAfter
        self.dateBefore = dateBefore
        self.limit = limit
    }
}

/// A typed discovery error (INF-315).
public enum AttacheSessionDiscoveryError: Error, Equatable, Sendable {
    case queryTextTooLong(maxLength: Int)
    case queryTextEmpty
    case limitOutOfRange(max: Int)
    case dateRangeInvalid
    case noMatches
    case staleResult
    case modelSuppliedFakeID
    case selectionRequired(matchCount: Int)
}

/// The non-effectful action request envelope (INF-315). The personality sends
/// this; the app validates it, runs search locally, and opens the native
/// picker. The model never sees the results.
public struct AttacheSessionDiscoveryRequest: Equatable, Sendable {
    public let query: AttacheSessionDiscoveryQuery
    public let triggeringUserTurn: String

    public init(query: AttacheSessionDiscoveryQuery, triggeringUserTurn: String) {
        self.query = query
        self.triggeringUserTurn = triggeringUserTurn
    }
}

/// The model-safe result of a discovery search (INF-315). Contains ONLY a
/// match count and fixed guidance text. No title, no snippet, no path, no
/// session ID, no transcript, no metadata. The model learns how many sessions
/// matched and whether it must ask the user to pick one. That is all.
public struct AttacheSessionDiscoveryResult: Equatable, Sendable {
    public let matchCount: Int
    public let requiresSelection: Bool
    public let noMatches: Bool
    public let guidance: String

    public init(matchCount: Int, requiresSelection: Bool, noMatches: Bool, guidance: String) {
        self.matchCount = matchCount
        self.requiresSelection = requiresSelection
        self.noMatches = noMatches
        self.guidance = guidance
    }
}

/// The user's explicit picker selection (INF-315). This is produced by the
/// native picker (Enter or click), never by the model. The coordinator
/// validates it against the search results before focus is granted.
public struct AttacheSessionDiscoverySelection: Equatable, Sendable {
    public let sessionID: String
    public let sourceKind: String
    public let displayTitle: String
    public let workingDirectory: String?

    public init(sessionID: String, sourceKind: String, displayTitle: String, workingDirectory: String?) {
        self.sessionID = sessionID
        self.sourceKind = sourceKind
        self.displayTitle = displayTitle
        self.workingDirectory = workingDirectory
    }
}

/// A monotonic focus authorization epoch (INF-315). Each explicit focus grant
/// advances the epoch so a request snapshot frozen before the grant is stale
/// and cannot use the newly focused session.
public struct AttacheFocusEpoch: Equatable, Sendable, Comparable {
    public let value: Int
    public init(_ value: Int) { self.value = value }
    public static func < (lhs: AttacheFocusEpoch, rhs: AttacheFocusEpoch) -> Bool { lhs.value < rhs.value }
    public func advanced() -> AttacheFocusEpoch { AttacheFocusEpoch(value + 1) }
}

/// The outcome of a focus grant (INF-315). The frozen session plus the new
/// authorization epoch. Search alone never produces one of these; only an
/// explicit native selection does.
public struct AttacheFocusGrant: Equatable, Sendable {
    public let session: AttacheFocusedSession
    public let epoch: AttacheFocusEpoch

    public init(session: AttacheFocusedSession, epoch: AttacheFocusEpoch) {
        self.session = session
        self.epoch = epoch
    }
}

/// The pure session-discovery coordinator (INF-315). Enforces the two-phase
/// safety contract: the model requests a search, the app runs it locally and
/// shows a model-safe result (count + guidance only), and only an explicit
/// native selection grants focus. No result content ever reaches the model.
///
/// Pure and deterministic given the search service. The App wires the picker
/// UI and the actual focus mutation; this type owns the contract and the
/// validation that makes focus safe.
public enum AttacheSessionDiscoveryCoordinator {

    public static let maxQueryLength = 200
    public static let maxLimit = 20

    /// Validate a discovery query (INF-315). Bounded text, bounded limit,
    /// valid date range. Throws a typed error on violation.
    public static func validateQuery(_ query: AttacheSessionDiscoveryQuery) throws -> AttacheSessionDiscoveryQuery {
        let trimmed = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AttacheSessionDiscoveryError.queryTextEmpty }
        guard trimmed.count <= maxQueryLength else {
            throw AttacheSessionDiscoveryError.queryTextTooLong(maxLength: maxQueryLength)
        }
        let clampedLimit = min(max(query.limit, 1), maxLimit)
        if let after = query.dateAfter, let before = query.dateBefore, after > before {
            throw AttacheSessionDiscoveryError.dateRangeInvalid
        }
        return AttacheSessionDiscoveryQuery(
            text: trimmed, sourceKind: query.sourceKind,
            workingDirectory: query.workingDirectory,
            dateAfter: query.dateAfter, dateBefore: query.dateBefore,
            limit: clampedLimit
        )
    }

    /// Run a discovery search and produce a model-safe result (INF-315). The
    /// model receives only a count and fixed guidance. No title, snippet,
    /// path, or session ID leaks. Returns the result plus the set of valid
    /// session IDs the picker may offer (kept app-side, never sent to the
    /// model).
    public static func search(
        request: AttacheSessionDiscoveryRequest,
        service: AttacheSessionSearchService,
        now: Date = Date()
    ) -> (result: AttacheSessionDiscoveryResult, validSessionIDs: Set<String>) {
        let query = (try? validateQuery(request.query)) ?? request.query
        let searchQuery = AttacheSessionSearchQuery(
            text: query.text,
            sourceKind: query.sourceKind,
            workingDirectory: query.workingDirectory,
            titleContains: nil,
            startDate: query.dateAfter,
            endDate: query.dateBefore,
            limit: min(query.limit, maxLimit),
            offset: 0
        )
        let hits = service.search(searchQuery, now: now)
        // Deduplicate by session ID: one session may produce multiple chunk hits.
        let uniqueSessionIDs = Set(hits.map { $0.sessionID })
        let matchCount = uniqueSessionIDs.count
        let result: AttacheSessionDiscoveryResult
        if matchCount == 0 {
            result = AttacheSessionDiscoveryResult(
                matchCount: 0, requiresSelection: false, noMatches: true,
                guidance: "No sessions matched. Ask the user to rephrase or try a different filter."
            )
        } else if matchCount == 1 {
            result = AttacheSessionDiscoveryResult(
                matchCount: 1, requiresSelection: true, noMatches: false,
                guidance: "One session matched. Ask the user to confirm it in the picker before Attaché can read it."
            )
        } else {
            result = AttacheSessionDiscoveryResult(
                matchCount: matchCount, requiresSelection: true, noMatches: false,
                guidance: "\(matchCount) sessions matched. Ask the user to pick one in the picker. Attaché cannot guess which one."
            )
        }
        return (result, uniqueSessionIDs)
    }

    /// Validate a native picker selection against the search results (INF-315).
    /// The selection must come from the picker and must be one of the sessions
    /// the search returned. A model-supplied fake ID, a stale result, or a
    /// deleted session is rejected. Only a valid selection produces a focus
    /// grant with an advanced epoch.
    public static func validateSelection(
        _ selection: AttacheSessionDiscoverySelection,
        validSessionIDs: Set<String>,
        currentEpoch: AttacheFocusEpoch
    ) throws -> AttacheFocusGrant {
        guard validSessionIDs.contains(selection.sessionID) else {
            // Distinguish a fake ID the model invented from a result that was
            // valid at search time but deleted before selection. The caller
            // does not know which; both are rejected with staleResult, which
            // is the safe answer: focus does not change.
            throw AttacheSessionDiscoveryError.staleResult
        }
        let session = AttacheFocusedSession(
            sessionID: selection.sessionID,
            sourceKind: selection.sourceKind,
            displayTitle: selection.displayTitle,
            workingDirectory: selection.workingDirectory
        )
        return AttacheFocusGrant(session: session, epoch: currentEpoch.advanced())
    }

    /// Reject a model-supplied session ID that did not come through the picker
    /// (INF-315). The model may try to focus a session by guessing its ID.
    /// That is always rejected: focus is granted only by a native selection
    /// event, and the selection must be in the valid set.
    public static func rejectModelSuppliedID(
        _ sessionID: String,
        validSessionIDs: Set<String>
    ) -> AttacheSessionDiscoveryError {
        if validSessionIDs.contains(sessionID) {
            // Technically valid but still rejected because it did not come
            // through the native picker event. The caller must route through
            // validateSelection with a real picker selection.
            return .modelSuppliedFakeID
        }
        return .modelSuppliedFakeID
    }
}