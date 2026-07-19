import AppKit
import AttacheCore
import XCTest
@testable import AttacheApp

/// INF-374: an incoming update on a live call must play (or queue to play next),
/// never silently land as unread voicemail, and a spoken update must be marked
/// heard so it never counts toward the unread badge.
@MainActor
final class AppModelLivePlaybackRoutingTests: XCTestCase {
    private func defaultsKeys() -> [String] {
        [
            AttachePreferenceKey.attachedCodexSessionID,
            AttachePreferenceKey.watchedSessions,
            AttachePreferenceKey.codexSourceEnabled
        ]
    }

    /// Stand up a model with one watched-and-focused session, then open a live
    /// call so `conversationTargetSnapshot` freezes that session as the target.
    private func makeCallingModel(
        sessionID: String,
        category: CodexAttachmentCategory,
        sourceKind: SourceKind = .codex
    ) throws -> AppModel {
        let defaults = UserDefaults.standard
        let target = CodexSessionTarget(
            id: sessionID,
            title: "Review Contacts Management",
            updatedAt: Date(),
            category: category,
            status: nil,
            sourceKind: sourceKind
        )
        defaults.set(true, forKey: AttachePreferenceKey.codexSourceEnabled)
        defaults.set(sessionID, forKey: AttachePreferenceKey.attachedCodexSessionID)
        defaults.set(try JSONEncoder().encode([target]), forKey: AttachePreferenceKey.watchedSessions)
        let model = AppModel(store: try CardStore.inMemory())
        model.startConversation()
        return model
    }

    private func agentEvent(
        sessionID: String?,
        source: SourceKind = .codex
    ) -> NormalizedEvent {
        NormalizedEvent(
            source: source.rawValue,
            eventType: "agent_message",
            externalSessionID: sessionID,
            title: "Update",
            text: "The migration finished."
        )
    }

    // MARK: - Routing

    func testFocusedCallTargetUpdatePlaysLiveWhenIdle() throws {
        _ = NSApplication.shared
        let sessionID = "live-routing-\(UUID().uuidString)"
        let snapshot = ConversationContextDefaultsSnapshot(keys: defaultsKeys(), defaults: .standard)
        defer { snapshot.restore() }
        let model = try makeCallingModel(sessionID: sessionID, category: .activeSession)
        XCTAssertEqual(model.conversationTargetSnapshot?.target.id, sessionID)

        XCTAssertEqual(
            model.livePlaybackRouting(for: agentEvent(sessionID: sessionID)),
            .playNow
        )
    }

    func testArchivedCategoryFocusedTargetStillPlaysLive() throws {
        // Symptom 2: the frozen target's UI category is stale display metadata.
        // A session the user explicitly focused and dialed must still speak live,
        // never divert to voicemail with nothing playing.
        _ = NSApplication.shared
        let sessionID = "live-routing-archived-\(UUID().uuidString)"
        let snapshot = ConversationContextDefaultsSnapshot(keys: defaultsKeys(), defaults: .standard)
        defer { snapshot.restore() }
        let model = try makeCallingModel(sessionID: sessionID, category: .archivedSession)
        XCTAssertEqual(model.conversationTargetSnapshot?.target.id, sessionID)

        XCTAssertNotEqual(
            model.livePlaybackRouting(for: agentEvent(sessionID: sessionID)),
            .voicemail
        )
    }

    func testUpdateFromNonTargetSessionIsVoicemailDuringCall() throws {
        _ = NSApplication.shared
        let sessionID = "live-routing-target-\(UUID().uuidString)"
        let snapshot = ConversationContextDefaultsSnapshot(keys: defaultsKeys(), defaults: .standard)
        defer { snapshot.restore() }
        let model = try makeCallingModel(sessionID: sessionID, category: .activeSession)

        XCTAssertEqual(
            model.livePlaybackRouting(for: agentEvent(sessionID: "some-other-session")),
            .voicemail
        )
    }

    func testNonLiveAgentSourceIsVoicemailDuringCall() throws {
        _ = NSApplication.shared
        let sessionID = "live-routing-source-\(UUID().uuidString)"
        let snapshot = ConversationContextDefaultsSnapshot(keys: defaultsKeys(), defaults: .standard)
        defer { snapshot.restore() }
        let model = try makeCallingModel(sessionID: sessionID, category: .activeSession)

        XCTAssertEqual(
            model.livePlaybackRouting(for: agentEvent(sessionID: sessionID, source: .generic)),
            .voicemail
        )
    }

