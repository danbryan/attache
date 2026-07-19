import AppKit
import AttacheCore
import XCTest
@testable import AttacheApp

/// End-to-end mapping from a Codex notify payload to Attaché activity state: the
/// JSON the notify program POSTs is ingested by the same path Claude hooks use
/// and drives the session's attention/status, and (critically) its non-empty
/// placeholder text survives `EventNormalizer` while creating no voicemail card.
@MainActor
final class CodexNotifyEventMappingTests: XCTestCase {
    private func makeModel() throws -> AppModel {
        // Force NSApp to exist before AppModel touches appearance (mirrors the
        // other AppModel tests), so a headless run does not crash on NSApp.
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-codex-notify-\(UUID().uuidString).sqlite")
        let model = AppModel(store: try CardStore(databaseURL: url))
        model.voicemailMode = false
        return model
    }

    /// The exact JSON body `CodexNotifySetup.bodyPython` emits for a completed
    /// Codex turn.
    private func notifyBody(sessionID: String) -> Data {
        Data(#"{"source":"codex","event_type":"turn_complete","external_session_id":"\#(sessionID)","project_path":"/p","title":"Codex","text":"Codex finished a turn.","metadata":{"adapter":"codex-notify"}}"#.utf8)
    }

    func testTurnCompletePayloadDrivesAttentionAndMakesNoCard() throws {
        let model = try makeModel()
        let sessionID = "019f765a-3d95-7c20-8497-e100ad479dc9"
        let cardsBefore = model.cards.count

        model.ingestEventData(notifyBody(sessionID: sessionID))

        XCTAssertEqual(model.sessionAttention[sessionID], .turnComplete,
                       "a Codex notify turn-complete must drive the session to turnComplete")
        XCTAssertEqual(model.cards.count, cardsBefore,
                       "a lifecycle status event must not create a voicemail card")
    }

    func testCelebrateMomentOnActiveToTurnComplete() throws {
        let model = try makeModel()
        let sessionID = "celebrate-session"
        // Prime the session as active (as the transcript watcher would), then
        // deliver the exact-completion notify.
        model.receive(NormalizedEvent(
            source: SourceKind.codex.rawValue,
            eventType: "turn_started",
            externalSessionID: sessionID,
            title: "Codex",
            text: "working"
        ))
        XCTAssertEqual(model.sessionAttention[sessionID], .active)

        model.ingestEventData(notifyBody(sessionID: sessionID))
        XCTAssertEqual(model.sessionAttention[sessionID], .turnComplete)
    }
}
