import AppKit
import AttacheCore
import SQLite3
import XCTest
@testable import AttacheApp

/// Forces the next DELETE through a `CardStore` under test to fail. Mirrors
/// `InstructionReplyEngineTests.breakInstructionWrites`: a `CardStore` keeps
/// one SQLite connection open for its whole lifetime, so filesystem
/// permission tricks (chmod/chflags) are enforced only at `open()` and do
/// nothing to an already-open, already-writable handle. Instead, open an
/// independent second connection to the same on-disk file and install a
/// `BEFORE DELETE` trigger on `cards` that always aborts, so the next
/// `deleteCards` call fails with a real, surfaced SQLite error rather than
/// crashing the test process.
private func breakCardDeletes(atPath path: String) {
    var handle: OpaquePointer?
    guard sqlite3_open(path, &handle) == SQLITE_OK else {
        XCTFail("failed to open a second connection to \(path)")
        return
    }
    defer { sqlite3_close(handle) }
    let sql = """
        CREATE TRIGGER test_break_cards_delete BEFORE DELETE ON cards
        BEGIN SELECT RAISE(ABORT, 'induced delete failure'); END;
        """
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
        let message = handle.flatMap { sqlite3_errmsg($0).map { String(cString: $0) } } ?? "unknown"
        XCTFail("failed to install a write-breaking trigger: \(message)")
        return
    }
}

