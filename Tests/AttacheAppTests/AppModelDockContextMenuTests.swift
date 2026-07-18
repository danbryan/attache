import AppKit
import AttacheCore
import XCTest
@testable import AttacheApp

/// INF-354: unit coverage for the navigation/action APIs backing the dock's
/// right-click context menus (Settings pane deep-links, Voicemail quick
/// actions, Call-as-personality, and the Option-key live state that drives
/// every menu's alternates).
@MainActor
final class AppModelDockContextMenuTests: XCTestCase {
    private static let touchedKeys = [
        "attache.personalities", "attache.activePersonalityID",
        AttachePreferenceKey.attachedCodexSessionID,
        AttachePreferenceKey.watchedSessions, AttachePreferenceKey.codexSourceEnabled,
        AttachePreferenceKey.claudeCodeSourceEnabled
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

    // MARK: - openSettings(pane:)

    /// `AttacheNavigation.openSettings(pane:)` is the direct navigation API
    /// the Settings context menu's items call. It must post both the overlay
    /// reveal notification synchronously and the pane-selection notification
    /// (asynchronously, once the overlay has had a chance to appear) with the
    /// exact `SettingsSection` chosen.
    func testOpenSettingsPanePostsWindowRevealAndSectionNotifications() {
        let revealExpectation = expectation(description: "reveal")
        let sectionExpectation = expectation(description: "section")

        let revealObserver = NotificationCenter.default.addObserver(
            forName: .attacheOpenSettings, object: nil, queue: .main
        ) { _ in revealExpectation.fulfill() }
        let sectionObserver = NotificationCenter.default.addObserver(
            forName: .attacheOpenSettingsSection, object: nil, queue: .main
        ) { note in
            XCTAssertEqual(note.object as? String, SettingsSection.integrations.rawValue)
            sectionExpectation.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(revealObserver)
            NotificationCenter.default.removeObserver(sectionObserver)
        }

        AttacheNavigation.openSettings(pane: .integrations)

        wait(for: [revealExpectation, sectionExpectation], timeout: 2)
    }

    /// Every section the dock's Settings context menu exposes (Appearance,
    /// Voice and Captions, Personalities, Context, Integrations, Memory, in
    /// that order, `.about` excluded) must round-trip through
    /// `openSettings(pane:)`.
    func testDockSettingsSectionsMatchTicketList() {
        let expected: [SettingsSection] = [.appearance, .voice, .personalities, .context, .integrations, .memory]
        XCTAssertEqual(AttacheRootView.dockSettingsSections, expected)
    }

    // MARK: - Voicemail quick actions

    func testPlayLatestCardPlaysMostRecentCard() throws {
        try restoringDefaults {
            let store = try CardStore.inMemory()
            _ = try store.insertEvent(NormalizedEvent(
                source: SourceKind.generic.rawValue,
                eventType: "attache.update",
                title: "Older",
                text: "older text"
            ))
            let newer = try store.insertEvent(NormalizedEvent(
                source: SourceKind.generic.rawValue,
                eventType: "attache.update",
                title: "Newer",
                text: "newer text"
            ))
            let model = AppModel(store: store)

            model.playLatestCard()

            XCTAssertEqual(model.selectedCardID, newer.id)
        }
    }

    func testPlayLatestCardIsNoOpWithEmptyInbox() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            XCTAssertNil(model.selectedCardID)
            model.playLatestCard()
            XCTAssertNil(model.selectedCardID)
        }
    }

    // MARK: - Call as personality

    func testStartCallAsSwitchesPersonalityThenStartsASavedCall() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let target = Personality(id: "custom.call-as", name: "Call Target", prompt: "p")
            model.personalities = [target]

            model.startCall(as: target.id)

            XCTAssertEqual(model.activePersonalityID, target.id)
            XCTAssertTrue(model.conversationActive)
            XCTAssertEqual(model.conversationStorageMode, .saved)
        }
    }

    /// The Option-held "Call as…" alternate: same destination, private
    /// storage mode. `startPrivateCall(as:)` is the only new code path here;
    /// the underlying private-call primitive (`startPrivateCall()` /
    /// `startConversation(storageMode: .privateCall)`) already shipped, so
    /// this only proves the personality switch happens first.
    func testStartPrivateCallAsSwitchesPersonalityThenStartsAPrivateCall() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let target = Personality(id: "custom.private-call-as", name: "Private Target", prompt: "p")
            model.personalities = [target]

            model.startPrivateCall(as: target.id)

            XCTAssertEqual(model.activePersonalityID, target.id)
            XCTAssertTrue(model.conversationActive)
            XCTAssertEqual(model.conversationStorageMode, .privateCall)
        }
    }

    // MARK: - OptionKeyMonitor

    /// `ATTACHE_UI_TEST_FORCE_OPTION_MENU=1` (only under `ATTACHE_UI_TEST=1`)
    /// forces the dock's Option-alternate items on for `scripts/ui-smoke.sh`,
    /// without requiring a synthesized modifier-flag event.
    func testForceOptionMenuEnvironmentIsDocumentedAndInert() {
        // No live process-environment mutation here (ProcessInfo.environment
        // is read once at OptionKeyMonitor init); this asserts the singleton
        // exists and defaults to false in the normal test environment, which
        // does not set either override variable.
        XCTAssertFalse(OptionKeyMonitor.shared.isHeld)
    }
}
