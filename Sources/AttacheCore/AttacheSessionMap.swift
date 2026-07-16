import Foundation
import CryptoKit

/// One episode in a session map (INF-326). A contiguous range of turns with
/// stable locators, timestamps, content hashes, and bounded lexical terms.
/// Map entries always carry session/range/hash provenance.
public struct AttacheSessionMapEpisode: Equatable, Sendable {
    public let episodeID: String
    public let sessionID: String
    public let sourceKind: String
    public let startTurnOrdinal: Int
    public let endTurnOrdinal: Int
    public let startTimestamp: Date
    public let endTimestamp: Date
    public let turnHashes: [String]
    public let combinedHash: String
    public let lexicalTerms: [String]
    public let topicLabel: String?
    public let mapVersion: Int
    public let isExcluded: Bool
    public let exclusionReason: String?

    public init(
        episodeID: String, sessionID: String, sourceKind: String,
        startTurnOrdinal: Int, endTurnOrdinal: Int,
        startTimestamp: Date, endTimestamp: Date,
        turnHashes: [String], lexicalTerms: [String],
        topicLabel: String? = nil, mapVersion: Int = 1,
        isExcluded: Bool = false, exclusionReason: String? = nil
    ) {
        self.episodeID = episodeID
        self.sessionID = sessionID
        self.sourceKind = sourceKind
        self.startTurnOrdinal = startTurnOrdinal
        self.endTurnOrdinal = endTurnOrdinal
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.turnHashes = turnHashes
        self.combinedHash = AttacheSessionMapEpisode.hash(turnHashes.joined(separator: "|"))
        self.lexicalTerms = lexicalTerms
        self.topicLabel = topicLabel
        self.mapVersion = mapVersion
        self.isExcluded = isExcluded
        self.exclusionReason = exclusionReason
    }

    public static func hash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public var turnCount: Int { endTurnOrdinal - startTurnOrdinal + 1 }
}

/// A turn range for a map query (INF-326).
public struct AttacheSessionMapTurnRange: Equatable, Sendable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

/// A query against the session map (INF-326).
public struct AttacheSessionMapQuery: Equatable, Sendable {
    public let topic: String?
    public let startTime: Date?
    public let endTime: Date?
    public let turnRange: AttacheSessionMapTurnRange?

    public init(topic: String? = nil, startTime: Date? = nil, endTime: Date? = nil, turnRange: AttacheSessionMapTurnRange? = nil) {
        self.topic = topic
        self.startTime = startTime
        self.endTime = endTime
        self.turnRange = turnRange
    }
}

/// Content-free diagnostics for a session map (INF-326).
public struct AttacheSessionMapDiagnostics: Equatable, Sendable {
    public let sessionID: String
    public let mapVersion: Int
    public let episodeCount: Int
    public let totalTurnCount: Int
    public let excludedTurnCount: Int
    public let isComplete: Bool
    public let needsRebuild: Bool
    public let labelSource: String?

    public init(
        sessionID: String, mapVersion: Int, episodeCount: Int,
        totalTurnCount: Int, excludedTurnCount: Int,
        isComplete: Bool, needsRebuild: Bool, labelSource: String?
    ) {
        self.sessionID = sessionID
        self.mapVersion = mapVersion
        self.episodeCount = episodeCount
        self.totalTurnCount = totalTurnCount
        self.excludedTurnCount = excludedTurnCount
        self.isComplete = isComplete
        self.needsRebuild = needsRebuild
        self.labelSource = labelSource
    }
}

/// The full structural map of a session (INF-326). Derived and rebuildable
/// from raw logs. A topic label is navigation metadata, not a factual summary
/// or durable memory. Maps cannot focus a session or authorize their source.
public struct AttacheSessionMap: Equatable, Sendable {
    public let sessionID: String
    public let sourceKind: String
    public let episodes: [AttacheSessionMapEpisode]
    public let mapVersion: Int
    public let totalTurnCount: Int
    public let excludedTurnCount: Int
    public let labelSource: String?

    public init(
        sessionID: String, sourceKind: String,
        episodes: [AttacheSessionMapEpisode], mapVersion: Int = 1,
        totalTurnCount: Int, excludedTurnCount: Int, labelSource: String? = nil
    ) {
        self.sessionID = sessionID
        self.sourceKind = sourceKind
        self.episodes = episodes
        self.mapVersion = mapVersion
        self.totalTurnCount = totalTurnCount
        self.excludedTurnCount = excludedTurnCount
        self.labelSource = labelSource
    }

