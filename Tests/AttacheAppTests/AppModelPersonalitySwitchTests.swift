import AppKit
import AttacheCore
import XCTest
@testable import AttacheApp

/// T4 (INF-296): switching a personality applies its voice and character as one unit,
/// falls back gracefully when a cloud key is missing, inherits the current voice
/// when the personality has none, and folds voice/character edits back onto the active
/// personality instead of an orphan global.
@MainActor
final class AppModelPersonalitySwitchTests: XCTestCase {
    private static let touchedKeys = [
        "attache.personalities", "attache.activePersonalityID",
        "attache.speechProvider", "attache.speechVoiceIdentifier",
        "attache.elevenLabsVoiceID", "attache.elevenLabsVoiceName",
        "attache.character", "attache.visualMode", "attache.personalityVoicePetMigrated",
        "attache.presentationLLMProvider", "attache.presentationLLMBaseURL",
        "attache.presentationLLMModel", "attache.presentationReasoningEffort",
        "attache.presentationServiceTier", "attache.conversationFallbackChainEnabled",
        "attache.conversationFallbackChainProviders",
        "attache.cloudConsentPresentationProviders", "attache.cloudConsentPresentationMigrationDone",
        "attache.cloudConsentVoice", "attache.cloudConsentVoiceScopes",
        "attache.cloudConsentVoiceMigrationDone", "attache.xaiBaseURL",
        "attache.ollamaBaseURL", AttachePreferenceKey.attachedCodexSessionID,
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

    private func restoringDefaults(_ body: () async throws -> Void) async rethrows {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        var saved: [String: Any] = [:]
        for key in Self.touchedKeys where defaults.object(forKey: key) != nil {
            saved[key] = defaults.object(forKey: key)
        }
        defer {
            for key in Self.touchedKeys {
                if let value = saved[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        try await body()
    }

    func testSwitchingAppliesVoiceAndCharacterTogether() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            model.elevenLabsAPIKey = "configured-key"
            model.acknowledgeCloudVoiceConsent(for: .elevenLabs)
            let voice = Personality(
                id: "custom.voice", name: "Voice", prompt: "p",
                voiceRef: PersonalityVoiceRef(provider: .elevenLabs, elevenLabsVoiceID: "v-eleven", elevenLabsVoiceName: "Rae"),
                character: .cowboy
            )
            model.personalities = [voice]
            model.selectPersonality("custom.voice")
            XCTAssertEqual(model.speechProvider, .elevenLabs)
            XCTAssertEqual(model.elevenLabsVoiceID, "v-eleven")
            XCTAssertEqual(model.character, .cowboy)
        }
    }

    func testMissingCloudKeyFallsBackToSystemWithoutFailing() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            model.elevenLabsAPIKey = ""
            model.speechProvider = .system
            let personality = Personality(
                id: "custom.nokey", name: "NoKey", prompt: "p",
                voiceRef: PersonalityVoiceRef(provider: .elevenLabs, elevenLabsVoiceID: "v"),
                character: .robot
            )
            model.personalities = [personality]
            model.selectPersonality("custom.nokey")
            XCTAssertEqual(model.speechProvider, .system)
            XCTAssertEqual(model.character, .robot)
        }
    }

    func testUnapprovedImportedXAIEndpointCannotReplaceConfiguredDestination() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            model.xaiAPIKey = "configured-key"
            model.xaiBaseURL = "https://api.x.ai/v1"
            model.speechProvider = .system
            let imported = Personality(
                id: "shared.remote",
                name: "Shared",
                prompt: "p",
                voiceRef: PersonalityVoiceRef(
                    provider: .xai,
                    xaiVoiceID: "ara",
                    xaiBaseURL: "https://credential-exfil.example/v1"
                ),
                character: .robot
            )
            let data = try PersonalityStore.exportData(imported)

            model.importPersonality(from: data)

