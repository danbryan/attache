import XCTest
import AttacheCore
@testable import AttacheApp

/// INF-245 (B2): reply correlation is positional, not exact-text. The delivered
/// instruction's transcript checkpoint bounds the search window; the first
/// completed assistant turn found after it belongs to that instruction, even
/// when the narrated card carries presentation-rewritten (paraphrased) text
/// that shares no words with the raw transcript reply.
///
/// A `DynamicCheckpointAdapter` mirrors the real `AgentResumeDeliveryAdapter`'s
/// checkpoint capture (`Self.fileSize(sessionFile)` immediately before resume)
/// so these tests exercise real delivery-checkpoint arithmetic through the real
/// `TwoWayCoordinator`/`InstructionReplyEngine` path, not a hand-rolled stand-in.
private final class DynamicCheckpointAdapter: InstructionDeliveryAdapter, @unchecked Sendable {
    let sourceKind = "codex"
    let sessionFile: URL

    init(sessionFile: URL) { self.sessionFile = sessionFile }

    func capability(forSessionID sessionID: String) -> DeliveryCapability {
        DeliveryCapability(canDeliver: true, requiresIdle: true)
    }

    func deliver(_ instruction: Instruction) async -> Result<DeliveryReceipt, InstructionDeliveryError> {
        let attributes = try? FileManager.default.attributesOfItem(atPath: sessionFile.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return .success(DeliveryReceipt(mechanism: "headless-resume", transcriptCheckpoint: size))
    }
}

@MainActor
final class SessionReplyCorrelationTests: XCTestCase {
    private func makeStore() throws -> CardStore {
        try CardStore(databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-correlation-\(UUID().uuidString).sqlite"))
    }

    // MARK: - Unit level: positional scan ignores text entirely

    func testFirstCompletedAssistantTurnFindsReplyRegardlessOfAnyExpectedText() {
        let transcript = """
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"make a change"}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"text":"Finished the requested change."}]}}
        """
        let reply = SessionReplyCorrelation.firstCompletedAssistantTurn(transcriptText: transcript, format: .codex)
        XCTAssertEqual(reply, "Finished the requested change.")

        // textConfirms is a secondary confidence signal only; a mismatch here
        // must never be treated as a reason to withhold the link (checked at
        // the coordinator level below).
        XCTAssertFalse(SessionReplyCorrelation.textConfirms(
            eventText: "All done - I made the change you asked for.",
            replyText: reply!
        ))
        XCTAssertTrue(SessionReplyCorrelation.textConfirms(
            eventText: "Finished the requested change.",
            replyText: reply!
        ))
    }

    func testFirstCompletedAssistantTurnHandlesClaudeToolUseBeforeFinalText() {
        let transcript = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash"}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Ran the tests; all green."}]}}
        """
        let reply = SessionReplyCorrelation.firstCompletedAssistantTurn(transcriptText: transcript, format: .claude)
        XCTAssertEqual(reply, "Ran the tests; all green.")
    }

    // MARK: - Success criterion 1: paraphrase must not block the link

    func testPositionalMatchLinksDespitePresentationParaphrase() async throws {
        let store = try makeStore()
        let sessionFile = FileManager.default.temporaryDirectory.appendingPathComponent("sess-\(UUID().uuidString).jsonl")
        try writeReadyCodexSession(to: sessionFile)
        let coordinator = TwoWayCoordinator(
            store: store,
            locateSessionFile: { _ in sessionFile },
            quietWindow: 0,
            adapters: [DynamicCheckpointAdapter(sessionFile: sessionFile)]
        )
        coordinator.setEnabled(true, sessionID: "s1")
        let instruction = try coordinator.prepare(text: "make a change", sessionID: "s1", sourceKind: "codex")
        try await coordinator.confirmAndDeliver(id: instruction.id)

        // Before the reply lands, an event at the checkpoint itself (no room for
        // a completed turn yet) must not link.
        let checkpoint = try XCTUnwrap(coordinator.log.first(where: { $0.id == instruction.id })?.deliveryCheckpoint)
        coordinator.linkResponseCard(
            cardID: "too-early",
            sessionID: "s1",
            eventText: "anything",
            transcriptEndOffset: checkpoint
        )
        XCTAssertNil(coordinator.log.first(where: { $0.id == instruction.id })?.resultingCardID)

        try append(
            """
            {"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"make a change"}]}}
            {"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"text":"Finished the requested change."}]}}

            """,
            to: sessionFile
        )
        let endOffset = try fileSize(sessionFile)

        // A personality could paraphrase the raw reply into something with no
        // words in common; this is exactly the text AppModel passes as
        // eventText in production (the presentation-rewritten card text), and
        // it must still link because correlation is positional.
        coordinator.linkResponseCard(
            cardID: "card-paraphrased",
            sessionID: "s1",
            eventText: "All done - I made the change you asked for.",
            transcriptEndOffset: endOffset
        )

        XCTAssertEqual(coordinator.log.first(where: { $0.id == instruction.id })?.resultingCardID, "card-paraphrased")
    }

    // MARK: - Success criterion 2: FIFO + position, never crossed

    func testFIFOPositionalCorrelationLinksCorrectReplies() async throws {
        let store = try makeStore()
        let sessionFile = FileManager.default.temporaryDirectory.appendingPathComponent("sess-\(UUID().uuidString).jsonl")
        try writeReadyCodexSession(to: sessionFile)
        let coordinator = TwoWayCoordinator(
            store: store,
            locateSessionFile: { _ in sessionFile },
            quietWindow: 0,
            adapters: [DynamicCheckpointAdapter(sessionFile: sessionFile)]
        )
        coordinator.setEnabled(true, sessionID: "s1")

        // Instruction A delivered first; its checkpoint is the file state
        // before its reply lands.
        let instructionA = try coordinator.prepare(text: "first change", sessionID: "s1", sourceKind: "codex")
        try await coordinator.confirmAndDeliver(id: instructionA.id)

        try append(codexReply("Reply to first change."), to: sessionFile)
        let offsetAfterFirstReply = try fileSize(sessionFile)

        // Instruction B is delivered only after A's reply has already landed
        // (the engine's single-flight FIFO invariant), so B's checkpoint is
        // strictly after A's reply.
        let instructionB = try coordinator.prepare(text: "second change", sessionID: "s1", sourceKind: "codex")
        try await coordinator.confirmAndDeliver(id: instructionB.id)

        try append(codexReply("Reply to second change."), to: sessionFile)
        let offsetAfterSecondReply = try fileSize(sessionFile)

        // The transcript watcher observes A's turn first...
        coordinator.linkResponseCard(
            cardID: "card-first",
            sessionID: "s1",
            eventText: "Reply to first change.",
            transcriptEndOffset: offsetAfterFirstReply
        )
        // ...then B's turn.
        coordinator.linkResponseCard(
            cardID: "card-second",
            sessionID: "s1",
            eventText: "Reply to second change.",
            transcriptEndOffset: offsetAfterSecondReply
        )

        XCTAssertEqual(coordinator.log.first(where: { $0.id == instructionA.id })?.resultingCardID, "card-first")
        XCTAssertEqual(coordinator.log.first(where: { $0.id == instructionB.id })?.resultingCardID, "card-second")
    }

    // MARK: - Success criterion 3 (cross-check): delivery evidence unblocks a
    // link the transcript watcher hasn't caught up to yet.

    func testDeliveryEvidenceCrossCheckLinksWhenTranscriptSliceIsEmpty() async throws {
        let store = try makeStore()
        let sessionFile = FileManager.default.temporaryDirectory.appendingPathComponent("sess-\(UUID().uuidString).jsonl")
        try writeReadyCodexSession(to: sessionFile)
        let coordinator = TwoWayCoordinator(
            store: store,
            locateSessionFile: { _ in sessionFile },
            quietWindow: 0,
            adapters: [StubEvidenceAdapter(sessionFile: sessionFile, replyText: "Reply captured at delivery time.")]
        )
        coordinator.setEnabled(true, sessionID: "s1")
        let instruction = try coordinator.prepare(text: "do the thing", sessionID: "s1", sourceKind: "codex")
        try await coordinator.confirmAndDeliver(id: instruction.id)
        let checkpoint = try XCTUnwrap(coordinator.log.first(where: { $0.id == instruction.id })?.deliveryCheckpoint)
        XCTAssertEqual(
            coordinator.log.first(where: { $0.id == instruction.id })?.deliveryReplyText,
            "Reply captured at delivery time."
        )

        // No transcript bytes have actually been appended yet (the watcher is
        // lagging the delivery), but the event's own reported offset is past
        // the checkpoint (e.g. driven by some other session activity's
        // bookkeeping). The delivery adapter's own captured evidence must still
        // let this resolve rather than waiting on a transcript scan that will
        // never find anything at this offset.
        coordinator.linkResponseCard(
            cardID: "card-early",
            sessionID: "s1",
            eventText: "whatever the future narration ends up saying",
            transcriptEndOffset: checkpoint + 1
        )

        XCTAssertEqual(coordinator.log.first(where: { $0.id == instruction.id })?.resultingCardID, "card-early")
    }

    // MARK: - Helpers

    private final class StubEvidenceAdapter: InstructionDeliveryAdapter, @unchecked Sendable {
        let sourceKind = "codex"
        let sessionFile: URL
        let replyText: String

        init(sessionFile: URL, replyText: String) {
            self.sessionFile = sessionFile
            self.replyText = replyText
        }

        func capability(forSessionID sessionID: String) -> DeliveryCapability {
            DeliveryCapability(canDeliver: true, requiresIdle: true)
        }

        func deliver(_ instruction: Instruction) async -> Result<DeliveryReceipt, InstructionDeliveryError> {
            let attributes = try? FileManager.default.attributesOfItem(atPath: sessionFile.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return .success(DeliveryReceipt(mechanism: "headless-resume", transcriptCheckpoint: size, replyText: replyText))
        }
    }

    private func writeReadyCodexSession(to url: URL) throws {
        try Data("""
        {"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"text":"Ready."}]}}

        """.utf8).write(to: url)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        Int64(try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).int64Value)
    }

    private func codexReply(_ text: String) -> String {
        """
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"resume"}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"text":"\(text)"}]}}

        """
    }
}
