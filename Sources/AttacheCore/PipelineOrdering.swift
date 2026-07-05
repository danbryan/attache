import Foundation
import CryptoKit

/// Pure helpers for ordering, staleness, and idempotency of ingested events, so
/// the pipeline's timeline behavior (INF-163) is testable without the watcher,
/// store, or clock.
public enum PipelineOrdering {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoWhole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func isoString(from date: Date) -> String {
        isoFractional.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        isoFractional.date(from: string) ?? isoWhole.date(from: string)
    }

    /// A stable, deterministic id for a card derived from what identifies the same
    /// agent turn across delivery paths (watcher and HTTP hook) and across client
    /// retries. Two ingests of the same turn produce the same id, so a dedupe on
    /// insert collapses them into one card.
    public static func stableCardID(source: String, sessionID: String?, sourceTime: String, content: String) -> String {
        let session = sessionID ?? "local-\(source)"
        // Bound the content so a huge body doesn't dominate hashing; the leading
        // text plus length is enough to distinguish turns at the same timestamp.
        let contentKey = String(content.prefix(512)) + "#\(content.count)"
        let material = [source, session, sourceTime, contentKey].joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether an event is too old to speak as if new: its source time predates the
    /// newest already-spoken update for the session by more than `threshold`. Such
    /// an event should be filed read rather than narrated.
    public static func isStale(eventTime: Date, newestSpokenTime: Date?, threshold: TimeInterval = 120) -> Bool {
        guard let newestSpokenTime else { return false }
        return eventTime < newestSpokenTime.addingTimeInterval(-threshold)
    }
}
