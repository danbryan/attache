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
        XCTAssertEqual(model.pendingInstruction?.origin, .offCallComposer)
        XCTAssertEqual(model.pendingInstruction?.targetDisplayName, "Agent Send Test")
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
        XCTAssertEqual(model.intakeStatus, "Sending to Agent Send Test when the session is quiet…")
        XCTAssertNotNil(model.twoWay.log.first?.confirmedAt)
        XCTAssertNotEqual(model.twoWay.log.first?.state, .pending)
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
        model.startConversation()
        model.conversationDestination = .agent

        model.sendConversationMessage("reply exactly RAW_AGENT_MODE")

        XCTAssertEqual(model.conversationDestination, .attache)
        XCTAssertTrue(model.showTwoWayEnable)
        XCTAssertEqual(model.twoWayEnableTargetTitle, "Agent Send Test")
        model.confirmEnableTwoWay()
        XCTAssertEqual(model.pendingInstruction?.sessionID, sessionID)
        XCTAssertEqual(model.pendingInstruction?.text, "reply exactly RAW_AGENT_MODE")
        XCTAssertEqual(model.pendingInstruction?.origin, .tellAgent)
        XCTAssertEqual(model.pendingInstruction?.sourceUtterance, "reply exactly RAW_AGENT_MODE")
        XCTAssertEqual(model.pendingInstruction?.targetDisplayName, "Agent Send Test")
        XCTAssertEqual(model.twoWay.log.first?.state, .pending)
    }

    func testTellAgentFreezesFocusedTargetAcrossFocusChanges() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }
        let firstSessionID = try seedWatchedSession(policy: .confirmEveryInstruction, defaults: defaults)
        let model = try AppModel(store: CardStore.inMemory())
        model.startConversation()

        let second = CodexSessionTarget(
            id: "second-\(UUID().uuidString)",
            title: "Second Session",
            updatedAt: Date(),
            category: .activeSession,
            status: nil,
            sourceKind: .claudeCode
        )
        model.attachCodexSession(second)
        model.conversationDestination = .agent
        model.sendConversationMessage("stay on the original target")

        XCTAssertEqual(model.twoWayEnableTargetTitle, "Agent Send Test")
        model.confirmEnableTwoWay()
        XCTAssertEqual(model.pendingInstruction?.sessionID, firstSessionID)
        XCTAssertEqual(model.pendingInstruction?.sourceKind, SourceKind.codex.rawValue)
        XCTAssertEqual(model.pendingInstruction?.targetDisplayName, "Agent Send Test")
    }

    func testTellAgentRequiresExplicitFocusEvenWhenARecentSessionExists() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }
        _ = try seedWatchedSession(policy: .confirmEveryInstruction, defaults: defaults)
        defaults.removeObject(forKey: CompanionPreferenceKey.attachedCodexSessionID)
        let model = try AppModel(store: CardStore.inMemory())
        model.attachCodexSession(nil)
        model.startConversation()

        XCTAssertFalse(model.canSendToAgent)
        model.conversationDestination = .agent
        model.sendConversationMessage("do not guess the target")

        XCTAssertEqual(model.conversationDestination, .attache)
        XCTAssertFalse(model.showTwoWayEnable)
        XCTAssertNil(model.pendingInstruction)
        XCTAssertTrue(model.twoWay.log.isEmpty)
        XCTAssertTrue(model.intakeStatus.contains("focused") || model.intakeStatus.contains("Focus"))
    }

    func testPersonalityToolArgumentsFreezeOnlyTheStructuredInstruction() {
        let arguments = #"{"instruction":"  Reply exactly TOOL_PAYLOAD. Do not use tools.  ","working_directory":"/tmp/wrong"}"#

        XCTAssertEqual(
            AppModel.agentInstruction(fromToolArguments: arguments),
            "Reply exactly TOOL_PAYLOAD. Do not use tools."
        )
        XCTAssertNil(AppModel.agentInstruction(fromToolArguments: #"{"instruction":"   "}"#))
        XCTAssertNil(AppModel.agentInstruction(fromToolArguments: #"{"working_directory":"/tmp/wrong"}"#))
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
