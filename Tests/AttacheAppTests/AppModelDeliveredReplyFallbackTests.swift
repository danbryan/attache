import AppKit
import AttacheCore
import XCTest
@testable import AttacheApp

/// INF-396: `narrateDeliveredReplyIfNeeded` generalizes the opencode
/// delivered-reply narration (INF-395) into a shared, source-switched path that
/// also covers `grok_build`. For grok it is a belt-and-suspenders fallback: the
/// live watcher normally narrates the reply, but if it does not (leaving
/// `resulting_card_id` unset), this files the delivered reply through the normal
/// path so `linkResponseCard` can still attach it. It must never double-file a
/// card the watcher already narrated and linked.
@MainActor
final class AppModelDeliveredReplyFallbackTests: XCTestCase {
    /// A disposable Grok home whose transcript carries the assistant reply
    /// appended after the delivery checkpoint, so positional/evidence
    /// correlation can link the fallback card.
    private func makeGrokHome(sessionID: String, reply: String) throws -> (home: URL, checkpoint: Int64) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-grok-fallback-\(UUID().uuidString)", isDirectory: true)
        let sessionDir = home
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("%2FUsers%2Ftester%2Fproject", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let file = sessionDir.appendingPathComponent("chat_history.jsonl")
        let preface = #"{"type":"user","content":[{"type":"text","text":"reply exactly PONG"}]}"# + "\n"
        try preface.write(to: file, atomically: true, encoding: .utf8)
        let checkpoint = Int64((try Data(contentsOf: file)).count)
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data(#"{"type":"assistant","content":"\#(reply)","tool_calls":null}"#.utf8))
        handle.write(Data("\n".utf8))
        try handle.close()
        return (home, checkpoint)
    }

    private func deliveredGrokInstruction(
        id: String, sessionID: String, checkpoint: Int64, reply: String, cardID: String? = nil
    ) -> Instruction {
        Instruction(
            id: id,
            sessionID: sessionID,
            sourceKind: SourceKind.grokBuild.rawValue,
            text: "reply exactly PONG",
            state: .delivered,
            createdAt: Date(),
            deliveredAt: Date(),
            resultingCardID: cardID,
            targetDisplayName: "Grok Build",
            deliveryCheckpoint: checkpoint,
            deliveryReplyText: reply,
            workingDirectory: "/Users/tester/project"
        )
    }

    private func makeModel(store: CardStore) -> AppModel {
        let model = AppModel(store: store)
        // Filing a queued card can post a system notification when voicemailMode
        // is on; the test process has no app bundle, so keep it off (mirrors
        // AppModelSessionPrivacyTests).
        model.voicemailMode = false
        return model
    }

    func testGrokDeliveredReplyFallbackFilesAndLinksCard() async throws {
        _ = NSApplication.shared
        setenv("ATTACHE_FORCE_PLAIN_READBACK", "1", 1)
        defer { unsetenv("ATTACHE_FORCE_PLAIN_READBACK") }
        let sessionID = "grok-fallback-\(UUID().uuidString.lowercased())"
        let (home, checkpoint) = try makeGrokHome(sessionID: sessionID, reply: "Pong from Grok.")
        setenv("GROK_HOME", home.path, 1)
        defer { unsetenv("GROK_HOME") }

        let store = try CardStore.inMemory()
        let delivered = deliveredGrokInstruction(
            id: "instr-1", sessionID: sessionID, checkpoint: checkpoint, reply: "Pong from Grok."
        )
        try store.upsertInstruction(delivered)

        let model = makeModel(store: store)
        XCTAssertTrue(model.cards.filter { $0.externalSessionID == sessionID }.isEmpty)
        XCTAssertTrue(model.twoWay.isDeliveredAwaitingCard(instructionID: "instr-1", sessionID: sessionID))

        model.fileDeliveredReplyFallbackIfUnlinked(delivered)

        try await waitUntil { model.cards.contains { $0.externalSessionID == sessionID } }

        let sessionCards = model.cards.filter { $0.externalSessionID == sessionID }
        XCTAssertEqual(sessionCards.count, 1, "exactly one fallback card should be filed")
        XCTAssertEqual(sessionCards.first?.sourceKind, SourceKind.grokBuild.rawValue)
        XCTAssertTrue(sessionCards.first?.rawText.contains("Pong from Grok.") ?? false)

        // Filed AND linked: the delivered instruction now points at the card, so
        // the f23 "resulting_card_id" is populated.
        let linked = model.twoWay.log.first { $0.id == "instr-1" }
        XCTAssertEqual(linked?.resultingCardID, sessionCards.first?.id)
        XCTAssertFalse(model.twoWay.isDeliveredAwaitingCard(instructionID: "instr-1", sessionID: sessionID))
    }

    func testGrokFallbackDoesNotDoubleFileWhenWatcherAlreadyFiledCard() throws {
        _ = NSApplication.shared
        let sessionID = "grok-nodupe-\(UUID().uuidString.lowercased())"
        let (home, checkpoint) = try makeGrokHome(sessionID: sessionID, reply: "Pong from Grok.")
        setenv("GROK_HOME", home.path, 1)
        defer { unsetenv("GROK_HOME") }

        let store = try CardStore.inMemory()
        // Simulate the live watcher having already narrated and linked its card.
        let delivered = deliveredGrokInstruction(
            id: "instr-2", sessionID: sessionID, checkpoint: checkpoint,
            reply: "Pong from Grok.", cardID: "watcher-card"
        )
        try store.upsertInstruction(delivered)

        let model = makeModel(store: store)
        XCTAssertFalse(model.twoWay.isDeliveredAwaitingCard(instructionID: "instr-2", sessionID: sessionID))
        let before = model.cards.count

        model.fileDeliveredReplyFallbackIfUnlinked(delivered)

        // The guard blocks filing synchronously (no `receive` call), so nothing
        // new lands: the watcher's card is not duplicated.
        XCTAssertEqual(model.cards.count, before)
        XCTAssertTrue(model.cards.filter { $0.externalSessionID == sessionID }.isEmpty)
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping () -> Bool
    ) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("timed out waiting for the fallback card to land")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
