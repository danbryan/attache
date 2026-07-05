import Foundation

/// Groups sessions into continuation chains, "threads". Codex stores no parent link
/// for a compacted-and-continued session, but a real continuation happens in one
/// sitting: same thread name, sessions minutes-to-hours apart. A recurring automation
/// (a daily brief) reuses its thread name but its runs are a day apart, so it never
/// clusters. So a thread = same thread name + a run of sessions whose consecutive
/// gaps stay under `maxGap`, with at least two sessions.
public enum SessionThreadGrouper {
    public struct Chain: Equatable {
        public let name: String
        public let ids: [String]   // most-recent first
        public init(name: String, ids: [String]) {
            self.name = name
            self.ids = ids
        }
    }

    /// Default cluster window: 6 hours. A continued sitting stays well under this; a
    /// daily automation's ~24h spacing stays well over it.
    public static func chains(from records: [SessionRecord], maxGap: TimeInterval = 21_600) -> [Chain] {
        let named = records.filter { ($0.threadName ?? "").isEmpty == false }
        let byThread = Dictionary(grouping: named) { $0.threadName! }
        var chains: [Chain] = []

        for (name, group) in byThread {
            let sorted = group.sorted { $0.updatedAt < $1.updatedAt }
            var run: [SessionRecord] = []
            func flush() {
                if run.count >= 2 {
                    // Present most-recent first to match the rest of the UI.
                    chains.append(Chain(name: name, ids: run.reversed().map(\.id)))
                }
                run = []
            }
            for record in sorted {
                if let last = run.last, record.updatedAt.timeIntervalSince(last.updatedAt) >= maxGap {
                    flush()
                }
                run.append(record)
            }
            flush()
        }

        // Most-recently-active chain first.
        return chains.sorted { lhs, rhs in
            (latest(lhs, in: records) ?? .distantPast) > (latest(rhs, in: records) ?? .distantPast)
        }
    }

    private static func latest(_ chain: Chain, in records: [SessionRecord]) -> Date? {
        let ids = Set(chain.ids)
        return records.filter { ids.contains($0.id) }.map(\.updatedAt).max()
    }
}
