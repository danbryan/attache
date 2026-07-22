import AppKit
import XCTest
import AttacheCore
@testable import AttacheApp

/// INF: the watched-session activity ring must derive service labels from an
/// MCP call's structured identity, and the optional smart-ranking pass must
/// never blank the ring or block on a model.
final class ActivityInsightIdentityAndRankingTests: XCTestCase {
    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-activity-identity-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func stamp(_ offsetSeconds: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date().addingTimeInterval(offsetSeconds))
    }

    // MARK: - Regression: a Slack query mentioning "coinbase" reads "checking Slack"

    func testSlackQueryContainingCoinbaseReadsCheckingSlackNotCoinbase() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectsDir = root.appendingPathComponent("projects", isDirectory: true)
        let project = projectsDir.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let sessionID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let parent = project.appendingPathComponent("\(sessionID).jsonl")

        // A real Slack MCP tool call whose ARGUMENTS mention coinbase. The old
        // substring matcher lit up "checking Coinbase"; structured identity must
        // resolve the server (slack-*) and read "checking Slack".
        let line = #"{"type":"assistant","timestamp":"\#(stamp(-1))","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"mcp__slack-bryanlabs-korotovsky__conversations_search_messages","input":{"query":"coinbase invoice"}}]}}"#
        try (line + "\n").write(to: parent, atomically: true, encoding: .utf8)

        let registry = SessionSourceRegistry.production(claudeProjectsDirectory: projectsDir)
        let watcher = SessionActivityWatcher(sourceRegistry: registry)
        var published: [[AgentActivityPhrase]] = []
        watcher.onPhrases = { published.append($0) }

        let target = CodexSessionTarget(id: sessionID, title: "Watched", updatedAt: Date(), category: .activeSession)
        watcher.watch([target])

        let latest = published.last(where: { !$0.isEmpty }) ?? []
        XCTAssertTrue(latest.contains { $0.text == "checking Slack" }, "a Slack MCP call must read 'checking Slack'")
        XCTAssertFalse(latest.contains { $0.text.lowercased().contains("coinbase") }, "no Coinbase label may appear when no Coinbase tool ran")
        watcher.stop()
    }

    // MARK: - Deterministic fallback selection

    func testDeterministicSelectionOrdersByWeightThenRecencyAndCaps() {
        let now = Date()
        let phrases = [
            AgentActivityPhrase(text: "a", weight: 0.3, source: .toolIntent, lastSeen: now.addingTimeInterval(-1)),
            AgentActivityPhrase(text: "b", weight: 0.9, source: .toolIntent, lastSeen: now.addingTimeInterval(-30)),
            AgentActivityPhrase(text: "c", weight: 0.9, source: .toolIntent, lastSeen: now),
            AgentActivityPhrase(text: "d", weight: 0.5, source: .toolIntent, lastSeen: now.addingTimeInterval(-2)),
            AgentActivityPhrase(text: "e", weight: 0.4, source: .toolIntent, lastSeen: now.addingTimeInterval(-3)),
            AgentActivityPhrase(text: "f", weight: 0.1, source: .toolIntent, lastSeen: now.addingTimeInterval(-4)),
        ]
        let selected = AppModel.deterministicActivitySelection(phrases, limit: 3)
        // c and b share top weight; c is more recent, so it wins the tie.
        XCTAssertEqual(selected.map(\.text), ["c", "b", "d"])
    }

    // MARK: - Ranking gate: off or no model -> deterministic, never blank

    @MainActor
    func testRankingGateFallsBackToDeterministicAndNeverBlanks() throws {
        _ = NSApplication.shared
        let model = try AppModel(store: CardStore.inMemory())
        let now = Date()
        // Six distinct labels: more than the display cap, so ranking is eligible.
        let phrases = (0..<6).map { i in
            AgentActivityPhrase(text: "label\(i)", weight: 0.9 - Double(i) * 0.1, source: .toolIntent, lastSeen: now.addingTimeInterval(-Double(i)))
        }
        model.setActivityPhrasesForTesting(phrases)

        // Smart ranking OFF -> no overlay, deterministic top-5 shown.
        model.activitySmartRanking = false
        model.maybeRankActivity()
        XCTAssertNil(model.rankedActivityPhrases)
        XCTAssertEqual(model.displayedActivityPhrases.count, ActivityInsightRanking.maxDisplay)
        XCTAssertFalse(model.displayedActivityPhrases.isEmpty)

        // Smart ranking ON but no model configured (fresh in-memory model) ->
        // still no overlay, deterministic fallback, never blank or blocked.
        model.activitySmartRanking = true
        model.maybeRankActivity()
        XCTAssertNil(model.rankedActivityPhrases)
        XCTAssertEqual(model.displayedActivityPhrases.count, ActivityInsightRanking.maxDisplay)
    }

    @MainActor
    func testAtOrBelowCapShowsEveryLabelWithNoRanking() throws {
        _ = NSApplication.shared
        let model = try AppModel(store: CardStore.inMemory())
        let now = Date()
        let phrases = (0..<3).map { i in
            AgentActivityPhrase(text: "label\(i)", weight: 0.9, source: .toolIntent, lastSeen: now.addingTimeInterval(-Double(i)))
        }
        model.setActivityPhrasesForTesting(phrases)
        model.activitySmartRanking = true
        model.maybeRankActivity()
        XCTAssertNil(model.rankedActivityPhrases)
        XCTAssertEqual(model.displayedActivityPhrases.count, 3)
    }
}
