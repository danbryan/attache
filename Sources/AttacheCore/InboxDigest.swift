import Foundation

/// The "while you were away" inbox digest (INF-169). Deterministic by
/// construction: it composes from the already-presented card summaries, so it
/// needs no model call of its own and degrades to counts when summaries are
/// empty.
public enum InboxDigest {
    public struct SessionSlice {
        public var title: String
        public var unheardCount: Int
        public var latestSummary: String
        public var needsDecision: Bool

        public init(title: String, unheardCount: Int, latestSummary: String, needsDecision: Bool = false) {
            self.title = title
            self.unheardCount = unheardCount
            self.latestSummary = latestSummary
            self.needsDecision = needsDecision
        }
    }

    /// One or two sentences: totals, the busiest sessions, the freshest
    /// summary for color, and a decision callout when any card carries the
    /// needs-decision flag.
    public static func text(slices: [SessionSlice]) -> String {
        let total = slices.reduce(0) { $0 + $1.unheardCount }
        guard total > 0, !slices.isEmpty else {
            return "You're all caught up."
        }
        let ordered = slices.sorted { $0.unheardCount > $1.unheardCount }
        let named = ordered.prefix(3)
            .map { "\($0.title) (\($0.unheardCount))" }
            .joined(separator: ", ")
        let overflow = slices.count > 3 ? " and \(slices.count - 3) more" : ""
        let updatesWord = total == 1 ? "update" : "updates"
        let sessionsWord = slices.count == 1 ? "session" : "sessions"
        var sentence = "\(total) \(updatesWord) across \(slices.count) \(sessionsWord): \(named)\(overflow)."

        if let freshest = ordered.first(where: { !$0.latestSummary.isEmpty }) {
            sentence += " Latest from \(freshest.title): \(clipped(freshest.latestSummary, limit: 140))"
        }
        let decisions = slices.filter(\.needsDecision)
        if !decisions.isEmpty {
            let names = decisions.prefix(2).map(\.title).joined(separator: " and ")
            sentence += " \(names) \(decisions.count == 1 ? "needs" : "need") a decision from you."
        }
        return sentence
    }

    private static func clipped(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