    func testFocusedUpdateIsVoicemailWhenNotOnCall() throws {
        _ = NSApplication.shared
        let sessionID = "live-routing-offcall-\(UUID().uuidString)"
        let snapshot = ConversationContextDefaultsSnapshot(keys: defaultsKeys(), defaults: .standard)
        defer { snapshot.restore() }
        let model = try makeCallingModel(sessionID: sessionID, category: .activeSession)
        model.endConversation()

        XCTAssertEqual(
            model.livePlaybackRouting(for: agentEvent(sessionID: sessionID)),
            .voicemail
        )
    }

    // MARK: - Settings overlay do-not-disturb (INF-377)

    func testSettingsOverlayOpenDivertsLiveCallUpdatesToVoicemail() throws {
        _ = NSApplication.shared
        let sessionID = "live-routing-settings-\(UUID().uuidString)"
        let snapshot = ConversationContextDefaultsSnapshot(keys: defaultsKeys(), defaults: .standard)
        defer { snapshot.restore() }
        let model = try makeCallingModel(sessionID: sessionID, category: .activeSession)

        // On-target, idle: normally plays live.
        XCTAssertEqual(
            model.livePlaybackRouting(for: agentEvent(sessionID: sessionID)),
            .playNow
        )

        // Opening Settings must divert the live call's own updates to voicemail:
        // the user cannot see captions while Settings is up.
        model.showSettingsOverlay()
        XCTAssertTrue(model.settingsOverlayVisible)
        XCTAssertTrue(model.conversationActive, "opening Settings must not end the live call")
        XCTAssertEqual(
            model.livePlaybackRouting(for: agentEvent(sessionID: sessionID)),
            .voicemail
        )

        // Closing Settings restores normal live routing for subsequent arrivals.
        model.hideSettingsOverlay()
        XCTAssertFalse(model.settingsOverlayVisible)
        XCTAssertTrue(model.conversationActive)
        XCTAssertEqual(
            model.livePlaybackRouting(for: agentEvent(sessionID: sessionID)),
            .playNow
        )
    }

    func testToggleSettingsOverlayFlipsRoutingBothWays() throws {
        _ = NSApplication.shared
        let sessionID = "live-routing-settings-toggle-\(UUID().uuidString)"
        let snapshot = ConversationContextDefaultsSnapshot(keys: defaultsKeys(), defaults: .standard)
        defer { snapshot.restore() }
        let model = try makeCallingModel(sessionID: sessionID, category: .activeSession)

        model.toggleSettingsOverlay()
        XCTAssertTrue(model.settingsOverlayVisible)
        XCTAssertEqual(model.livePlaybackRouting(for: agentEvent(sessionID: sessionID)), .voicemail)

        model.toggleSettingsOverlay()
        XCTAssertFalse(model.settingsOverlayVisible)
        XCTAssertEqual(model.livePlaybackRouting(for: agentEvent(sessionID: sessionID)), .playNow)
    }

    func testHideSettingsOverlayAlsoClosesCharacterStudio() throws {
        _ = NSApplication.shared
        let model = AppModel(store: try CardStore.inMemory())
        model.showSettingsOverlay(section: .personalities)
        model.openCharacterStudio(.create)
        XCTAssertNotNil(model.characterStudioRequest)
        XCTAssertEqual(model.activeSettingsSection, .personalities)

        model.hideSettingsOverlay()
        XCTAssertNil(model.characterStudioRequest)
        XCTAssertFalse(model.settingsOverlayVisible)
    }

    // MARK: - Heard / unread accounting

    func testSpokenLivePathCardIsMarkedHeardAndLeavesUnreadCount() throws {
        _ = NSApplication.shared
        let sessionID = "live-heard-\(UUID().uuidString)"
        let snapshot = ConversationContextDefaultsSnapshot(keys: defaultsKeys(), defaults: .standard)
        defer { snapshot.restore() }
        let store = try CardStore.inMemory()
        let card = try store.insertEvent(agentEvent(sessionID: sessionID))
        let defaults = UserDefaults.standard
        let target = CodexSessionTarget(
            id: sessionID, title: "Session", updatedAt: Date(),
            category: .activeSession, status: nil, sourceKind: .codex
        )
        defaults.set(true, forKey: AttachePreferenceKey.codexSourceEnabled)
        defaults.set(sessionID, forKey: AttachePreferenceKey.attachedCodexSessionID)
        defaults.set(try JSONEncoder().encode([target]), forKey: AttachePreferenceKey.watchedSessions)
        let model = AppModel(store: store)

        model.reloadCards()
        XCTAssertEqual(model.unreadCount, 1)

        // The live path marks a spoken card heard (what `finishPlayback` does on
        // success). It must then drop out of the unread badge entirely.
        try store.markHeard(cardID: card.id)
        model.reloadCards()
        XCTAssertEqual(model.unreadCount, 0)
        XCTAssertTrue(model.unreadCards.isEmpty)
        XCTAssertEqual(model.cards.first(where: { $0.id == card.id })?.status, .heard)
    }