    /// Query the map by topic, time, or turn range (INF-326).
    public func query(_ q: AttacheSessionMapQuery) -> [AttacheSessionMapEpisode] {
        episodes.filter { episode in
            if episode.isExcluded { return false }
            if let topic = q.topic {
                let labelMatch = episode.topicLabel?.lowercased().contains(topic.lowercased()) ?? false
                let termMatch = episode.lexicalTerms.contains { $0.lowercased().contains(topic.lowercased()) }
                if !labelMatch && !termMatch { return false }
            }
            if let start = q.startTime, episode.endTimestamp < start { return false }
            if let end = q.endTime, episode.startTimestamp > end { return false }
            if let range = q.turnRange {
                if episode.endTurnOrdinal < range.start || episode.startTurnOrdinal > range.end {
                    return false
                }
            }
            return true
        }
    }

    public func diagnostics() -> AttacheSessionMapDiagnostics {
        let covered = episodes.filter { !$0.isExcluded }.reduce(0) { $0 + $1.turnCount }
        let excluded = episodes.filter { $0.isExcluded }.reduce(0) { $0 + $1.turnCount }
        let isComplete = covered + excluded == totalTurnCount
        return AttacheSessionMapDiagnostics(
            sessionID: sessionID, mapVersion: mapVersion,
            episodeCount: episodes.count, totalTurnCount: totalTurnCount,
            excludedTurnCount: excluded, isComplete: isComplete,
            needsRebuild: !isComplete, labelSource: labelSource
        )
    }
}

/// One turn for the map builder (INF-326).
public struct AttacheSessionMapTurn: Equatable, Sendable {
    public let ordinal: Int
    public let role: String
    public let content: String
    public let timestamp: Date
    public let contentHash: String
    public let isPrivateReasoning: Bool
    public let isToolPayload: Bool

    public init(ordinal: Int, role: String, content: String, timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000), isPrivateReasoning: Bool = false, isToolPayload: Bool = false) {
        self.ordinal = ordinal
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.contentHash = AttacheSessionMapEpisode.hash(content)
        self.isPrivateReasoning = isPrivateReasoning
        self.isToolPayload = isToolPayload
    }

    public var isEligible: Bool { !isPrivateReasoning && !isToolPayload }
}

/// The pure session map builder (INF-326). Partitions turns into contiguous
/// episodes with stable locators. Incrementally extends only trailing affected
/// episodes as logs grow. Detects truncation, replacement, and hash mismatch.
/// Excludes private reasoning, secrets, and raw tool payloads from stored
/// terms. No remote topic-label call without explicit consent.
public enum AttacheSessionMapBuilder {

    public static let maxTermsPerEpisode = 10
    public static let maxTermLength = 50
    public static let timeGapThresholdSeconds: TimeInterval = 300 // 5 minutes
    public static let currentMapVersion = 1
    /// Keeps downstream review stages granular even when a transcript has no
    /// natural topic or time boundary. A single larger turn remains one exact
    /// source range and is rejected by the review planner if it cannot fit.
    public static let maxTurnsPerEpisode = 16
    public static let maxCharactersPerEpisode = 24_000

    /// Build a session map from turns (INF-326). Partitions into episodes
    /// based on time gaps, user pivots, and headings. Every eligible turn
    /// belongs to exactly one episode or an explicit excluded category.
    public static func build(
        sessionID: String, sourceKind: String,
        turns: [AttacheSessionMapTurn]
    ) -> AttacheSessionMap {
        let sorted = turns.sorted { $0.ordinal < $1.ordinal }
        var episodes: [AttacheSessionMapEpisode] = []
        var currentEpisode: [AttacheSessionMapTurn] = []
        var currentEpisodeIsExcluded = false
        var excludedCount = 0
        let total = sorted.count

        func flushEpisode() {
            guard !currentEpisode.isEmpty else { return }
            let start = currentEpisode.first!
            let end = currentEpisode.last!
            let terms = currentEpisodeIsExcluded ? [] : extractTerms(from: currentEpisode)
            let hashes = currentEpisode.map { $0.contentHash }
            let episode = AttacheSessionMapEpisode(
                episodeID: "ep-\(start.ordinal)-\(end.ordinal)",
                sessionID: sessionID, sourceKind: sourceKind,
                startTurnOrdinal: start.ordinal, endTurnOrdinal: end.ordinal,
                startTimestamp: start.timestamp, endTimestamp: end.timestamp,
                turnHashes: hashes, lexicalTerms: terms,
                topicLabel: nil, mapVersion: currentMapVersion,
                isExcluded: currentEpisodeIsExcluded,
                exclusionReason: currentEpisodeIsExcluded ? "private-reasoning-or-tool-payload" : nil
            )
            episodes.append(episode)
            currentEpisode = []
            currentEpisodeIsExcluded = false
        }

        for i in 0..<sorted.count {
            let turn = sorted[i]
            if !turn.isEligible {
                if !currentEpisodeIsExcluded {
                    // Flush any current eligible episode before starting an excluded one.
                    flushEpisode()
                    currentEpisodeIsExcluded = true
                }
                currentEpisode.append(turn)
                excludedCount += 1
                // Check if the next turn is eligible; if so, flush the excluded episode.
                if i + 1 >= sorted.count || sorted[i + 1].isEligible {
                    flushEpisode()
                }
                continue
            }
            // Check for episode boundary: time gap or user pivot.
            if !currentEpisode.isEmpty {
                let last = currentEpisode.last!
                let timeGap = turn.timestamp.timeIntervalSince(last.timestamp)
                let isUserPivot = turn.role == "user" && last.role == "assistant"
                    && currentEpisode.last?.role != "user"
                let isHeading = turn.content.hasPrefix("#") || turn.content.hasPrefix("## ")
                let wouldExceedStructuralBound = currentEpisode.count >= maxTurnsPerEpisode
                    || currentEpisode.reduce(0) { $0 + $1.content.count } + turn.content.count
                        > maxCharactersPerEpisode
                if timeGap > timeGapThresholdSeconds || isUserPivot || isHeading
                    || wouldExceedStructuralBound {
                    flushEpisode()
                }
            }
            currentEpisode.append(turn)
        }
        flushEpisode()

        return AttacheSessionMap(
            sessionID: sessionID, sourceKind: sourceKind, episodes: episodes,
            mapVersion: currentMapVersion, totalTurnCount: total,
            excludedTurnCount: excludedCount, labelSource: nil
        )
    }

