import AppKit
import AttacheCore
import XCTest
@testable import AttacheApp

/// A delivered recap must play through the standard live media surface (the
/// animated Attaché presence, the live transport bar, and captions), not the
/// bespoke voicemail split panel its preparation feedback used (INF-378). The
/// preparation stays on the voicemail surface for the cost preview, progress
/// chip, and any failure/recovery banner; only the successful playback switches
/// to the live surface, so a recap sounds and looks like any other card or live
/// turn.
///
/// These drive `AppModel.deliverRecap` directly with a fixed recap string and a
/// no-model inference, so they never touch a network or presentation model. The
/// controller starts real (muted, then stopped) playback exactly as the
/// `playHistoryCard` reliability tests do, and the synchronous published state
/// on the controller is asserted before teardown.
@MainActor
final class RecapPlaybackSurfaceTests: XCTestCase {
    private func unreadCard(_ index: Int) -> VoicemailCard {
        VoicemailCard(
            id: "src-\(index)",
            sourceID: "s",
            sourceKind: SourceKind.codex.rawValue,
            sourceDisplayName: "Codex",
            sessionID: nil,
            externalSessionID: "session-\(index)",
            projectPath: "/tmp/p\(index)",
            sessionTitle: "Session \(index)",
            kind: .update,
            rawText: "raw update \(index)",
            summary: "update \(index)",
            spokenText: "Update number \(index).",
            status: .unread,
            createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
            heardAt: nil,
            metadataJSON: "{}",
            durationMs: 0,
            alignment: nil
        )
    }

    /// Observes a single synchronous post of `name` across `body`. `deliverRecap`
    /// runs on the calling (main) thread, so a `nil`-queue observer fires inline
    /// with no timed wait.
    private func observingRoute(_ name: Notification.Name, during body: () -> Void) -> Bool {
        var fired = false
        let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
            fired = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        body()
        return fired
    }

    /// A delivered recap routes to the live playback surface, files a heard recap
    /// card as the selected card, and drives the standard playback controller
    /// with the recap's own text and a caption alignment, so the animated
    /// presence and the standard transport render it exactly like a normal card.
    func testDeliveredRecapRoutesToLiveSurfaceAndDrivesStandardController() throws {
        _ = NSApplication.shared
        let store = try CardStore.inMemory()
        let sources = try (0..<2).map { index -> VoicemailCard in
            let event = NormalizedEvent(
                source: SourceKind.codex.rawValue,
                eventType: "agent_message",
                externalSessionID: "session-\(index)",
                title: "Session \(index)",
                text: "Update number \(index)."
            )
            return try store.insertEvent(event)
        }
        let model = AppModel(store: store)
        model.reloadCards()
        defer { model.playback.stop() }

        let recapText = "Two sessions moved: the migration finished and the tests are green."
        let snapshot = model.captureRequestSnapshot(role: .recap, userInput: recapText, personalityOverride: nil)

        let routed = observingRoute(.attacheShowLivePlaybackSurface) {
            model.deliverRecap(
                recapText,
                summarizing: sources,
                personality: nil,
                inference: .noModel(snapshot: snapshot)
            )
        }

        XCTAssertTrue(routed, "a delivered recap must switch to the standard live playback surface")

        let selected = try XCTUnwrap(model.selectedCard, "the recap becomes the selected, playing card")
        XCTAssertEqual(selected.status, .heard, "a recap is filed straight to history, never left unread")
        XCTAssertEqual(
            model.metadataDictionary(for: selected)["attache_recap"], "1",
            "the selected card is the recap"
        )

        // The standard playback controller (the same one the animated presence,
        // transport bar, and captions read) is now driving the recap.
        XCTAssertEqual(model.playback.currentCardID, selected.id)
        XCTAssertEqual(model.playback.currentText, recapText)
        XCTAssertNotNil(model.playback.currentAlignment, "captions need an alignment for the recap text")
    }

    /// The recap's context affordances stay reachable after it plays on the live
    /// surface: it is a heard history card, so the ⌘Y History palette (which
    /// hosts Another Take, the context receipt, and replay) lists it, and
    /// replaying it drives the same standard playback controller.
    func testDeliveredRecapRemainsReachableInHistoryAndReplayable() throws {
        _ = NSApplication.shared
        let store = try CardStore.inMemory()
        let source = try store.insertEvent(NormalizedEvent(
            source: SourceKind.codex.rawValue,
            eventType: "agent_message",
            externalSessionID: "session-x",
            title: "Session X",
            text: "The deploy is out."
        ))
        let model = AppModel(store: store)
        model.reloadCards()
        defer { model.playback.stop() }

        let recapText = "One session moved: the deploy is out."
        let snapshot = model.captureRequestSnapshot(role: .recap, userInput: recapText, personalityOverride: nil)
        model.deliverRecap(
            recapText,
            summarizing: [source],
            personality: nil,
            inference: .noModel(snapshot: snapshot)
        )
        model.playback.stop()

        let recap = try XCTUnwrap(
            model.historyCards(for: .all).first { model.metadataDictionary(for: $0)["attache_recap"] == "1" },
            "the recap is a heard history card the ⌘Y palette reads (its Another Take / receipt / replay live there)"
        )

        // Replaying the recap from History drives the standard playback surface,
        // exactly like any other heard card.
        model.playHistoryCard(recap)
        XCTAssertEqual(model.playback.currentCardID, recap.id)
        XCTAssertEqual(model.playback.currentText, recapText)
    }
}