    // MARK: - Focused-session live updates never file unread inbox (INF-398)

    /// (a) On a live call, an update from the frozen focused target is filed as
    /// HEARD history the instant it lands, so it never adds an unread inbox
    /// voicemail for a message the user already heard live, and the badge never
    /// increments. This is decoupled from whether audio finished, so no
    /// mark-heard race can strand it unread.
    func testFocusedCallTargetEventIsFiledHeardNotUnreadInbox() throws {
        _ = NSApplication.shared
        setenv("ATTACHE_UI_TEST_MUTE_AUDIO", "1", 1)
        defer { unsetenv("ATTACHE_UI_TEST_MUTE_AUDIO") }
        let sessionID = "live-heard-inbox-\(UUID().uuidString)"
        let snapshot = ConversationContextDefaultsSnapshot(keys: defaultsKeys(), defaults: .standard)
        defer { snapshot.restore() }
        let model = try makeCallingModel(sessionID: sessionID, category: .activeSession)
        XCTAssertEqual(model.conversationTargetSnapshot?.target.id, sessionID)
        XCTAssertEqual(model.unreadCount, 0)

        model.persist(agentEvent(sessionID: sessionID))
        defer { model.playback.stop() }

        let card = model.cards.first { $0.externalSessionID == sessionID }
        XCTAssertNotNil(card, "the update is still recorded in History")
        XCTAssertEqual(
            card?.status, .heard,
            "a live-narrated focused-session update must be filed heard, never unread inbox"
        )
        XCTAssertEqual(model.unreadCount, 0, "it must not increment the unread badge")
        XCTAssertTrue(model.unreadCards.isEmpty)
    }

    /// (b) During the same call, an update from a watched session that is NOT the
    /// frozen call target keeps normal voicemail behavior: it lands unread and
    /// counts toward the badge.
    func testWatchedNonFocusedEventStaysUnreadVoicemailDuringCall() throws {
        _ = NSApplication.shared
        let sessionID = "live-focused-\(UUID().uuidString)"
        let snapshot = ConversationContextDefaultsSnapshot(keys: defaultsKeys(), defaults: .standard)
        defer { snapshot.restore() }
        let model = try makeCallingModel(sessionID: sessionID, category: .activeSession)
        // Filing a voicemail card posts a system notification when voicemailMode
        // is on; the test process has no app bundle, so keep it off.
        model.voicemailMode = false
        XCTAssertTrue(model.conversationActive)

        let otherSessionID = "watched-not-focused-\(UUID().uuidString)"
        model.persist(agentEvent(sessionID: otherSessionID))

        let card = model.cards.first { $0.externalSessionID == otherSessionID }
        XCTAssertEqual(
            card?.status, .unread,
            "a watched-but-not-focused session keeps normal unread voicemail during a call"
        )
        XCTAssertEqual(model.unreadCount, 1)
    }

    /// (d) After hang-up the call target is gone, so an update from the same
    /// session files as an unread voicemail again: the suppression is scoped to
    /// the active call.
    func testFocusedEventFilesUnreadVoicemailAfterHangUp() throws {
        _ = NSApplication.shared
        let sessionID = "live-hangup-\(UUID().uuidString)"
        let snapshot = ConversationContextDefaultsSnapshot(keys: defaultsKeys(), defaults: .standard)
        defer { snapshot.restore() }
        let model = try makeCallingModel(sessionID: sessionID, category: .activeSession)
        model.voicemailMode = false
        model.endConversation()
        XCTAssertFalse(model.conversationActive)

        model.persist(agentEvent(sessionID: sessionID))

        let card = model.cards.first { $0.externalSessionID == sessionID }
        XCTAssertEqual(
            card?.status, .unread,
            "off-call, the focused session's update is a normal unread voicemail again"
        )
        XCTAssertEqual(model.unreadCount, 1)
    }
}
