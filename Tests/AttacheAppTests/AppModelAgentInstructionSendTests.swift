import XCTest
import AppKit
import AttacheCore
@testable import AttacheApp

@MainActor
final class AppModelAgentInstructionSendTests: XCTestCase {
    private let preferenceKeys = [
        CompanionPreferenceKey.codexSourceEnabled,
        CompanionPreferenceKey.watchedSessions,
        CompanionPreferenceKey.attachedCodexSessionID,
        CompanionPreferenceKey.agentInstructionSendPolicy,
        CompanionPreferenceKey.presentationLLMEnabled,
        CompanionPreferenceKey.onboardingCompleted
    ]

    func testDefaultPolicyStagesInstructionForFinalConfirmation() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }
        let sessionID = try seedWatchedSession(policy: .confirmEveryInstruction, defaults: defaults)
        let model = try AppModel(store: CardStore.inMemory())
        model.twoWay.setEnabled(true, sessionID: sessionID)

        model.requestSendToAgent("reply exactly DEFAULT_CONFIRM")

        XCTAssertNotNil(model.pendingInstruction)
        XCTAssertEqual(model.twoWay.log.first?.state, .pending)
    }

    func testDirectPolicySendsImmediatelyAfterSessionIsEnabled() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }
        let sessionID = try seedWatchedSession(policy: .directAfterSessionEnable, defaults: defaults)
        let model = try AppModel(store: CardStore.inMemory())
        model.twoWay.setEnabled(true, sessionID: sessionID)

        model.requestSendToAgent("reply exactly DIRECT_CONFIRM")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(model.pendingInstruction)
        XCTAssertEqual(model.intakeStatus, "Sending to the agent when the session is quiet…")
        XCTAssertEqual(model.twoWay.log.first?.state, .confirmed)
    }

    func testDirectPolicyDoesNotSkipFirstUseEnable() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }
        let sessionID = try seedWatchedSession(policy: .directAfterSessionEnable, defaults: defaults)
        let model = try AppModel(store: CardStore.inMemory())

        model.requestSendToAgent("reply exactly FIRST_USE")
        XCTAssertTrue(model.showTwoWayEnable)

        model.confirmEnableTwoWay()

        XCTAssertTrue(model.twoWay.isEnabled(sessionID: sessionID))
        XCTAssertNotNil(model.pendingInstruction)
        XCTAssertEqual(model.twoWay.log.first?.state, .pending)
    }

    func testAskAttacheModeDoesNotHostRouteAgentWording() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }
        let sessionID = try seedWatchedSession(policy: .confirmEveryInstruction, defaults: defaults)
        defaults.set(false, forKey: CompanionPreferenceKey.presentationLLMEnabled)
        let model = try AppModel(store: CardStore.inMemory())
        model.twoWay.setEnabled(true, sessionID: sessionID)
        model.conversationDestination = .attache

        model.sendConversationMessage("Tell Codex to reply exactly SHOULD_NOT_STAGE.")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(model.pendingInstruction)
        XCTAssertTrue(model.twoWay.log.isEmpty)
    }

    func testTellAgentModeStagesRawMessageForFocusedSession() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }
        let sessionID = try seedWatchedSession(policy: .confirmEveryInstruction, defaults: defaults)
        let model = try AppModel(store: CardStore.inMemory())
        model.conversationDestination = .agent

        model.sendConversationMessage("reply exactly RAW_AGENT_MODE")

        XCTAssertTrue(model.showTwoWayEnable)
        model.confirmEnableTwoWay()
        XCTAssertEqual(model.pendingInstruction?.sessionID, sessionID)
        XCTAssertEqual(model.pendingInstruction?.text, "reply exactly RAW_AGENT_MODE")
        XCTAssertEqual(model.twoWay.log.first?.state, .pending)
    }

    private func seedWatchedSession(policy: AgentInstructionSendPolicy, defaults: UserDefaults) throws -> String {
        let sessionID = "agent-send-\(UUID().uuidString)"
        let target = CodexSessionTarget(
            id: sessionID,
            title: "Agent Send Test",
            updatedAt: Date(),
            category: .activeSession,
            status: nil,
            sourceKind: .codex
        )
        defaults.set(true, forKey: CompanionPreferenceKey.codexSourceEnabled)
        defaults.set(try JSONEncoder().encode([target]), forKey: CompanionPreferenceKey.watchedSessions)
        defaults.set(sessionID, forKey: CompanionPreferenceKey.attachedCodexSessionID)
        defaults.set(policy.rawValue, forKey: CompanionPreferenceKey.agentInstructionSendPolicy)
        defaults.set(true, forKey: CompanionPreferenceKey.onboardingCompleted)
        return sessionID
    }
}

private final class DefaultsSnapshot {
    private let keys: [String]
    private let defaults: UserDefaults
    private let values: [String: Any]

    init(keys: [String], defaults: UserDefaults) {
        self.keys = keys
        self.defaults = defaults
        self.values = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        })
        keys.forEach { defaults.removeObject(forKey: $0) }
    }

    func restore() {
        keys.forEach { defaults.removeObject(forKey: $0) }
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
    }
}
