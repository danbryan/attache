import Foundation

/// A structured session search query shared by Command-K and the model-facing
/// conversational API (INF-311). Identical queries produce identical ordered
/// session IDs in both surfaces.
public struct AttacheSessionSearchQuery: Equatable, Sendable {
    public var text: String
    public var sourceKind: String?
    public var workingDirectory: String?
    public var titleContains: String?
    public var startDate: Date?
    public var endDate: Date?
    public var limit: Int
    public var offset: Int

    public init(
        text: String,
        sourceKind: String? = nil,
        workingDirectory: String? = nil,
        titleContains: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        limit: Int = 200,
        offset: Int = 0
    ) {
        self.text = text
        self.sourceKind = sourceKind
        self.workingDirectory = workingDirectory
        self.titleContains = titleContains
        self.startDate = startDate
        self.endDate = endDate
        self.limit = max(1, min(limit, 500))
        self.offset = max(0, offset)
    }
}

/// One ranked search result (INF-311). Carries stable session identity, source,
/// title, date, working directory, a provenance locator, a bounded snippet, and
/// a score explanation so the user can understand why it ranked where it did.
/// A result is discovery metadata, not authorization: selecting it is the only
/// action that may focus the session.
public struct AttacheSessionSearchResult: Equatable, Sendable {
    public let sessionID: String
    public let sourceKind: String
    public let title: String
    public let workingDirectory: String?
    public let timestamp: Date
    public let chunkOrdinal: Int
    public let byteOffset: Int
    public let snippet: String
    public let score: Double
    public let scoreExplanation: String

    public init(
        sessionID: String, sourceKind: String, title: String, workingDirectory: String?,
        timestamp: Date, chunkOrdinal: Int, byteOffset: Int, snippet: String,
        score: Double, scoreExplanation: String
    ) {
        self.sessionID = sessionID
        self.sourceKind = sourceKind
        self.title = title
        self.workingDirectory = workingDirectory
        self.timestamp = timestamp
        self.chunkOrdinal = chunkOrdinal
        self.byteOffset = byteOffset
        self.snippet = snippet
        self.score = score
        self.scoreExplanation = scoreExplanation
    }
}

/// One unified local search service over the FTS index (INF-311). Command-K
/// and the model-facing conversational API both call this, so they share
/// ranking, filters, provenance, and the privacy boundary. Search never changes
/// focus, authorization, watched sessions, or tool availability.
public final class AttacheSessionSearchService {
    private let ftsIndex: SessionFTSIndex
    private let records: [SessionRecord]

    public init(ftsIndex: SessionFTSIndex, records: [SessionRecord] = []) {
        self.ftsIndex = ftsIndex
        self.records = records
    }

    /// Search the FTS index. Aggregates chunk hits by session, applies title,
    /// exact-ID, and bounded recency boosts, and returns paginated results with
    /// deterministic tie-breaking.
    public func search(_ query: AttacheSessionSearchQuery, now: Date = Date()) -> [AttacheSessionSearchResult] {
        let trimmed = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return recentSessions(limit: query.limit, offset: query.offset) }

        // Reject pathological query size or term count (INF-311).
        guard trimmed.count <= 1_000 else { return [] }
        let terms = trimmed.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard terms.count <= 50 else { return [] }

        let ftsFilters = SessionFTSQuery(
            sourceKind: query.sourceKind,
            workingDirectory: query.workingDirectory,
            titleContains: query.titleContains,
            startDate: query.startDate,
            endDate: query.endDate,
            limit: query.limit * 4
        )
        let ftsHits = ftsIndex.search(trimmed, filters: ftsFilters)
        return rankAndPaginate(hits: ftsHits, queryText: trimmed, limit: query.limit, offset: query.offset, now: now)
    }

    /// Empty-query behavior: recent sessions display in the picker but are not
    /// injected into conversation (INF-311).
    public func recentSessions(limit: Int, offset: Int = 0) -> [AttacheSessionSearchResult] {
        let sorted = records.sorted { $0.updatedAt > $1.updatedAt }
        let page = Array(sorted.dropFirst(offset).prefix(limit))
        return page.map { record in
            AttacheSessionSearchResult(
                sessionID: record.id,
                sourceKind: record.sourceKind.rawValue,
                title: record.title,
                workingDirectory: record.project,
                timestamp: record.updatedAt,
                chunkOrdinal: 0,
                byteOffset: 0,
                snippet: "",
                score: 0,
                scoreExplanation: "recent"
            )
        }
    }

    // MARK: - Ranking

    private func rankAndPaginate(
        hits: [SessionFTSHit], queryText: String, limit: Int, offset: Int, now: Date
    ) -> [AttacheSessionSearchResult] {
        // Aggregate by session: keep the best (lowest FTS rank = highest relevance) hit.
        var bestBySession: [String: SessionFTSHit] = [:]
        for hit in hits {
            if let existing = bestBySession[hit.sessionID] {
                if hit.rank < existing.rank { bestBySession[hit.sessionID] = hit }
            } else {
                bestBySession[hit.sessionID] = hit
            }
        }

        let queryLower = queryText.lowercased()
        var results: [AttacheSessionSearchResult] = []
        for hit in bestBySession.values {
            var score = -hit.rank // FTS5 rank: lower = more relevant, so negate.
            var explanation: [String] = ["fts:\(String(format: "%.1f", -hit.rank)))"]

            // Title boost: a query term in the title is a strong signal.
            let titleLower = hit.title.lowercased()
            if titleLower.contains(queryLower) {
                score += 40
                explanation.append("title:40")
            }

            // Exact session-ID match: the strongest signal.
            if hit.sessionID.lowercased() == queryLower {
                score += 500
                explanation.append("exact-id:500")
            } else if hit.sessionID.lowercased().contains(queryLower) {
                score += 100
                explanation.append("id-substring:100")
            }

            // Bounded recency boost: ~8 points for today, decaying, so it never
            // swamps a strong older match (INF-311).
            let days = max(0, now.timeIntervalSince(hit.timestamp) / 86_400)
            let recency = 8.0 / (1.0 + days / 3.0)
            score += recency
            explanation.append("recency:\(String(format: "%.1f", recency)))")

            results.append(AttacheSessionSearchResult(
                sessionID: hit.sessionID,
                sourceKind: hit.sourceKind,
                title: hit.title,
                workingDirectory: hit.workingDirectory,
                timestamp: hit.timestamp,
                chunkOrdinal: hit.chunkOrdinal,
                byteOffset: hit.byteOffset,
                snippet: hit.snippet,
                score: score,
                scoreExplanation: explanation.joined(separator: " ")
            ))
        }

        // Deterministic tie-breaking: score desc, then sessionID asc.
        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.sessionID < rhs.sessionID
        }

        return Array(results.dropFirst(offset).prefix(limit))
    }
}