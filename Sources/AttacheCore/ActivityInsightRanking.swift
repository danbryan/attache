import Foundation

/// One distinct thing an agent has been doing recently, as the activity ring
/// sees it: a humanized label and how many times it was observed. The label is
/// the ONLY thing that ever leaves the machine for smart ranking; arguments,
/// results, file contents, and transcript text never appear here.
public struct ActivityRankingCandidate: Equatable, Sendable {
    public let label: String
    public let count: Int

    public init(label: String, count: Int) {
        self.label = label
        self.count = count
    }
}

/// Pure logic for the optional "smart ranking" pass over watched-session
/// activity labels (INF): when an agent makes many DISTINCT calls the
/// deterministic ring gets noisy, so a fast model can pick the few most
/// significant. This type only builds the prompt and maps the answer back; it
/// makes no model call, and by construction the prompt carries ONLY labels and
/// counts.
public enum ActivityInsightRanking {
    /// The most labels the ring shows, and the ceiling the ranker returns.
    public static let maxDisplay = 5

    /// Collapse candidates to distinct-by-label, summing counts, so "50
    /// Coinbase calls" is ONE candidate. Order is by count desc then label, a
    /// deterministic, model-free baseline.
    public static func distinctCandidates(from raw: [ActivityRankingCandidate]) -> [ActivityRankingCandidate] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for candidate in raw {
            let label = candidate.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            if counts[label] == nil { order.append(label) }
            counts[label, default: 0] += max(1, candidate.count)
        }
        return order
            .map { ActivityRankingCandidate(label: $0, count: counts[$0] ?? 1) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.label < rhs.label
            }
    }

    /// Ranking only earns its keep (and its token spend) when there are more
    /// distinct labels than the ring can show at once.
    public static func shouldRank(candidateCount: Int, displayCap: Int = maxDisplay) -> Bool {
        candidateCount > displayCap
    }

    /// The smallest possible prompt: a fixed instruction plus a bulleted list of
    /// `label (count)` lines. No arguments, no results, no session text. The
    /// model is told to return labels FROM THE LIST so the answer maps cleanly.
    public static func prompt(
        for candidates: [ActivityRankingCandidate],
        limit: Int = maxDisplay
    ) -> (system: String, user: String) {
        let system = "You rank an AI agent's recent tool activity. You are given a list of short activity labels with counts. Return the \(limit) most significant labels for the user to notice, one per line, copied exactly from the list, most important first. Output only labels, no numbering, no commentary."
        let list = candidates
            .map { "- \($0.label) (\($0.count))" }
            .joined(separator: "\n")
        let user = "Recent activity labels:\n\(list)"
        return (system, user)
    }

    /// Parse the model's reply into an ordered list of labels: split on
    /// newlines/commas, strip bullets and numbering, drop empties.
    public static func parseRankedLabels(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { line -> String in
                var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                while let first = trimmed.first, "-*•0123456789.)#".contains(first) {
                    trimmed.removeFirst()
                    trimmed = trimmed.trimmingCharacters(in: .whitespaces)
                }
                return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    /// Map the model's ordered labels back onto the known candidate labels,
    /// preserving the model's order, de-duplicating, and capping at `limit`.
    /// Matching is case-insensitive exact first, then containment either way, so
    /// a lightly reworded answer still resolves. Never invents a label the ring
    /// did not already have.
    public static func selectRanked(
        orderedLabels: [String],
        from candidateLabels: [String],
        limit: Int = maxDisplay
    ) -> [String] {
        var chosen: [String] = []
        for raw in orderedLabels {
            let needle = raw.lowercased()
            let match = candidateLabels.first { candidate in
                let hay = candidate.lowercased()
                return hay == needle || hay.contains(needle) || needle.contains(hay)
            }
            if let match, !chosen.contains(match) {
                chosen.append(match)
                if chosen.count >= limit { break }
            }
        }
        return chosen
    }
}
