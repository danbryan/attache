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

    // MARK: - handleTwoWayDeliveryChanges surfaces every change (INF-248/B3)

    /// The old implementation was `changed.sorted(by: createdAt).last`, so a
    /// pump batch containing both a delivered instruction and a failed one
    /// only ever surfaced the newest-created instruction's status; nothing
    /// happened for the other one. This proves every instruction in the batch
    /// is now applied (ascending by `createdAt`), while the truly newest one
    /// still ends up as the visible status line - so the fix does not change
    /// today's precedence for what the string says, it just stops the older
    /// instruction from being skipped over entirely.
    func testHandleTwoWayDeliveryChangesAppliesEveryInstructionNewestLast() throws {
        _ = NSApplication.shared
        let model = try AppModel(store: CardStore.inMemory())

        let olderFailed = Instruction(
            id: "older-failed",
            sessionID: "s-old",
            sourceKind: "codex",
            text: "run the tests",
            state: .failed,
            createdAt: Date(timeIntervalSince1970: 100),
            error: "Send expired after 30 min waiting for Weekly Codex Improvement Review to go quiet.",
            targetDisplayName: "Weekly Codex Improvement Review"
        )
        let newerDelivered = Instruction(
            id: "newer-delivered",
            sessionID: "s-new",
            sourceKind: "codex",
            text: "run it again",
            state: .delivered,
            createdAt: Date(timeIntervalSince1970: 200),
            targetDisplayName: "Second Session"
        )

        // Passed in reverse-of-creation order to prove the handler sorts by
        // createdAt itself rather than trusting caller order.
        model.handleTwoWayDeliveryChanges([newerDelivered, olderFailed])

        XCTAssertEqual(model.intakeStatus, "Sent to Second Session. Watching for the reply…")
        XCTAssertEqual(model.liveFollowUpStatus, "Sent to Second Session. Watching for the reply…")
    }

    /// The expiry message (`InstructionReplyEngine.expireStale`) is already a
    /// complete sentence, so the failed-status formatting must show it
    /// verbatim rather than prefixing another "Send failed:" in front of it -
    /// this also keeps the off-call composer status consistent with
    /// `CallPhase.derive`'s on-call formatting, which already shows a failed
    /// send's error message with no added prefix.
    func testHandleTwoWayDeliveryChangesShowsExpiryMessageVerbatim() throws {
        _ = NSApplication.shared
        let model = try AppModel(store: CardStore.inMemory())
        let expired = Instruction(
            id: "expired",
            sessionID: "s1",
            sourceKind: "codex",
            text: "run the tests",
            state: .failed,
            createdAt: Date(),
            error: "Send expired after 30 min waiting for Weekly Codex Improvement Review to go quiet.",
            targetDisplayName: "Weekly Codex Improvement Review"
        )

        model.handleTwoWayDeliveryChanges([expired])

        XCTAssertEqual(
            model.intakeStatus,
            "Send expired after 30 min waiting for Weekly Codex Improvement Review to go quiet."
        )
        XCTAssertEqual(
            model.liveFollowUpStatus,
            "Send expired after 30 min waiting for Weekly Codex Improvement Review to go quiet."
        )
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

    // MARK: - intended_agent (INF-246)

    func testAgentInstructionArgumentsDecodeIntendedAgentAlongsideInstruction() {
        let withAgent = #"{"instruction":"reply exactly X","intended_agent":"claude_code"}"#
        let decoded = AppModel.agentInstructionArguments(fromToolArguments: withAgent)
        XCTAssertEqual(decoded?.instruction, "reply exactly X")
        XCTAssertEqual(decoded?.intendedAgent, "claude_code")

        let withoutAgent = #"{"instruction":"reply exactly X"}"#
        XCTAssertNil(AppModel.agentInstructionArguments(fromToolArguments: withoutAgent)?.intendedAgent)

        let blankAgent = #"{"instruction":"reply exactly X","intended_agent":"   "}"#
        XCTAssertNil(AppModel.agentInstructionArguments(fromToolArguments: blankAgent)?.intendedAgent)
    }

    /// Absent `intended_agent` must behave exactly as before this ticket:
    /// stages normally, no mismatch check runs at all.
    func testApplyStageAgentInstructionToolStagesNormallyWhenIntendedAgentAbsent() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }
        let sessionID = try seedWatchedSession(policy: .confirmEveryInstruction, defaults: defaults)
        let model = try AppModel(store: CardStore.inMemory())
        model.twoWay.setEnabled(true, sessionID: sessionID)
        let target = AgentSendTarget(
            sessionID: sessionID,
            sourceKind: SourceKind.codex.rawValue,
            displayTitle: "Agent Send Test",
            workingDirectory: nil
        )

        let message = await model.applyStageAgentInstructionTool(
            arguments: #"{"instruction":"reply exactly NO_INTENDED_AGENT"}"#,
            target: target,
            sourceUtterance: "tell it to reply"
        )

        XCTAssertNotNil(model.pendingInstruction)
        XCTAssertEqual(model.twoWay.log.first?.state, .pending)
        XCTAssertEqual(model.twoWay.log.first?.text, "reply exactly NO_INTENDED_AGENT")
        XCTAssertTrue(message.contains("staged") || message.contains("confirmation"))
    }

    /// A matching `intended_agent` stages exactly as if it had been absent.
    func testApplyStageAgentInstructionToolStagesNormallyWhenIntendedAgentMatchesFocusedSource() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }
        let sessionID = try seedWatchedSession(policy: .confirmEveryInstruction, defaults: defaults)
        let model = try AppModel(store: CardStore.inMemory())
        model.twoWay.setEnabled(true, sessionID: sessionID)
        let target = AgentSendTarget(
            sessionID: sessionID,
            sourceKind: SourceKind.codex.rawValue,
            displayTitle: "Agent Send Test",
            workingDirectory: nil
        )

        _ = await model.applyStageAgentInstructionTool(
            arguments: #"{"instruction":"reply exactly MATCHING_AGENT","intended_agent":"codex"}"#,
            target: target,
            sourceUtterance: "ask codex to reply"
        )

        XCTAssertNotNil(model.pendingInstruction)
        XCTAssertEqual(model.twoWay.log.first?.state, .pending)
        XCTAssertEqual(model.twoWay.log.first?.text, "reply exactly MATCHING_AGENT")
    }

    /// The core safety case: the model names a different, currently-watched
    /// agent than the frozen target. Nothing should be staged: no
    /// `PendingAgentSend`, no `requestSendToAgent` side effect, no instruction
    /// in the two-way log.
    func testApplyStageAgentInstructionToolBlocksWrongAgentMismatchWithoutSideEffects() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }
        let sessionID = try seedWatchedSession(policy: .confirmEveryInstruction, defaults: defaults)
        let model = try AppModel(store: CardStore.inMemory())
        model.twoWay.setEnabled(true, sessionID: sessionID)
        let claudeSession = CodexSessionTarget(
            id: "claude-\(UUID().uuidString)",
            title: "Claude Session",
            updatedAt: Date(),
            category: .activeSession,
            status: nil,
            sourceKind: .claudeCode
        )
        model.attachCodexSession(claudeSession)
        let target = AgentSendTarget(
            sessionID: sessionID,
            sourceKind: SourceKind.codex.rawValue,
            displayTitle: "Agent Send Test",
            workingDirectory: nil
        )

        let message = await model.applyStageAgentInstructionTool(
            arguments: #"{"instruction":"reply exactly WRONG_AGENT","intended_agent":"claude_code"}"#,
            target: target,
            sourceUtterance: "ask claude code to reply"
        )

        XCTAssertNil(model.pendingInstruction)
        XCTAssertTrue(model.twoWay.log.isEmpty)
        XCTAssertFalse(model.showTwoWayEnable)
        XCTAssertEqual(
            message,
            "The focused session is Codex (Agent Send Test). No staging occurred. Ask the user to focus a Claude Code session, or to confirm sending to Codex."
        )
    }

    /// When the named agent has no watched session at all, the message must
    /// say that rather than implying there is a session the user could focus.
    func testApplyStageAgentInstructionToolBlocksWhenNoWatchedSessionOfNamedSourceExists() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }
        let sessionID = try seedWatchedSession(policy: .confirmEveryInstruction, defaults: defaults)
        let model = try AppModel(store: CardStore.inMemory())
        model.twoWay.setEnabled(true, sessionID: sessionID)
        let target = AgentSendTarget(
            sessionID: sessionID,
            sourceKind: SourceKind.codex.rawValue,
            displayTitle: "Agent Send Test",
            workingDirectory: nil
        )

        let message = await model.applyStageAgentInstructionTool(
            arguments: #"{"instruction":"reply exactly NO_SESSION","intended_agent":"claude_code"}"#,
            target: target,
            sourceUtterance: "ask claude code to reply"
        )

        XCTAssertNil(model.pendingInstruction)
        XCTAssertTrue(model.twoWay.log.isEmpty)
        XCTAssertEqual(message, "No Claude Code sessions are currently being watched. No staging occurred.")
    }

    /// Fail closed (ticket title): an unrecognized `intended_agent` value is
    /// refused, never silently ignored/treated as absent.
    func testApplyStageAgentInstructionToolFailsClosedOnUnrecognizedIntendedAgent() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }
        let sessionID = try seedWatchedSession(policy: .confirmEveryInstruction, defaults: defaults)
        let model = try AppModel(store: CardStore.inMemory())
        model.twoWay.setEnabled(true, sessionID: sessionID)
        let target = AgentSendTarget(
            sessionID: sessionID,
            sourceKind: SourceKind.codex.rawValue,
            displayTitle: "Agent Send Test",
            workingDirectory: nil
        )

        let message = await model.applyStageAgentInstructionTool(
            arguments: #"{"instruction":"reply exactly UNRECOGNIZED","intended_agent":"gemini"}"#,
            target: target,
            sourceUtterance: "ask gemini to reply"
        )

        XCTAssertNil(model.pendingInstruction)
        XCTAssertTrue(model.twoWay.log.isEmpty)
        XCTAssertTrue(message.contains("No staging occurred."))
        XCTAssertTrue(message.contains("gemini"))
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
