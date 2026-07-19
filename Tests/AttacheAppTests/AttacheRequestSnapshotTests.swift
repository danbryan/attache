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
        memoryState.setMemoryMode(.automatic, explicit: false)

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
    /// with a valid seven-field payload, must land the proposal in the review
    /// queue in Suggest mode. Ledger and queue live in temp storage because the
    /// card store is in-memory.
    func testLiveCallMemoryProposalQueuesForReviewInSuggestMode() throws {
        let (model, defaults) = try makeModel()
        defer { defaults.restore() }
        let memoryState = AttacheContextUIState.shared
        let priorMode = memoryState.memoryMode
        defer { memoryState.setMemoryMode(priorMode, explicit: false) }
        memoryState.setMemoryMode(.suggest, explicit: false)
        // Init defers the same bind to a main-actor task; wire it now so the
        // review-queue cleanup below persists through this model's runtime.
        model.bindMemoryContextUI(to: memoryState)

        model.startConversation()
        defer { model.endConversation() }
        XCTAssertTrue(model.conversationAllowsMemoryProposals)
        let authorization = try XCTUnwrap(model.issueConversationRequestAuthorization())
        let effectLedger = ConversationTurnEffectLedger()

        let statement = "The user's name is Dan Vermilion Quartz"
        let reply = model.applyMemoryProposalTool(
            arguments: #"{"statement":"The user's name is Dan Vermilion Quartz","type":"userFact","scope":"global","scope_value":"global","sensitivity":"low","egress":"localOnly","requires_confirmation":true}"#,
            sourceUtterance: "remember my name is Dan Vermilion Quartz",
            personalityID: model.activePersonality?.id ?? "attache",
            sourceLocator: "test:suggest-queue",
            effectLedger: effectLedger,
            authorization: authorization
        )

        XCTAssertTrue(reply.contains("waiting for the user to review"), reply)
        let queued = memoryState.memoryReviewItems.first { $0.proposal.statement == statement }
        XCTAssertNotNil(queued)
        XCTAssertEqual(queued?.proposal.egress, .localOnly)
        XCTAssertFalse(memoryState.memoryRecords.contains { $0.statement == statement })
        XCTAssertFalse(
            effectLedger.claim(.memoryProposal),
            "the dispatch must have claimed the per-turn memory effect"
        )

        if let queued {
            memoryState.rejectMemoryProposal(id: queued.proposal.id)
        }
        XCTAssertFalse(memoryState.memoryReviewItems.contains { $0.proposal.statement == statement })
    }

    /// Automatic mode with an exact user restatement (after the "remember"
    /// lead-in is stripped) auto-stores as a user-authored record instead of
    /// queueing, and the record is forced local-only.
    func testLiveCallMemoryProposalAutoStoresExactUserRestatementInAutomaticMode() throws {
        let (model, defaults) = try makeModel()
        defer { defaults.restore() }
        let memoryState = AttacheContextUIState.shared
        let priorMode = memoryState.memoryMode
        defer { memoryState.setMemoryMode(priorMode, explicit: false) }
        memoryState.setMemoryMode(.automatic, explicit: false)
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
            sourceLocator: "test:automatic-store",
            effectLedger: effectLedger,
            authorization: authorization
        )

        XCTAssertTrue(reply.contains("saved on this Mac"), reply)
        XCTAssertFalse(memoryState.memoryReviewItems.contains { $0.proposal.statement == statement })
        let stored = memoryState.memoryRecords.first { $0.statement == statement }
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.sourceKind, .userAuthored)
        XCTAssertEqual(stored?.egress, .localOnly)

        if let stored {
            memoryState.forgetMemory(id: stored.id)
        }
        XCTAssertFalse(memoryState.memoryRecords.contains { $0.statement == statement })
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
