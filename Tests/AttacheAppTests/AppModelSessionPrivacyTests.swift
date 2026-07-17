import AppKit
import AttacheCore
import SQLite3
import XCTest
@testable import AttacheApp

/// Forces the next DELETE through a `CardStore` under test to fail. Mirrors
/// `AppModelPrivateCallConversionTests.breakCardDeletes` (INF-355): a
/// `CardStore` keeps one SQLite connection open for its whole lifetime, so a
/// second connection installs a `BEFORE DELETE` trigger on `cards` that
/// always aborts.
private func breakCardDeletes(atPath path: String) {
    var handle: OpaquePointer?
    guard sqlite3_open(path, &handle) == SQLITE_OK else {
        XCTFail("failed to open a second connection to \(path)")
        return
    }
    defer { sqlite3_close(handle) }
    let sql = """
        CREATE TRIGGER test_break_privacy_cards_delete BEFORE DELETE ON cards
        BEGIN SELECT RAISE(ABORT, 'induced delete failure'); END;
        """
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
        let message = handle.flatMap { sqlite3_errmsg($0).map { String(cString: $0) } } ?? "unknown"
        XCTFail("failed to install a write-breaking trigger: \(message)")
        return
    }
}

/// Covers INF-357: the per-session "do not record" toggle, its gate on new
/// event persistence, and the "Forget This Session…" retroactive scrub,
/// including its fail-closed failure path.
@MainActor
final class AppModelSessionPrivacyTests: XCTestCase {
    private func makeFileBackedStore() throws -> CardStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-session-privacy-\(UUID().uuidString).sqlite")
        return try CardStore(databaseURL: url)
    }

    private func registryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-session-privacy-registry-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("SessionPrivacyRegistry.json")
    }

    private func makeModel(store: CardStore) -> AppModel {
        let model = AppModel(store: store, sessionPrivacyRegistryURLOverride: registryURL())
        // Persisting a queued card can post a system notification when
        // voicemailMode is on; the test process has no app bundle, so
        // UNUserNotificationCenter throws. Off is enough to exercise
        // `persist`'s don't-record gate without that unrelated crash.
        model.voicemailMode = false
        return model
    }

    private func event(sessionID: String, text: String) -> NormalizedEvent {
        NormalizedEvent(
            source: SourceKind.codex.rawValue,
            eventType: "agent_message",
            externalSessionID: sessionID,
            title: "Codex update",
            text: text
        )
    }

    // MARK: - Registry round trip through AppModel

    func testSetSessionDoNotRecordTogglesAndPersistsThroughTheModel() throws {
        _ = NSApplication.shared
        let model = makeModel(store: try CardStore.inMemory())
        let sessionID = "session-toggle"

        XCTAssertFalse(model.isSessionRecordingDisabled(sessionID: sessionID))
        XCTAssertTrue(model.setSessionDoNotRecord(true, sessionID: sessionID))
        XCTAssertTrue(model.isSessionRecordingDisabled(sessionID: sessionID))
        XCTAssertTrue(model.setSessionDoNotRecord(false, sessionID: sessionID))
        XCTAssertFalse(model.isSessionRecordingDisabled(sessionID: sessionID))
    }

    // MARK: - Don't-record gate on new persistence

    func testDontRecordSessionProducesNoPersistedCard() throws {
        _ = NSApplication.shared
        let store = try CardStore.inMemory()
        let model = makeModel(store: store)
        let sessionID = "session-do-not-record"
        model.setSessionDoNotRecord(true, sessionID: sessionID)

        model.persist(event(sessionID: sessionID, text: "Ran the build and it passed."))

        let cards = try store.fetchCards(forExternalSessionID: sessionID)
        XCTAssertTrue(cards.isEmpty, "a don't-record session must never gain a persisted card")
        XCTAssertTrue(
            model.intakeStatus.contains("not-recorded") || model.intakeStatus.contains("Not recorded"),
            "expected status to reflect nothing was saved, got: \(model.intakeStatus)"
        )
    }

    func testOrdinarySessionStillPersistsNormally() throws {
        _ = NSApplication.shared
        let store = try CardStore.inMemory()
        let model = makeModel(store: store)
        let sessionID = "session-normal"

        model.persist(event(sessionID: sessionID, text: "Ran the build and it passed."))

        let cards = try store.fetchCards(forExternalSessionID: sessionID)
        XCTAssertEqual(cards.count, 1)
    }

    func testTogglingOffResumesPersistenceForNewEventsOnlyOldOnesStayGone() throws {
        _ = NSApplication.shared
        let store = try CardStore.inMemory()
        let model = makeModel(store: store)
        let sessionID = "session-resume"

        // An event before the session was ever marked "do not record" persists.
        model.persist(event(sessionID: sessionID, text: "Before toggling on"))
        XCTAssertEqual(try store.fetchCards(forExternalSessionID: sessionID).count, 1)

        model.setSessionDoNotRecord(true, sessionID: sessionID)
        model.persist(event(sessionID: sessionID, text: "While disabled"))
        // The "while disabled" event never became a card; only the earlier one exists.
        XCTAssertEqual(try store.fetchCards(forExternalSessionID: sessionID).count, 1)

        model.setSessionDoNotRecord(false, sessionID: sessionID)
        model.persist(event(sessionID: sessionID, text: "After toggling off"))
        let cards = try store.fetchCards(forExternalSessionID: sessionID)
        XCTAssertEqual(cards.count, 2, "toggling off must resume persistence for NEW events")
        XCTAssertTrue(cards.contains { $0.rawText.contains("Before toggling on") })
        XCTAssertTrue(cards.contains { $0.rawText.contains("After toggling off") })
        XCTAssertFalse(
            cards.contains { $0.rawText.contains("While disabled") },
            "an event skipped while disabled must never retroactively appear"
        )
    }

    // MARK: - Forget Session: successful retroactive scrub

    func testForgetSessionDeletesEveryLinkedCard() throws {
        _ = NSApplication.shared
        let store = try CardStore.inMemory()
        let model = makeModel(store: store)
        let sessionID = "session-forget"
        let otherSessionID = "session-keep"

        _ = try store.insertEvent(event(sessionID: sessionID, text: "First update"))
        _ = try store.insertEvent(event(sessionID: sessionID, text: "Second update"))
        let otherCard = try store.insertEvent(event(sessionID: otherSessionID, text: "Unrelated"))

        let counts = model.forgetSessionImpactCounts(externalSessionID: sessionID)
        XCTAssertEqual(counts.cards, 2)

        let forgotten = model.forgetSession(externalSessionID: sessionID)

        XCTAssertTrue(forgotten)
        XCTAssertTrue(try store.fetchCards(forExternalSessionID: sessionID).isEmpty)
        let remaining = try store.fetchCards(includeArchived: true)
        XCTAssertEqual(remaining.map(\.id), [otherCard.id])
        XCTAssertTrue(
            model.conversationStatus.contains("Forgot"),
            "expected a success status, got: \(model.conversationStatus)"
        )
    }

    // MARK: - Forget Session: fail closed

    func testForgetSessionFailureLeavesCardsIntactAndSurfacesStillRecorded() throws {
        _ = NSApplication.shared
        let store = try makeFileBackedStore()
        let model = makeModel(store: store)
        let sessionID = "session-forget-failure"

        _ = try store.insertEvent(event(sessionID: sessionID, text: "Only update"))
        breakCardDeletes(atPath: store.databasePath)

        let forgotten = model.forgetSession(externalSessionID: sessionID)

        XCTAssertFalse(forgotten)
        XCTAssertTrue(
            model.conversationStatus.contains("Still recorded"),
            "expected the fail-closed status to say the session is still recorded, got: \(model.conversationStatus)"
        )
        // The card the induced failure was supposed to delete is untouched.
        let remaining = try store.fetchCards(forExternalSessionID: sessionID)
        XCTAssertEqual(remaining.count, 1)
    }

    func testForgetSessionOnEmptySessionIsANoOpSuccess() throws {
        _ = NSApplication.shared
        let model = makeModel(store: try CardStore.inMemory())
        XCTAssertTrue(model.forgetSession(externalSessionID: "never-had-anything"))
    }
}
