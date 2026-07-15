import AppKit
import AttacheCore
import XCTest
@testable import AttacheApp

@MainActor
final class AttacheRequestSnapshotTests: XCTestCase {

    private func freshDefaultsKeys() -> [String] {
        [
            AttachePreferenceKey.attachedCodexSessionID,
            AttachePreferenceKey.watchedSessions,
            AttachePreferenceKey.codexSourceEnabled,
            AttachePreferenceKey.claudeCodeSourceEnabled
        ]
    }

    private func makeModel() throws -> (AppModel, ConversationContextDefaultsSnapshot) {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = ConversationContextDefaultsSnapshot(keys: freshDefaultsKeys(), defaults: defaults)
        defaults.set(false, forKey: AttachePreferenceKey.codexSourceEnabled)
        defaults.set(false, forKey: AttachePreferenceKey.claudeCodeSourceEnabled)
        return (AppModel(store: try CardStore.inMemory()), snapshot)
    }

    /// Sentinel (INF-304): the selected personality's prompt is the authority
    /// for a captured request. The legacy file store is gone, so nothing else
    /// can supply a competing prompt at runtime.
    func testCaptureUsesSelectedPersonalityPrompt() throws {
        let (model, defaults) = try makeModel()
        defer { defaults.restore() }
        let id = model.createPersonality(name: "Sentinel", prompt: "Sentinel-selected-prompt-tone")
        XCTAssertEqual(model.activePersonality?.id, id)

        let snapshot = model.captureRequestSnapshot(role: .conversation, userInput: "hi")
        XCTAssertEqual(snapshot.personalityID, id)
        XCTAssertEqual(snapshot.profilePrompt, "Sentinel-selected-prompt-tone")
        XCTAssertEqual(snapshot.userInput, "hi")
        XCTAssertEqual(snapshot.role, .conversation)
    }

    /// Switching personality after a snapshot is captured does not mutate the
    /// frozen request; the next capture reflects the new selection.
    func testInFlightPersonalitySwitchDoesNotMutateCapturedSnapshot() throws {
        let (model, defaults) = try makeModel()
        defer { defaults.restore() }
        let firstID = model.createPersonality(name: "First", prompt: "First-prompt-tone")
        let first = model.captureRequestSnapshot(role: .conversation, userInput: "go")

        let secondID = model.createPersonality(name: "Second", prompt: "Second-prompt-tone")
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(model.activePersonality?.id, secondID)

        // The already-captured snapshot is frozen by value.
        XCTAssertEqual(first.personalityID, firstID)
        XCTAssertEqual(first.profilePrompt, "First-prompt-tone")

        // The next capture uses the new selection.
        let next = model.captureRequestSnapshot(role: .conversation, userInput: "again")
        XCTAssertEqual(next.personalityID, secondID)
        XCTAssertEqual(next.profilePrompt, "Second-prompt-tone")
    }

    /// No focused session means the snapshot is context-free and carries no
    /// work-session evidence or tools.
    func testContextFreeSnapshotWhenNoSessionFocused() throws {
        let (model, defaults) = try makeModel()
        defer { defaults.restore() }
        model.startConversation()
        defer { model.endConversation() }
        XCTAssertNil(model.conversationTargetSnapshot)

        let snapshot = model.captureRequestSnapshot(role: .conversation, userInput: "hello")
        XCTAssertEqual(snapshot.session, .contextFree)
        XCTAssertFalse(snapshot.isFocused)
        XCTAssertNil(snapshot.focusedSession)
    }

    /// A focused session freezes its identity into the snapshot. A later
    /// selection cannot mutate the already-captured value.
    func testFocusedSnapshotFreezesSessionIdentity() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = ConversationContextDefaultsSnapshot(keys: freshDefaultsKeys(), defaults: defaults)
        defer { snapshot.restore() }
        let sessionID = "focused-snapshot-\(UUID().uuidString)"
        let target = CodexSessionTarget(
            id: sessionID,
            title: "Frozen session",
            updatedAt: Date(),
            category: .activeSession,
            status: nil,
            sourceKind: .codex
        )
        defaults.set(true, forKey: AttachePreferenceKey.codexSourceEnabled)
        defaults.set(sessionID, forKey: AttachePreferenceKey.attachedCodexSessionID)
        defaults.set(try JSONEncoder().encode([target]), forKey: AttachePreferenceKey.watchedSessions)

        let model = AppModel(store: try CardStore.inMemory())
        model.startConversation()
        defer { model.endConversation() }
        XCTAssertEqual(model.conversationTargetSnapshot?.target.id, sessionID)

        let captured = model.captureRequestSnapshot(role: .conversation, userInput: "status")
        guard case .focused(let focused) = captured.session else {
            XCTFail("Expected a focused session authorization")
            return
        }
        XCTAssertEqual(focused.sessionID, sessionID)
        XCTAssertEqual(focused.displayTitle, "Frozen session")
        XCTAssertEqual(focused.sourceKind, SourceKind.codex.rawValue)

        // A later selection (different attached session) must not mutate the
        // frozen snapshot even if live state changes.
        defaults.set("a-different-session", forKey: AttachePreferenceKey.attachedCodexSessionID)
        XCTAssertEqual(captured.focusedSession?.sessionID, sessionID)
    }

    /// Every user-facing role captures the selected personality. Topic tagging
    /// is neutral and never inherits a personality's session context (enforced
    /// by AttacheRequestAuthority).
    func testEveryRoleCapturesSelectedPersonalityAndTaggingStaysNeutral() throws {
        let (model, defaults) = try makeModel()
        defer { defaults.restore() }
        let id = model.createPersonality(name: "Owner", prompt: "Owner-tone")
        let userFacing: [AttacheRequestRole] = [
            .presentation, .conversation, .recap, .followUp, .liveFollowUp, .anotherTake, .preview
        ]
        for role in userFacing {
            let snap = model.captureRequestSnapshot(role: role, userInput: "")
            XCTAssertEqual(snap.personalityID, id, "Role \(role) must capture the selected personality")
            XCTAssertEqual(snap.profilePrompt, "Owner-tone")
        }
        let focused = AttacheSessionAuthorization.focused(AttacheFocusedSession(
            sessionID: "s", sourceKind: "codex", displayTitle: "T", workingDirectory: nil
        ))
        XCTAssertFalse(AttacheRequestAuthority.roleMayUseSessionContext(.topicTagging, authorization: focused))
    }
}