    /// Incrementally extend a map with new trailing turns (INF-326). Appending
    /// a short tail does not rebuild unchanged early episodes.
    public static func extend(
        existing: AttacheSessionMap,
        newTurns: [AttacheSessionMapTurn]
    ) -> AttacheSessionMap {
        let existingMaxOrdinal = existing.episodes.flatMap { $0.startTurnOrdinal...$0.endTurnOrdinal }.max() ?? -1
        let trulyNew = newTurns.filter { $0.ordinal > existingMaxOrdinal }
        guard !trulyNew.isEmpty else { return existing }
        // Build a map for just the new turns, then concatenate.
        let newMap = build(sessionID: existing.sessionID, sourceKind: existing.sourceKind, turns: trulyNew)
        let allEpisodes = existing.episodes + newMap.episodes
        let total = existing.totalTurnCount + trulyNew.count
        let excluded = existing.excludedTurnCount + newMap.excludedTurnCount
        return AttacheSessionMap(
            sessionID: existing.sessionID, sourceKind: existing.sourceKind,
            episodes: allEpisodes, mapVersion: existing.mapVersion,
            totalTurnCount: total, excludedTurnCount: excluded,
            labelSource: existing.labelSource
        )
    }

    /// Detect truncation or replacement by comparing hashes (INF-326).
    /// Returns the indices of affected episodes, or nil if a full rebuild is
    /// needed (identity uncertain).
    public static func detectAffectedEpisodes(
        existing: AttacheSessionMap,
        currentTurns: [AttacheSessionMapTurn]
    ) -> [Int]? {
        let currentHashByOrdinal = Dictionary(currentTurns.map { ($0.ordinal, $0.contentHash) }, uniquingKeysWith: { a, _ in a })
        var affected: [Int] = []
        for (index, episode) in existing.episodes.enumerated() {
            for (i, hash) in episode.turnHashes.enumerated() {
                let ordinal = episode.startTurnOrdinal + i
                guard let currentHash = currentHashByOrdinal[ordinal] else {
                    // Turn was deleted. If it's in the middle, identity is uncertain.
                    return nil // full rebuild
                }
                if currentHash != hash {
                    affected.append(index)
                    break
                }
            }
        }
        return affected
    }

    /// Extract bounded lexical terms from a set of turns (INF-326). Excludes
    /// private reasoning, secrets, and raw tool payloads. Filters by the
    /// secret filter and limits term count and length.
    public static func extractTerms(from turns: [AttacheSessionMapTurn]) -> [String] {
        var terms: Set<String> = []
        for turn in turns {
            let words = turn.content.split { !$0.isLetter && !$0.isNumber }.map { String($0).lowercased() }
            for word in words {
                guard word.count >= 3, word.count <= maxTermLength else { continue }
                if AttacheMemorySecretFilter.shouldReject(word) { continue }
                terms.insert(word)
                if terms.count >= maxTermsPerEpisode { break }
            }
            if terms.count >= maxTermsPerEpisode { break }
        }
        return Array(terms.sorted().prefix(maxTermsPerEpisode))
    }

    /// True when a topic label request would require a hidden remote call
    /// (INF-326). Topic labels are only allowed through the compiled request
    /// path with explicit provider consent.
    public static func requiresRemoteCallForLabels(
        hasProviderConsent: Bool, hasCompiledBudget: Bool
    ) -> Bool {
        // A hidden background cloud call is forbidden. Labels are only allowed
        // when the provider has consent and a compiled budget exists.
        !(hasProviderConsent && hasCompiledBudget)
    }
}
