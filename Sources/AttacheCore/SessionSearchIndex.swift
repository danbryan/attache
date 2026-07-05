import Foundation

/// One indexed Codex session: cheap metadata plus a capped digest of the
/// transcript so search can match on title and content without re-reading files.
public struct SessionRecord: Codable, Equatable {
    public var id: String
    public var title: String
    public var project: String?      // working directory (cwd)
    public var threadName: String?   // continuation key: resumed threads share it
    public var updatedAt: Date
    public var archived: Bool
    public var filePath: String
    public var fileMtime: Double
    public var content: String       // lowercased, capped transcript digest
    public var topicTag: String?     // LLM-assigned topic ("Taxes", "Penumbra"), nil until tagged
    public var sourceKind: SourceKind // which tool produced the session (Codex, Claude Code, ...)

    public init(
        id: String,
        title: String,
        project: String?,
        threadName: String?,
        updatedAt: Date,
        archived: Bool,
        filePath: String,
        fileMtime: Double,
        content: String,
        topicTag: String? = nil,
        sourceKind: SourceKind = .codex
    ) {
        self.id = id
        self.title = title
        self.project = project
        self.threadName = threadName
        self.updatedAt = updatedAt
        self.archived = archived
        self.filePath = filePath
        self.fileMtime = fileMtime
        self.content = content
        self.topicTag = topicTag
        self.sourceKind = sourceKind
    }
}

public struct SessionSearchHit: Equatable {
    public var record: SessionRecord
    public var score: Double
    public var matchedContent: Bool
    public var snippet: String?

    public init(record: SessionRecord, score: Double, matchedContent: Bool, snippet: String?) {
        self.record = record
        self.score = score
        self.matchedContent = matchedContent
        self.snippet = snippet
    }
}

public enum SessionSort: String, CaseIterable {
    case recent
    case project
    case continuation
}

/// Pure ranking over the in-memory records: fuzzy title match + keyword content
/// match, stopword-filtered so plain-language queries ("the session where we did
/// penumbra delegation") match on the words that matter.
public enum SessionSearchRanker {
    static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "where",
        "we", "i", "you", "did", "do", "does", "that", "this", "it", "was", "is", "are",
        "session", "sessions", "bring", "up", "find", "one", "my", "me", "can", "could",
        "please", "attache", "attaché", "show", "open", "get", "about", "when", "what",
        "had", "have", "been", "back", "go", "into", "at", "by", "from", "be", "our"
    ]

    public static func tokens(in query: String) -> [String] {
        query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    /// Distinctive query terms used for content matching (stopwords removed). Falls
    /// back to all tokens if everything was a stopword (e.g. a short title query).
    public static func distinctiveTerms(in query: String) -> [String] {
        let all = tokens(in: query)
        let distinctive = all.filter { !stopwords.contains($0) }
        return distinctive.isEmpty ? all : distinctive
    }

    public static func search(
        _ query: String,
        in records: [SessionRecord],
        pinned: Set<String> = [],
        includeArchived: Bool = true,
        limit: Int = 200
    ) -> [SessionSearchHit] {
        let pool = includeArchived ? records : records.filter { !$0.archived }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            // No query: most-recent (pinned first), no scoring.
            let sorted = pool.sorted { lhs, rhs in
                let lp = pinned.contains(lhs.id), rp = pinned.contains(rhs.id)
                if lp != rp { return lp }
                return lhs.updatedAt > rhs.updatedAt
            }
            return sorted.prefix(limit).map {
                SessionSearchHit(record: $0, score: 0, matchedContent: false, snippet: nil)
            }
        }

        let terms = distinctiveTerms(in: trimmed)
        let queryLower = trimmed.lowercased()
        var hits: [SessionSearchHit] = []

        for record in pool {
            let titleLower = record.title.lowercased()
            let tagLower = record.topicTag?.lowercased() ?? ""
            var score = 0.0
            var matchedContent = false
            var matchedTerms = 0

            // Whole-query fuzzy match on the title (handles typo-y short queries).
            if let fuzzy = fuzzyScore(queryLower, titleLower) {
                score += fuzzy
            }

            for term in terms {
                var matched = false
                if titleLower.contains(term) {
                    score += 14
                    matched = true
                }
                if !tagLower.isEmpty, tagLower.contains(term) {
                    score += 10
                    matched = true
                }
                if record.content.contains(term) {
                    score += 4
                    matchedContent = true
                    matched = true
                }
                if matched { matchedTerms += 1 }
            }

            guard matchedTerms > 0 || score > 0 else { continue }
            // Reward matching more of the requested terms.
            score += Double(matchedTerms) * 3
            score += recencyBonus(record.updatedAt)
            if pinned.contains(record.id) { score += 1_000 }

            let snippet = matchedContent ? makeSnippet(record.content, terms: terms) : nil
            hits.append(SessionSearchHit(record: record, score: score, matchedContent: matchedContent, snippet: snippet))
        }

        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.record.updatedAt > rhs.record.updatedAt
        }
        return Array(hits.prefix(limit))
    }

    /// Case-insensitive subsequence score, or nil if not all query chars appear in
    /// order. Rewards contiguous runs and a prefix match.
    static func fuzzyScore(_ query: String, _ text: String) -> Double? {
        let q = Array(query), t = Array(text)
        guard !q.isEmpty, !t.isEmpty else { return nil }
        var qi = 0
        var score = 0.0
        var lastMatch = -2
        for (ti, ch) in t.enumerated() where qi < q.count {
            if ch == q[qi] {
                score += (ti == lastMatch + 1) ? 3 : 1
                if ti == 0 { score += 6 }
                lastMatch = ti
                qi += 1
            }
        }
        guard qi == q.count else { return nil }
        return score / Double(t.count) * 40
    }

    static func recencyBonus(_ date: Date, now: Date = Date()) -> Double {
        let days = max(0, now.timeIntervalSince(date) / 86_400)
        // ~8 points for today, decaying over a couple weeks.
        return 8.0 / (1.0 + days / 3.0)
    }

    static func makeSnippet(_ raw: String, terms: [String], window: Int = 60) -> String? {
        // Strip command markup before cutting the window so a snippet never
        // shows a half tag like "…mmand-message>…".
        let content = SessionDigest.strippedTranscriptMarkup(raw)
        guard let term = terms.first(where: { content.contains($0) }),
              let range = content.range(of: term) else {
            return nil
        }
        let lower = content.index(range.lowerBound, offsetBy: -window, limitedBy: content.startIndex) ?? content.startIndex
        let upper = content.index(range.upperBound, offsetBy: window, limitedBy: content.endIndex) ?? content.endIndex
        var snippet = String(content[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
        if lower > content.startIndex { snippet = "…" + snippet }
        if upper < content.endIndex { snippet += "…" }
        return snippet
    }
}
