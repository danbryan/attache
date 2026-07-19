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

    /// Persisted UI focus alone is not authority when the session is absent
    /// from the current app-owned index. This prevents stale defaults or a
    /// fabricated watched-session record from granting transcript access.
    func testUnindexedPersistedFocusRemainsContextFree() throws {
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
        XCTAssertNil(model.conversationTargetSnapshot?.focusedSession)

        let captured = model.captureRequestSnapshot(role: .conversation, userInput: "status")
        XCTAssertEqual(captured.session, .contextFree)

        // A later mutable default cannot retroactively alter the frozen value.
        defaults.set("a-different-session", forKey: AttachePreferenceKey.attachedCodexSessionID)
        XCTAssertEqual(captured.session, .contextFree)
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

    /// A LAN model is local for consent copy, but it is remote for a memory
    /// marked `localOnly`: the prompt leaves this Mac. The snapshot boundary
    /// must filter that memory before compilation or transport.
    func testLANModelExcludesLocalOnlyMemoryFromCapturedSnapshot() throws {
        let (model, defaults) = try makeModel()
        defer { defaults.restore() }

        let memoryState = AttacheContextUIState.shared
        let priorMode = memoryState.memoryMode
        defer { memoryState.setMemoryMode(priorMode, explicit: false) }
        memoryState.setMemoryMode(.on, explicit: false)

        let statement = "I prefer ultramarine tangerine combinations."
        let arguments = #"{"statement":"I prefer ultramarine tangerine combinations.","type":"preference","scope":"global","scope_value":"global","sensitivity":"low","egress":"localOnly"}"#
        let disposition = model.applyMemoryProposalTool(
            arguments: arguments,
            sourceUtterance: statement,
            personalityID: model.activePersonality?.id ?? "attache",
            sourceLocator: "test:lan-memory-egress"
        )
        XCTAssertTrue(disposition.contains("saved"), disposition)

        func ollamaSettings(_ endpoint: String) -> AttachePresentationSettings {
            AttachePresentationSettings(
                llmEnabled: true,
                provider: .ollama,
                baseURL: URL(string: endpoint)!,
                apiKey: "",
                apiKeySecretRef: "",
                model: "test-model",
                reasoningEffort: nil,
                serviceTier: nil,
                profilePrompt: ""
            )
        }

        let loopback = model.captureRequestSnapshot(
            role: .conversation,
            userInput: statement,
            settingsOverride: ollamaSettings("http://127.0.0.1:11434/v1")
        )
        XCTAssertTrue(loopback.contextItems.contains { $0.content.contains(statement) })

        let lan = model.captureRequestSnapshot(
            role: .conversation,
            userInput: statement,
            settingsOverride: ollamaSettings("http://192.168.50.25:11434/v1")
        )
        XCTAssertFalse(lan.contextItems.contains { $0.content.contains(statement) })
        XCTAssertTrue(lan.memorySelectionReceipt.contains {
            $0.disposition == .omitted && $0.omissionReason == "local-only-egress"
        })
    }

    func testStaleConversationAuthorizationBlocksMemoryRenameAndAgentSendAtMutationPoint() async throws {
        let (model, defaults) = try makeModel()
        defer { defaults.restore() }
        model.startConversation()
        let authorization = try XCTUnwrap(model.issueConversationRequestAuthorization())
        model.endConversation()

        let sentinel = "stale boundary memory \(UUID().uuidString)"
        let memoryResult = model.applyMemoryProposalTool(
            arguments: #"{"statement":"stale boundary memory","type":"preference","scope":"global","scope_value":"global","sensitivity":"low","egress":"localOnly"}"#,
            sourceUtterance: sentinel,
            personalityID: model.activePersonality?.id ?? "attache",
            sourceLocator: "test:stale-effect",
            authorization: authorization
        )
        XCTAssertTrue(memoryResult.contains("canceled"), memoryResult)

        let renameResult = await model.applyRenameTool(
            arguments: #"{"name":"MUST NOT RENAME"}"#,
            sessionID: "stale-session",
            effectLedger: ConversationTurnEffectLedger(),
            authorization: authorization
        )
        XCTAssertTrue(renameResult.contains("canceled"), renameResult)
        XCTAssertNil(model.sessionRenames["stale-session"])

        let sendResult = await model.applyStageAgentInstructionTool(
            arguments: #"{"instruction":"MUST NOT SEND"}"#,
            target: AgentSendTarget(
                sessionID: "stale-session",
                sourceKind: SourceKind.codex.rawValue,
                displayTitle: "Stale session",
                workingDirectory: nil
            ),
            sourceUtterance: "send it",
            effectLedger: ConversationTurnEffectLedger(),
            authorization: authorization
        )
        XCTAssertTrue(sendResult.contains("canceled"), sendResult)
        XCTAssertNil(model.pendingInstruction)
        XCTAssertTrue(model.twoWay.log.isEmpty)

        model.startConversation()
        let later = model.captureRequestSnapshot(role: .conversation, userInput: sentinel)
        model.endConversation()
        XCTAssertFalse(later.contextItems.contains { $0.content.contains(sentinel) })
    }

    /// Model-free end-to-end run of the live-call propose_memory dispatch: the
    /// same handler the conversation executeTool closure routes the tool to,
    /// with a valid seven-field payload. An explicit ask restated in the user's
    /// own words saves immediately as a user-authored, local-only record.
    /// Ledger storage lives in a temp directory because the card store is
    /// in-memory.
    func testLiveCallExplicitAskSavesImmediatelyAsUserAuthoredLocalOnly() throws {
        let (model, defaults) = try makeModel()
        defer { defaults.restore() }
        let memoryState = AttacheContextUIState.shared
        let priorMode = memoryState.memoryMode
        defer { memoryState.setMemoryMode(priorMode, explicit: false) }
        memoryState.setMemoryMode(.on, explicit: false)
        // Init defers the same bind to a main-actor task; wire it now so the
        // forget cleanup below persists through this model's runtime.
        model.bindMemoryContextUI(to: memoryState)

        model.startConversation()
        defer { model.endConversation() }
        XCTAssertTrue(model.conversationAllowsMemoryProposals)
        let authorization = try XCTUnwrap(model.issueConversationRequestAuthorization())
        let effectLedger = ConversationTurnEffectLedger()

        let statement = "my name is Dan Vermilion Quartz"
        let reply = model.applyMemoryProposalTool(
            arguments: #"{"statement":"my name is Dan Vermilion Quartz","type":"userFact","scope":"global","scope_value":"global","sensitivity":"low","egress":"localOnly","requires_confirmation":false}"#,
            sourceUtterance: "Remember my name is Dan Vermilion Quartz.",
            personalityID: model.activePersonality?.id ?? "attache",
            sourceLocator: "test:explicit-save",
            effectLedger: effectLedger,
            authorization: authorization
        )

        XCTAssertTrue(reply.contains("saved on this Mac"), reply)
        let stored = memoryState.memoryRecords.first { $0.statement == statement }
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.sourceKind, .userAuthored)
        XCTAssertEqual(stored?.egress, .localOnly)
        // The payload's scope-like fields are ignored: a conversation capture
        // always binds to the active Attaché, never global.
        XCTAssertEqual(
            stored?.scope,
            .personality(model.activePersonality?.id ?? "attache"),
            "the tool must never produce a global row"
        )
        XCTAssertTrue(model.memorySavedChipVisible, "the save confirmation chip must show")
        XCTAssertFalse(
            effectLedger.claim(.memoryProposal),
            "the dispatch must have claimed the per-turn memory effect"
        )

        if let stored {
            memoryState.forgetMemory(id: stored.id)
        }
        XCTAssertFalse(memoryState.memoryRecords.contains { $0.statement == statement })
    }

    /// A validator-rejected fact (here a transient mood) returns the declined
    /// tool result, saves nothing, and never shows the saved chip. There is no
    /// suggestion queue to fall back to.
    func testLiveCallValidatorRejectionSavesNothingAndReportsDecline() throws {
        let (model, defaults) = try makeModel()
        defer { defaults.restore() }
        let memoryState = AttacheContextUIState.shared
        let priorMode = memoryState.memoryMode
        defer { memoryState.setMemoryMode(priorMode, explicit: false) }
        memoryState.setMemoryMode(.on, explicit: false)
        model.bindMemoryContextUI(to: memoryState)

        model.startConversation()
        defer { model.endConversation() }
        let authorization = try XCTUnwrap(model.issueConversationRequestAuthorization())
        let effectLedger = ConversationTurnEffectLedger()

        let statement = "today I feel unstoppable about quartz"
        let reply = model.applyMemoryProposalTool(
            arguments: #"{"statement":"today I feel unstoppable about quartz","type":"userFact","scope":"global","scope_value":"global","sensitivity":"low","egress":"localOnly","requires_confirmation":false}"#,
            sourceUtterance: "Remember today I feel unstoppable about quartz.",
            personalityID: model.activePersonality?.id ?? "attache",
            sourceLocator: "test:validator-decline",
            effectLedger: effectLedger,
            authorization: authorization
        )

        XCTAssertTrue(reply.contains("declined"), reply)
        XCTAssertTrue(reply.contains(AttacheMemoryProposalRejection.transientMood.rawValue), reply)
        XCTAssertFalse(memoryState.memoryRecords.contains { $0.statement == statement })
        XCTAssertFalse(model.memorySavedChipVisible, "no chip may show for a declined fact")
    }

    /// A rejected proposal saved nothing, so it refunds the once-per-turn
    /// effect: the model is told to retry with the user's words, the retry can
    /// save, and a completed save still blocks any second save in the turn.
    func testRejectedMemoryAttemptAllowsRetryButOnlyOneSavePerTurn() throws {
        let (model, defaults) = try makeModel()
        defer { defaults.restore() }
        let memoryState = AttacheContextUIState.shared
        let priorMode = memoryState.memoryMode
        defer { memoryState.setMemoryMode(priorMode, explicit: false) }
        memoryState.setMemoryMode(.on, explicit: false)
        model.bindMemoryContextUI(to: memoryState)

        model.startConversation()
        defer { model.endConversation() }
        let authorization = try XCTUnwrap(model.issueConversationRequestAuthorization())
        let effectLedger = ConversationTurnEffectLedger()
        let personalityID = model.activePersonality?.id ?? "attache"
        let utterance = "Yeah, can you re please remember that my other dogs named Alice and Orli"

        // Attempt 1: a paraphrase the user never said is rejected with the
        // retry instruction, not a deflection.
        let firstReply = model.applyMemoryProposalTool(
            arguments: #"{"statement":"my dogs are wonderful loyal sidekicks","type":"userFact","sensitivity":"low","egress":"localOnly","requires_confirmation":false}"#,
            sourceUtterance: utterance,
            personalityID: personalityID,
            sourceLocator: "test:retry-1",
            effectLedger: effectLedger,
            authorization: authorization
        )
        XCTAssertTrue(firstReply.contains("Retry propose_memory"), firstReply)
        XCTAssertTrue(firstReply.contains("Do not ask the user to repeat themselves"), firstReply)

        // Attempt 2: the grammatical restatement of the user's ASR-mangled
        // turn saves immediately.
        let savedStatement = "my other dogs are named Alice and Orli"
        let secondReply = model.applyMemoryProposalTool(
            arguments: #"{"statement":"my other dogs are named Alice and Orli","type":"userFact","sensitivity":"low","egress":"localOnly","requires_confirmation":false}"#,
            sourceUtterance: utterance,
            personalityID: personalityID,
            sourceLocator: "test:retry-2",
            effectLedger: effectLedger,
            authorization: authorization
        )
        XCTAssertTrue(secondReply.contains("saved on this Mac"), secondReply)
        XCTAssertTrue(memoryState.memoryRecords.contains { $0.statement == savedStatement })

        // Attempt 3: a second save in the same turn is refused.
        let thirdReply = model.applyMemoryProposalTool(
            arguments: #"{"statement":"my name is Dan Vermilion Quartz","type":"userFact","sensitivity":"low","egress":"localOnly","requires_confirmation":false}"#,
            sourceUtterance: "Remember my name is Dan Vermilion Quartz.",
            personalityID: personalityID,
            sourceLocator: "test:retry-3",
            effectLedger: effectLedger,
            authorization: authorization
        )
        XCTAssertTrue(thirdReply.contains("already saved a memory"), thirdReply)
        XCTAssertFalse(memoryState.memoryRecords.contains { $0.statement == "my name is Dan Vermilion Quartz" })

        if let stored = memoryState.memoryRecords.first(where: { $0.statement == savedStatement }) {
            memoryState.forgetMemory(id: stored.id)
        }
        XCTAssertFalse(memoryState.memoryRecords.contains { $0.statement == savedStatement })
    }

    /// The retry loop is bounded: the third rejection tells the model to stop
    /// and inform the user, and a fourth attempt is refused outright.
    func testMemoryAttemptCapExhaustsAfterThreeRejections() throws {
        let (model, defaults) = try makeModel()
        defer { defaults.restore() }
        let memoryState = AttacheContextUIState.shared
        let priorMode = memoryState.memoryMode
        defer { memoryState.setMemoryMode(priorMode, explicit: false) }
        memoryState.setMemoryMode(.on, explicit: false)
        model.bindMemoryContextUI(to: memoryState)

        model.startConversation()
        defer { model.endConversation() }
        let authorization = try XCTUnwrap(model.issueConversationRequestAuthorization())
        let effectLedger = ConversationTurnEffectLedger()
        let personalityID = model.activePersonality?.id ?? "attache"
        let arguments = #"{"statement":"quartz gardens bloom at midnight","type":"userFact","sensitivity":"low","egress":"localOnly","requires_confirmation":false}"#

        var replies: [String] = []
        for attempt in 0..<4 {
            replies.append(model.applyMemoryProposalTool(
                arguments: arguments,
                sourceUtterance: "Remember something else entirely.",
                personalityID: personalityID,
                sourceLocator: "test:cap-\(attempt)",
                effectLedger: effectLedger,
                authorization: authorization
            ))
        }

        XCTAssertTrue(replies[0].contains("Retry propose_memory"), replies[0])
        XCTAssertTrue(replies[1].contains("Retry propose_memory"), replies[1])
        XCTAssertTrue(replies[2].contains("couldn't be saved"), replies[2])
        XCTAssertFalse(replies[2].contains("Retry propose_memory"), replies[2])
        XCTAssertTrue(replies[3].contains("No memory attempts remain"), replies[3])
        XCTAssertFalse(memoryState.memoryRecords.contains { $0.statement == "quartz gardens bloom at midnight" })
    }

    func testContextOverflowPublishesExplicitRetryWithoutAutoFallbackAndExpiresAtHangup() async throws {
        let (model, defaults) = try makeModel()
        defer { defaults.restore() }
        let state = AttacheContextUIState.shared
        state.dismissOverflowRecovery()
        defer { state.dismissOverflowRecovery() }

        model.startConversation()
        let settings = AttachePresentationSettings(
            llmEnabled: true,
            provider: .ollama,
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            apiKey: "",
            apiKeySecretRef: "",
            model: "frozen-overflow-model",
            reasoningEffort: "low",
            serviceTier: nil,
            profilePrompt: ""
        )
        let draft = "Preserve this exact overflow draft."
        let snapshot = model.captureRequestSnapshot(
            role: .conversation,
            userInput: draft,
            settingsOverride: settings
        )
        model.handleConversationFailure(
            AttacheContextCompilerError.preEgressOverflow(
                userDraft: draft,
                requestedTokens: 65_000,
                hardLimit: 64_000
            ),
            failedPrompt: draft,
            attemptedProvider: .ollama,
            frozenSnapshot: snapshot,
            attemptedSettings: settings
        )
        await Task.yield()

        XCTAssertEqual(state.overflowRecovery?.preservedDraft, draft)
        XCTAssertEqual(model.conversationDraft, draft)
        XCTAssertEqual(model.conversationFallbackHopCount, 0)

        let efficient = snapshot.retryingOverflow(with: .efficient)
        XCTAssertEqual(efficient.contextStrategy, .efficient)
        XCTAssertEqual(efficient.requestID, snapshot.requestID)
        XCTAssertEqual(efficient.userInput, snapshot.userInput)
        XCTAssertEqual(efficient.session, snapshot.session)
        XCTAssertEqual(efficient.modelSettings, snapshot.modelSettings)
        XCTAssertEqual(efficient.contextItems, snapshot.contextItems)

        model.endConversation()
        state.retryOverflow(using: .efficient)
        await Task.yield()
        XCTAssertFalse(model.conversationActive)
        XCTAssertFalse(model.isConversing)
    }
}