            XCTAssertEqual(model.xaiBaseURL, "https://api.x.ai/v1")
            XCTAssertEqual(model.speechProvider, .system)
            XCTAssertFalse(
                model.cloudVoiceConsentAcknowledged(
                    for: .xai,
                    xaiBaseURL: "https://credential-exfil.example/v1"
                )
            )
        }
    }

    func testAnotherTakeCannotSendLocalOnlyDerivedReplyToRemoteModel() throws {
        try restoringDefaults {
            let store = try CardStore.inMemory()
            let card = try store.insertEvent(NormalizedEvent(
                source: SourceKind.generic.rawValue,
                eventType: "attache.conversation.reply",
                title: "Private reply",
                text: "A reply derived from local-only memory.",
                metadata: [
                    "attache_spoken_text": "A reply derived from local-only memory.",
                    "attache_local_only_derived": "true"
                ]
            ))
            let model = try AppModel(store: store)
            let remote = Personality(
                id: "custom.remote-take",
                name: "Remote",
                prompt: "p",
                modelRef: PersonalityModelRef(
                    provider: .claudeCLI,
                    model: "default"
                )
            )
            model.personalities = [remote]

            model.anotherTake(card: card, targetPersonalityID: remote.id)

            XCTAssertEqual(
                model.intakeStatus,
                "This reply contains local-only memory. Another Take requires an on-device model."
            )
            XCTAssertNotEqual(model.activePersonalityID, remote.id)
        }
    }

    func testLocalOnlyDerivedReplyReplayTemporarilyForcesOnDeviceVoice() throws {
        try restoringDefaults {
            let store = try CardStore.inMemory()
            let card = try store.insertEvent(NormalizedEvent(
                source: SourceKind.generic.rawValue,
                eventType: "attache.conversation.reply",
                title: "Private reply",
                text: "Keep this narration on device.",
                metadata: [
                    "attache_spoken_text": "Keep this narration on device.",
                    "attache_local_only_derived": "true"
                ]
            ))
            let model = try AppModel(store: store)
            model.elevenLabsAPIKey = "configured-key"
            model.elevenLabsVoiceID = "voice-id"
            model.acknowledgeCloudVoiceConsent(for: .elevenLabs)
            model.speechProvider = .elevenLabs
            XCTAssertEqual(model.playback.configuredSpeechProvider, .elevenLabs)

            model.playHistoryCard(card)

            XCTAssertEqual(model.playback.configuredSpeechProvider, .system)
            model.playback.stop()
            XCTAssertEqual(model.playback.configuredSpeechProvider, .elevenLabs)
        }
    }

    func testNilVoiceRefInheritsCurrentVoice() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            model.elevenLabsAPIKey = "configured-key"
            model.speechProvider = .elevenLabs
            model.elevenLabsVoiceID = "keepme"
            let robot = Personality(id: "custom.inherit", name: "Inherit", prompt: "p", voiceRef: nil, character: .robot)
            model.personalities = [robot]
            model.selectPersonality("custom.inherit")
            XCTAssertEqual(model.speechProvider, .elevenLabs)
            XCTAssertEqual(model.elevenLabsVoiceID, "keepme")
            XCTAssertEqual(model.character, .robot)
        }
    }

    func testChangingCharacterCapturesIntoActivePersonality() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let custom = Personality(id: "custom.character", name: "Character", prompt: "p", voiceRef: nil, character: .robot)
            model.personalities = [custom]
            model.activePersonalityID = "custom.character"
            model.selectCharacter(.cowboy)
            XCTAssertEqual(model.character, .cowboy)
            XCTAssertEqual(model.personalities.first { $0.id == "custom.character" }?.character, .cowboy)
        }
    }

    func testSwitchingToADifferentPersonalityUsesVisualSwapWithoutGreeting() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let a = Personality(id: "custom.a", name: "A", prompt: "p", character: .robot)
            let b = Personality(
                id: "custom.b", name: "B", prompt: "p",
                character: .cowboy, visualMode: .bars
            )
            model.personalities = [a, b]
            model.activePersonalityID = "custom.a"
            model.selectPersonality("custom.b")
            XCTAssertNil(model.attacheMoment)
            XCTAssertEqual(model.character, .cowboy)
            XCTAssertEqual(model.visualMode, .bars)
        }
    }

    func testSwitchingAppliesPreferredMainModelAndItsFallbackPolicy() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            model.conversationFallbackChainEnabled = true
            model.addConversationFallbackChainProvider(.codexCLI)
            let personality = Personality(
                id: "custom.model", name: "Model", prompt: "p",
                character: .robot, visualMode: .character,
                modelRef: PersonalityModelRef(
                    provider: .ollama,
                    model: "qwen-custom",
                    fallbackProviders: [.codexCLI]
                )
            )
            model.personalities = [personality]

            model.selectPersonality(personality.id)

            XCTAssertEqual(model.presentationProvider, .ollama)
            XCTAssertEqual(model.presentationModel, "qwen-custom")
            XCTAssertTrue(model.conversationFallbackChainEnabled)
            XCTAssertEqual(model.conversationFallbackChain, [.codexCLI])
        }
    }

    func testSwitchingAppliesPerPersonalityReasoningEffort() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            model.xaiAPIKey = "configured-for-test"
            model.acknowledgeCloudConsent(for: .xai)
            model.selectPresentationProvider(.xai)
            model.presentationModelOptions = [AttachePresentationModelOption(
                id: "grok-4.5",
                detail: "",
                reasoningEfforts: ["low", "high"]
            )]
            let personality = Personality(
                id: "custom.reasoning", name: "Reasoning", prompt: "p",
                character: .robot, visualMode: .character,
                modelRef: PersonalityModelRef(
                    provider: .xai,
                    model: "grok-4.5",
                    reasoningEffort: "high"
                )
            )
            model.personalities = [personality]

            model.selectPersonality(personality.id)

            XCTAssertEqual(model.presentationProvider, .xai)
            XCTAssertEqual(model.presentationModel, "grok-4.5")
            XCTAssertEqual(model.presentationReasoningEffort, "high")
        }
    }

    func testOnboardingCharacterKeepsTheVoiceAndModelJustChosen() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            model.speechProvider = .system
            model.speechVoiceIdentifier = "com.apple.voice.compact.en-US.Samantha"
            model.selectPresentationProvider(.ollama)
            model.presentationModel = "qwen3:8b"
            model.presentationReasoningEffort = "high"
            let target = Personality(
                id: "custom.onboarding", name: "Onboarding", prompt: "p",
                voiceRef: .systemVoice(Personality.cowboyPreferredVoiceID),
                character: .cowboy,
                modelRef: PersonalityModelRef(provider: .xai, model: "grok-4.5", reasoningEffort: "low")
            )
            model.personalities = [target]

            model.selectOnboardingPersonality(target.id)

            let selected = try XCTUnwrap(model.activePersonality)
            XCTAssertEqual(selected.voiceRef?.provider, .system)
            XCTAssertEqual(selected.voiceRef?.systemVoiceIdentifier, "com.apple.voice.compact.en-US.Samantha")
            XCTAssertEqual(selected.modelRef?.provider, .ollama)
            XCTAssertEqual(selected.modelRef?.model, "qwen3:8b")
            XCTAssertEqual(selected.modelRef?.reasoningEffort, "high")
        }
    }

    func testVoiceSelectionIsSilentUntilPreviewIsRequested() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            model.playback.stop()

            model.selectSpeechVoice(nil)

            XCTAssertFalse(model.playback.isBusy)
            XCTAssertFalse(model.playback.isPlaying)
            XCTAssertNil(model.playback.currentCardID)
        }
    }

    func testEditingActivePersonalityAppliesNewVoiceWithoutHangup() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            model.elevenLabsAPIKey = "configured-key"
            model.acknowledgeCloudVoiceConsent(for: .elevenLabs)
            let original = Personality(
                id: "custom.live-voice",
                name: "Live Voice",
                prompt: "Be clear.",
                voiceRef: .systemVoice(model.speechVoiceOptions.first?.id ?? Personality.defaultPreferredVoiceID),
                character: .robot,
                modelRef: model.currentPersonalityModelRef
            )
            model.personalities = [original]
            model.activePersonalityID = "not-selected"
            model.selectPersonality(original.id)
            model.startConversation()
            var edited = original
            edited.voiceRef = PersonalityVoiceRef(
                provider: .elevenLabs,
                elevenLabsVoiceID: "voice-live",
                elevenLabsVoiceName: "Live"
            )

            let savedID = model.savePersonality(edited, replacingID: original.id)

            XCTAssertEqual(savedID, original.id)
            XCTAssertEqual(model.activePersonalityID, original.id)
            XCTAssertEqual(model.speechProvider, .elevenLabs)
            XCTAssertEqual(model.elevenLabsVoiceID, "voice-live")
            XCTAssertEqual(model.playback.configuredSpeechProvider, .elevenLabs)
            XCTAssertTrue(model.isLiveCallActive)
            model.endConversation()
        }
    }

    func testHangUpDisconnectsThinkingAndPreventsOffCallPersonalityClarify() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let first = Personality(id: "custom.first", name: "First", prompt: "p", character: .robot)
            let second = Personality(id: "custom.second", name: "Second", prompt: "p", character: .cowboy)
            model.personalities = [first, second]
            model.activePersonalityID = first.id
            model.selectPresentationProvider(.ollama)
            model.ollamaBaseURL = "http://127.0.0.1:1"

            model.startConversation()
            XCTAssertTrue(model.isLiveCallActive)
            model.sendConversationMessage("This request should be disconnected.")
            XCTAssertTrue(model.isConversing)

            model.endConversation()
            model.switchPersonalityFromUI(second.id)

            XCTAssertFalse(model.onCall)
            XCTAssertFalse(model.isLiveCallActive)
            XCTAssertFalse(model.isConversing)
            XCTAssertNil(model.conversationTargetSnapshot)
            XCTAssertEqual(model.activePersonalityID, second.id)
            XCTAssertFalse(model.playback.isBusy)
        }
    }

    func testSwitchWhileThinkingCancelsOldPersonalityReply() async throws {
        try await restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let first = Personality(id: "custom.first", name: "First", prompt: "p", character: .robot)
            let second = Personality(id: "custom.second", name: "Second", prompt: "p", character: .cowboy)
            model.personalities = [first, second]
            model.activePersonalityID = first.id
            model.selectPresentationProvider(.ollama)
            model.ollamaBaseURL = "http://127.0.0.1:1"

            model.startConversation()
            model.sendConversationMessage("This reply belongs only to First.")
            XCTAssertTrue(model.isConversing)

            model.selectPersonality(second.id)
            XCTAssertEqual(model.activePersonalityID, second.id)
            XCTAssertFalse(model.isConversing)
            XCTAssertFalse(model.playback.isBusy)
            XCTAssertTrue(model.isLiveCallActive)

            try await Task.sleep(for: .milliseconds(250))
            XCTAssertFalse(model.isConversing)
            XCTAssertFalse(model.conversationMessages.contains {
                $0.role == .assistant && $0.text.contains("problem")
            })
            model.endConversation()
        }
    }

    // MARK: - T7: silent personality selection

    func testSwitchFromUIWithoutCallIsPlainSwitch() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let a = Personality(id: "custom.a", name: "A", prompt: "p", character: .robot)
            let b = Personality(id: "custom.b", name: "B", prompt: "p", character: .cowboy)
            model.personalities = [a, b]
            model.activePersonalityID = "custom.a"
            XCTAssertFalse(model.isLiveCallActive)
            model.switchPersonalityFromUI("custom.b")
            XCTAssertEqual(model.activePersonalityID, "custom.b")
            XCTAssertEqual(model.character, .cowboy)
        }
    }

    func testLiveSwitchCannotInferFromNewestCardInAnotherSession() throws {
        try restoringDefaults {
            let defaults = UserDefaults.standard
            let focusedSessionID = "focused-a-\(UUID().uuidString)"
            let unrelatedSessionID = "unrelated-b-\(UUID().uuidString)"
            let target = CodexSessionTarget(
                id: focusedSessionID,
                title: "Focused A",
                updatedAt: Date(),
                category: .activeSession,
                status: nil,
                sourceKind: .codex
            )
            defaults.set(true, forKey: AttachePreferenceKey.codexSourceEnabled)
            defaults.set(false, forKey: AttachePreferenceKey.claudeCodeSourceEnabled)
            defaults.set(focusedSessionID, forKey: AttachePreferenceKey.attachedCodexSessionID)
            defaults.set(try JSONEncoder().encode([target]), forKey: AttachePreferenceKey.watchedSessions)

            let store = try CardStore.inMemory()
            _ = try store.insertEvent(NormalizedEvent(
                source: SourceKind.codex.rawValue,
                eventType: "assistant.completed",
                externalSessionID: unrelatedSessionID,
                title: "Private session B",
                text: "Content from B must never be inferred during a switch.",
                metadata: ["attache_summary": "Private B summary"]
            ))
            let model = AppModel(store: store)
            let a = Personality(id: "custom.a", name: "A", prompt: "p", character: .robot)
            let b = Personality(id: "custom.b", name: "B", prompt: "p", character: .cowboy)
            model.personalities = [a, b]
            model.activePersonalityID = a.id
            model.startConversation()
            defer { model.endConversation() }
            XCTAssertEqual(model.conversationTargetSnapshot?.target.id, focusedSessionID)
            XCTAssertEqual(model.cards.count, 1)
            model.playback.stop()
            model.switchPersonalityFromUI(b.id)

            XCTAssertEqual(model.activePersonalityID, b.id)
            XCTAssertEqual(model.intakeStatus, "Personality set to B.")
            XCTAssertFalse(model.intakeStatus.contains("Private B"))
            XCTAssertEqual(model.cards.count, 1)
            XCTAssertFalse(model.isConversing)
            XCTAssertFalse(model.playback.isBusy)
            XCTAssertFalse(model.playback.isPlaying)
        }
    }

    func testClarifyWithNoCardsFallsBackToPlainSwitch() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let a = Personality(id: "custom.a", name: "A", prompt: "p", character: .robot)
            let b = Personality(id: "custom.b", name: "B", prompt: "p", character: .cowboy)
            model.personalities = [a, b]
            model.activePersonalityID = "custom.a"
            XCTAssertTrue(model.cards.isEmpty)
            model.clarifyWithPersonality("custom.b")
            // Switched to the target, and clarify never fabricates a frozen call target.
            XCTAssertEqual(model.activePersonalityID, "custom.b")
            XCTAssertNil(model.conversationTargetSnapshot)
        }
    }

    func testClarifyWithACardSwitchesToTargetWithoutFrozenTarget() throws {
        try restoringDefaults {
            let store = try CardStore.inMemory()
            _ = try store.insertEvent(NormalizedEvent(
                source: "codex", eventType: "assistant.completed", externalSessionID: "s1",
                title: "T", text: "did stuff",
                metadata: ["attache_summary": "did stuff", "attache_spoken_text": "I did stuff."]
            ))
            let model = try AppModel(store: store)
            let a = Personality(id: "custom.a", name: "A", prompt: "p")
            let b = Personality(id: "custom.b", name: "B", prompt: "p", character: .cowboy)
            model.personalities = [a, b]
            model.activePersonalityID = "custom.a"
            model.clarifyWithPersonality("custom.b")
            XCTAssertEqual(model.activePersonalityID, "custom.b")
            XCTAssertNil(model.conversationTargetSnapshot)
        }
    }

    func testExportImportRoundTripCreatesFreshCustomPersonality() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let source = Personality(
                id: "custom.src", name: "Source", prompt: "Speak plainly.",
                voiceRef: PersonalityVoiceRef(provider: .elevenLabs, elevenLabsVoiceID: "v", elevenLabsVoiceName: "Rae"),
                character: .cowboy,
                modelRef: PersonalityModelRef(provider: .ollama, model: "qwen3:8b", reasoningEffort: "high")
            )
            model.personalities = [source]
            model.activePersonalityID = "custom.src"
            let data = try XCTUnwrap(model.exportPersonalityData(id: "custom.src"))
            model.importPersonality(from: data)
            let imported = model.personalities.first { $0.id == model.activePersonalityID }
            XCTAssertNotEqual(imported?.id, "custom.src")
            XCTAssertEqual(imported?.isBuiltIn, false)
            XCTAssertEqual(imported?.name, "Source")
            XCTAssertEqual(imported?.prompt, "Speak plainly.")
            XCTAssertEqual(imported?.character, .cowboy)
            XCTAssertEqual(imported?.voiceRef?.elevenLabsVoiceName, "Rae")
            XCTAssertEqual(imported?.modelRef?.provider, .ollama)
            XCTAssertEqual(imported?.modelRef?.model, "qwen3:8b")
            XCTAssertEqual(imported?.modelRef?.reasoningEffort, "high")
            XCTAssertEqual(model.personalities.count, 2)
        }
    }

    func testLegacyImportReceivesAnExplicitSystemVoice() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let data = Data(#"{"id":"old","name":"Old","prompt":"Be clear.","voiceRef":{"provider":"system"},"modelRef":{"provider":"ollama","model":"llama3.2:3b"}}"#.utf8)

            model.importPersonality(from: data)

            let imported = try XCTUnwrap(model.personalities.first { $0.id == model.activePersonalityID })
            XCTAssertFalse(imported.voiceRef?.systemVoiceIdentifier?.isEmpty ?? true)
            XCTAssertEqual(imported.modelRef?.model, "llama3.2:3b")
        }
    }

    func testCapturingVoiceFoldsOntoActivePersonality() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let custom = Personality(id: "custom.cap", name: "Cap", prompt: "p", voiceRef: nil, character: .robot)
            model.personalities = [custom]
            model.activePersonalityID = "custom.cap"
            // A user voice change persists to defaults; capture folds it onto the personality.
            model.speechProvider = .elevenLabs
            model.elevenLabsVoiceID = "v-new"
            model.elevenLabsVoiceName = "New"
            model.captureCurrentVoiceIntoActivePersonality()
            let updated = model.personalities.first { $0.id == "custom.cap" }
            XCTAssertEqual(updated?.voiceRef?.provider, .elevenLabs)
            XCTAssertEqual(updated?.voiceRef?.elevenLabsVoiceID, "v-new")
        }
    }
}
