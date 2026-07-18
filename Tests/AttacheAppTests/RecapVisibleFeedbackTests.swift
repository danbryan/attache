import AttacheCore
import XCTest
@testable import AttacheApp

/// INF-378: a recap of a large selection used to do nothing the user could
/// see. The recap is launched from the ⌘I inbox palette and the dock, but its
/// only feedback surfaces (the cost-preview banner, the preparing/writing
/// progress chip, and any failure/recovery banner) live in the voicemail
/// inbox panel, which neither launch point presents. Above 40 items the recap
/// deferred to the cost-preview banner and, with no visible host, silently did
/// nothing. These tests pin the fix: every non-empty recap routes to the
/// voicemail surface and enters a visible state, and an empty recap does not.
///
/// They drive `AppModel.playInboxRecap(for:)` directly. The cost-preview
/// branch and the empty guard both return before any model call or network,
/// so these stay fast and hermetic.
@MainActor
final class RecapVisibleFeedbackTests: XCTestCase {
    private static let touchedKeys = [
        AttachePreferenceKey.presentationLLMEnabled,
        AttachePreferenceKey.presentationLLMProvider,
        AttachePreferenceKey.presentationLLMModel,
        AttachePreferenceKey.presentationLLMBaseURL,
        AttachePreferenceKey.presentationLLMRoleKey(.recap, .provider),
        AttachePreferenceKey.presentationLLMRoleKey(.recap, .model)
    ]

    private func restoringDefaults(_ body: () throws -> Void) rethrows {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        var saved: [String: Any] = [:]
        for key in Self.touchedKeys where defaults.object(forKey: key) != nil {
            saved[key] = defaults.object(forKey: key)
        }
        defer {
            for key in Self.touchedKeys {
                if let value = saved[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        try body()
    }

    /// A local Ollama provider needs no API key, so recap presentation reads as
    /// configured and `playInboxRecap` reaches the staging decision (and thus
    /// the cost-preview branch) rather than the deterministic-digest fallback.
    private func configureLocalPresentation() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: AttachePreferenceKey.presentationLLMEnabled)
        defaults.set(AttachePresentationProvider.ollama.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        defaults.set(AttachePresentationProvider.ollama.defaultModel, forKey: AttachePreferenceKey.presentationLLMModel)
        defaults.set(AttachePresentationProvider.ollama.defaultBaseURL, forKey: AttachePreferenceKey.presentationLLMBaseURL)
        // No per-role recap override, so recap resolves the local provider too.
        defaults.removeObject(forKey: AttachePreferenceKey.presentationLLMRoleKey(.recap, .provider))
        defaults.removeObject(forKey: AttachePreferenceKey.presentationLLMRoleKey(.recap, .model))
    }

    private func card(_ index: Int) -> VoicemailCard {
        VoicemailCard(
            id: "card-\(index)",
            sourceID: "s",
            sourceKind: SourceKind.codex.rawValue,
            sourceDisplayName: "Codex",
            sessionID: nil,
            externalSessionID: "session-\(index % 3)",
            projectPath: "/tmp/p\(index % 3)",
            sessionTitle: "Session \(index % 3)",
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

    /// Observes a single synchronous post of `name` across `body`. The recap
    /// posts on the calling (main) thread, so a `nil`-queue observer fires
    /// inline and no timed wait is needed.
    private func observingRoute(_ name: Notification.Name, during body: () -> Void) -> Bool {
        var fired = false
        let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
            fired = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        body()
        return fired
    }

    // A large selection (past the 40-item cost-preview threshold) must route
    // to the voicemail surface AND raise the cost-preview banner, so the gate
    // is visible instead of silently swallowing the recap. This is the exact
    // 42-fails/40-works regression from the report.
    func testLargeSelectionRoutesToVoicemailSurfaceAndShowsCostPreview() throws {
        try restoringDefaults {
            configureLocalPresentation()
            let model = try AppModel(store: CardStore.inMemory())
            let cards = (0..<42).map(card)

            let routed = observingRoute(.attacheOpenVoicemailSurface) {
                model.playInboxRecap(for: cards)
            }

            XCTAssertTrue(routed, "a large recap must present the surface that hosts its feedback")
            let preview = try XCTUnwrap(model.recapCostPreview, "past 40 items the cost-preview banner must appear")
            XCTAssertEqual(preview.itemCount, 42)
            XCTAssertFalse(model.recapInProgress, "the banner is the visible feedback while awaiting the Start decision")
            XCTAssertTrue(
                model.intakeStatus.contains("model call"),
                "the status must explain the cost, got: \(model.intakeStatus)"
            )
        }
    }

    // Any non-empty recap must enter a visible state (either the progress chip
    // or the cost-preview banner) and route to the surface hosting it, so
    // clicking Recap is never a silent no-op regardless of selection size.
    func testNonEmptyRecapNeverSilent() throws {
        try restoringDefaults {
            configureLocalPresentation()
            let model = try AppModel(store: CardStore.inMemory())
            let cards = (0..<3).map(card)

            let routed = observingRoute(.attacheOpenVoicemailSurface) {
                model.playInboxRecap(for: cards)
            }

            XCTAssertTrue(routed)
            XCTAssertTrue(
                model.recapInProgress || model.recapCostPreview != nil,
                "a recap must show progress or a cost preview, never nothing"
            )
            XCTAssertFalse(model.intakeStatus.isEmpty)
        }
    }

    // An empty recap must not switch surfaces or claim progress: there is
    // nothing to recap, matching the pre-fix early return.
    func testEmptyRecapDoesNotRouteOrEnterProgress() throws {
        try restoringDefaults {
            configureLocalPresentation()
            let model = try AppModel(store: CardStore.inMemory())

            let routed = observingRoute(.attacheOpenVoicemailSurface) {
                model.playInboxRecap(for: [])
            }

            XCTAssertFalse(routed, "an empty recap has no feedback to show, so it must not force a surface switch")
            XCTAssertNil(model.recapCostPreview)
            XCTAssertFalse(model.recapInProgress)
        }
    }

    // The unconfigured-presentation fallback (deterministic digest) must still
    // report a visible status rather than failing silently.
    func testUnconfiguredRecapReportsVisibleStatus() throws {
        try restoringDefaults {
            configureLocalPresentation()
            // Force the not-configured branch: an API-key provider with no key
            // is not `hasProviderConfiguration`, so recap falls back to the
            // deterministic digest.
            UserDefaults.standard.set(AttachePresentationProvider.xai.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
            UserDefaults.standard.set("", forKey: AttachePreferenceKey.presentationLLMModel)
            let model = try AppModel(store: CardStore.inMemory())
            let cards = (0..<3).map(card)

            let routed = observingRoute(.attacheOpenVoicemailSurface) {
                model.playInboxRecap(for: cards)
            }

            XCTAssertTrue(routed)
            XCTAssertFalse(model.recapInProgress)
            XCTAssertFalse(model.intakeStatus.isEmpty, "the digest fallback must still explain what happened")
        }
    }
}