/// Covers INF-355: the mid-call saved-to-private switch
/// (`AppModel.convertActiveCallToPrivate()`), its fail-closed failure path,
/// and the one-way door (no private-to-saved API).
@MainActor
final class AppModelPrivateCallConversionTests: XCTestCase {
    private func makeFileBackedStore() throws -> CardStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-private-conversion-\(UUID().uuidString).sqlite")
        return try CardStore(databaseURL: url)
    }

    private func directChatDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-direct-chat-conversion-\(UUID().uuidString).sqlite")
    }

    private func cardEvent(conversationID: String, kind: String, text: String) -> NormalizedEvent {
        NormalizedEvent(
            source: SourceKind.generic.rawValue,
            eventType: "attache.conversation.reply",
            title: "Attaché reply",
            text: text,
            metadata: [
                "attache_history_kind": kind,
                "attache_conversation_id": conversationID
            ]
        )
    }

    private func capsule(callID: String, id: String) -> AttacheDirectChatSummaryCapsule {
        let receipt = ContextReceipt(
            includedSources: [], omittedSources: [], truncatedSources: [],
            totalEstimatedTokens: 1, remainingBudget: 1,
            modelIdentityKey: "local", strategyKind: "automatic",
            stagedProcessingRequired: false
        )
        return AttacheDirectChatSummaryCapsule(
            id: id, segmentID: "\(id)-segment",
            startTurnIndex: 0, endTurnIndex: 0,
            sourceHash: "\(id)-hash", establishedFacts: ["a fact"],
            decisions: [], openQuestions: [], corrections: [],
            unresolvedCommitments: [], summarizerVersion: "v1",
            modelIdentityKey: "local", receipt: receipt, callID: callID
        )
    }

    // MARK: - Successful conversion: full retroactive scrub

    func testConvertActiveCallToPrivateDeletesEveryLinkedCardCapsuleAndAlternateTake() throws {
        _ = NSApplication.shared
        let store = try CardStore.inMemory()
        let directChatURL = directChatDatabaseURL()
        let model = AppModel(store: store, directChatDatabaseURLOverride: directChatURL)

        model.startConversation()
        guard let conversationID = model.activeConversationID else {
            return XCTFail("starting a saved conversation must freeze an active conversation id")
        }
        defer { model.endConversation() }
        let conversationIDString = conversationID.uuidString

        // 3 cards linked to this conversation.
        _ = try store.insertEvent(cardEvent(conversationID: conversationIDString, kind: "direct_reply", text: "First answer"))
        _ = try store.insertEvent(cardEvent(conversationID: conversationIDString, kind: "direct_reply", text: "Second answer"))
        _ = try store.insertEvent(cardEvent(conversationID: conversationIDString, kind: "direct_reply", text: "Third answer"))
        // 1 alternate take linked to the same conversation (another-take cards
        // carry the same attache_conversation_id, see AttachePresentationService.anotherTakeEvent).
        _ = try store.insertEvent(cardEvent(conversationID: conversationIDString, kind: "direct_reply", text: "Another take"))
        // An unrelated card in a different conversation must survive.
        let otherConversationCard = try store.insertEvent(cardEvent(conversationID: UUID().uuidString, kind: "direct_reply", text: "Unrelated"))

        // 2 direct-chat capsules linked to this conversation's call id.
        let directChatStore = AttacheDirectChatSummaryStore(databaseURL: directChatURL)
        XCTAssertTrue(directChatStore.add(capsule(callID: conversationIDString, id: "capsule-1")))
        XCTAssertTrue(directChatStore.add(capsule(callID: conversationIDString, id: "capsule-2")))
        XCTAssertEqual(directChatStore.count(callID: conversationIDString), 2)

        let converted = model.convertActiveCallToPrivate()

        XCTAssertTrue(converted)
        XCTAssertTrue(model.isPrivateConversation)
        XCTAssertEqual(model.conversationStorageMode, .privateCall)

        let remainingCards = try store.fetchCards(includeArchived: true)
        XCTAssertEqual(remainingCards.map(\.id), [otherConversationCard.id])
        XCTAssertEqual(directChatStore.count(callID: conversationIDString), 0)
    }

    // MARK: - Fail-closed: deletion failure leaves the call saved

    func testConvertActiveCallToPrivateFailureLeavesCallSavedAndSurfacesStatus() throws {
        _ = NSApplication.shared
        let store = try makeFileBackedStore()
        let model = AppModel(store: store, directChatDatabaseURLOverride: directChatDatabaseURL())

        model.startConversation()
        guard let conversationID = model.activeConversationID else {
            return XCTFail("starting a saved conversation must freeze an active conversation id")
        }
        defer { model.endConversation() }
        let conversationIDString = conversationID.uuidString

        _ = try store.insertEvent(cardEvent(conversationID: conversationIDString, kind: "direct_reply", text: "Only answer"))
        breakCardDeletes(atPath: store.databasePath)

        let converted = model.convertActiveCallToPrivate()

        XCTAssertFalse(converted)
        XCTAssertFalse(model.isPrivateConversation)
        XCTAssertEqual(model.conversationStorageMode, .saved)
        XCTAssertTrue(
            model.conversationStatus.contains("Still recorded"),
            "expected the fail-closed status to say the call is still recorded, got: \(model.conversationStatus)"
        )

        // The card the induced failure was supposed to delete is untouched:
        // conversion never got as far as reporting success with stale data left behind.
        let remainingCards = try store.fetchCards(includeArchived: true)
        XCTAssertEqual(remainingCards.count, 1)
    }

    // MARK: - Post-conversion turns persist nothing

    func testConvertActiveCallToPrivateStopsFuturePersistenceImmediately() throws {
        _ = NSApplication.shared
        let store = try CardStore.inMemory()
        let model = AppModel(store: store, directChatDatabaseURLOverride: directChatDatabaseURL())

        model.startConversation()
        XCTAssertTrue(model.conversationSavesHistory)

        let converted = model.convertActiveCallToPrivate()
        defer { model.endConversation() }

        XCTAssertTrue(converted)
        // conversationSavesHistory/conversationAllowsMemoryProposals both gate
        // on conversationStorageMode == .saved; once conversion flips it to
        // .privateCall every later turn in this call takes the same
        // write-nothing path a call that started private would.
        XCTAssertFalse(model.conversationSavesHistory)
        XCTAssertFalse(model.conversationAllowsMemoryProposals)
        XCTAssertFalse(model.canSendToAgent)
    }

    // MARK: - One-way door: no private-to-saved transition

    func testConvertActiveCallToPrivateIsAOneWayDoorNotReversible() throws {
        _ = NSApplication.shared
        let model = AppModel(store: try CardStore.inMemory())

        model.startConversation(storageMode: .privateCall)
        defer { model.endConversation() }
        XCTAssertTrue(model.isPrivateConversation)

        // convertActiveCallToPrivate() is the ONLY API that can move
        // conversationStorageMode away from .saved mid-call, and it is
        // guarded to require conversationStorageMode == .saved (AppModel.swift).
        // Calling it on an already-private call is therefore a no-op: there is
        // no private-to-saved transition anywhere in AppModel. (grep across
        // AppModel.swift confirms `conversationStorageMode =` appears at
        // exactly three sites: startConversation's initial freeze,
        // endConversation's post-hangup reset for the NEXT call, and
        // convertActiveCallToPrivate's own saved->private freeze plus its
        // rollback on failure, which only reverts an attempt that never
        // succeeded, not an established private call.)
        let reverted = model.convertActiveCallToPrivate()

        XCTAssertFalse(reverted)
        XCTAssertTrue(model.isPrivateConversation)
        XCTAssertEqual(model.conversationStorageMode, .privateCall)
    }

    // MARK: - Idle guard: no active call, or already-private call

    func testConvertActiveCallToPrivateIsANoOpWithNoActiveCall() throws {
        _ = NSApplication.shared
        let model = AppModel(store: try CardStore.inMemory())

        XCTAssertFalse(model.conversationActive)
        let converted = model.convertActiveCallToPrivate()

        XCTAssertFalse(converted)
        XCTAssertEqual(model.conversationStorageMode, .saved)
    }
}
