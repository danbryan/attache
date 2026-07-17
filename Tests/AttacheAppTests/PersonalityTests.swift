import XCTest
@testable import AttacheApp

final class PersonalityTests: XCTestCase {
    func testBuiltInWardrobeIsExactlyAttacheColtAndEcho() {
        XCTAssertEqual(Personality.builtIns.map(\.id), ["builtin.bigPicture", "builtin.cowboy", "builtin.echo"])
        XCTAssertEqual(Personality.builtIns.map(\.name), ["Attaché", "Colt", "Echo"])
        for personality in Personality.builtIns {
            XCTAssertGreaterThan(personality.prompt.count, 120, "\(personality.id) prompt is too thin")
            XCTAssertNotNil(personality.voiceRef)
            XCTAssertNotNil(personality.modelRef)
            XCTAssertEqual(personality.playbackSpeed, 1.0)
        }
    }

    func testStoreReplacesRetiredBuiltInsAndPreservesCustomCharacters() {
        let suite = UserDefaults(suiteName: "personality-merge-test")!
        suite.removePersistentDomain(forName: "personality-merge-test")
        let store = PersonalityStore(defaults: suite)

        let old = [
            Personality(id: "builtin.explainer", name: "Explainer", prompt: "Old", isBuiltIn: true),
            Personality(id: "builtin.inquisitive", name: "Inquisitive", prompt: "Old", isBuiltIn: true),
            Personality(id: "custom.mine", name: "Mine", prompt: "Be nice.")
        ]
        store.save(old, activeID: "custom.mine")

        let loaded = store.load()
        XCTAssertEqual(
            loaded.personalities.filter(\.isBuiltIn).map(\.id),
            ["builtin.bigPicture", "builtin.cowboy", "builtin.echo"]
        )
        XCTAssertFalse(loaded.personalities.contains { Personality.retiredBuiltInIDs.contains($0.id) })
        XCTAssertTrue(loaded.personalities.contains { $0.id == "custom.mine" })
        XCTAssertEqual(loaded.activeID, "custom.mine")
        suite.removePersistentDomain(forName: "personality-merge-test")
    }

    func testStoreBackfillsBuiltInPresenceAndExplicitConfiguration() {
        let suiteName = "personality-presence-migration-test"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        suite.set(true, forKey: "attache.personalityVoicePetMigrated")
        let store = PersonalityStore(defaults: suite)
        let legacyBuiltIn = Personality(
            id: "builtin.bigPicture", name: "Big Picture", prompt: "Legacy prompt",
            isBuiltIn: true, character: .robot, visualMode: nil
        )
        let legacyCustom = Personality(id: "custom.mine", name: "Mine", prompt: "Be brief.")
        store.save([legacyBuiltIn, legacyCustom], activeID: legacyBuiltIn.id)

        let loaded = store.load().personalities

        let migrated = loaded.first { $0.id == legacyBuiltIn.id }
        XCTAssertEqual(migrated?.name, "Attaché")
        XCTAssertNotEqual(migrated?.prompt, "Legacy prompt")
        XCTAssertEqual(migrated?.visualMode, .character)
        XCTAssertEqual(loaded.first { $0.id == legacyCustom.id }?.visualMode, .character)
        XCTAssertNotNil(loaded.first { $0.id == legacyCustom.id }?.voiceRef)
        XCTAssertNotNil(loaded.first { $0.id == legacyCustom.id }?.modelRef)
        suite.removePersistentDomain(forName: suiteName)
    }

    // MARK: - T1: personality owns its voice and character

    func testBuiltInsCarryTheirExpectedPresenceAndVoice() {
        let byID = Dictionary(uniqueKeysWithValues: Personality.builtIns.map { ($0.id, $0) })
        XCTAssertEqual(byID["builtin.bigPicture"]?.character, .robot)
        XCTAssertEqual(byID["builtin.bigPicture"]?.visualMode, .character)
        XCTAssertEqual(byID["builtin.cowboy"]?.character, .cowboy)
        XCTAssertEqual(byID["builtin.cowboy"]?.visualMode, .character)
        XCTAssertEqual(byID["builtin.cowboy"]?.voiceRef?.provider, .system)
        XCTAssertEqual(byID["builtin.cowboy"]?.voiceRef?.systemVoiceIdentifier, Personality.cowboyPreferredVoiceID)
        XCTAssertNil(byID["builtin.echo"]?.character)
        XCTAssertEqual(byID["builtin.echo"]?.visualMode, .bars)
        XCTAssertEqual(byID["builtin.echo"]?.characterAvatarEmoji, "🎙️")
        XCTAssertEqual(byID["builtin.bigPicture"]?.voiceRef, .systemVoice(Personality.defaultPreferredVoiceID))
    }

    func testOldPersonalityJSONWithoutVoiceOrCharacterStillDecodes() throws {
        // A list persisted by v0.3.0, before personalities owned a voice or character.
        let json = Data("""
        [{"id":"custom.mine","name":"Mine","prompt":"Be brief.","isBuiltIn":false}]
        """.utf8)
        let list = try JSONDecoder().decode([Personality].self, from: json)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.id, "custom.mine")
        XCTAssertNil(list.first?.voiceRef)
        XCTAssertNil(list.first?.character)
        XCTAssertNil(list.first?.visualMode)
        XCTAssertNil(list.first?.modelRef)
        XCTAssertNil(list.first?.accentColorHex)
    }

    func testPersonalityRoundTripsVoicePresenceAndModel() throws {
        let original = Personality(
            id: "custom.eleven", name: "Eleven", prompt: "Narrate warmly.",
            voiceRef: PersonalityVoiceRef(
                provider: .elevenLabs,
                elevenLabsVoiceID: "abc123", elevenLabsVoiceName: "Rachel",
                elevenLabsModelID: "eleven_turbo_v2", elevenLabsOutputFormat: "mp3_44100_128"
            ),
            character: .cowboy,
            visualMode: .bars,
            modelRef: PersonalityModelRef(
                provider: .codexCLI,
                model: "gpt-5",
                reasoningEffort: "high",
                serviceTier: "fast",
                fallbackProviders: [.ollama, .claudeCLI]
            ),
            playbackSpeed: 1.25,
            accentColorHex: "#BB87FC"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Personality.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.voiceRef?.provider, .elevenLabs)
        XCTAssertEqual(decoded.voiceRef?.elevenLabsVoiceName, "Rachel")
        XCTAssertEqual(decoded.character, .cowboy)
        XCTAssertEqual(decoded.visualMode, .bars)
        XCTAssertEqual(decoded.modelRef?.provider, .codexCLI)
        XCTAssertEqual(decoded.modelRef?.model, "gpt-5")
        XCTAssertEqual(decoded.modelRef?.fallbackProviders, [.ollama, .claudeCLI])
        XCTAssertEqual(decoded.playbackSpeed, 1.25)
    }

    func testLegacyPetKeysImportAsCurrentCharacterPresence() throws {
        let json = Data("""
        {
          "id": "legacy",
          "name": "Legacy",
          "prompt": "Keep it concise.",
          "isBuiltIn": false,
          "petCharacter": "cowboy",
          "visualMode": "pet"
        }
        """.utf8)

        let imported = try JSONDecoder().decode(Personality.self, from: json)

        XCTAssertEqual(imported.character, .cowboy)
        XCTAssertEqual(imported.visualMode, .character)
    }

    func testRetiredAbstractVisualizerImportsAsEchoBars() throws {
        let json = Data(#"{"id":"legacy","name":"Legacy","prompt":"Brief.","visualMode":"combined"}"#.utf8)

        let imported = try JSONDecoder().decode(Personality.self, from: json)

        XCTAssertEqual(imported.visualMode, .bars)
    }

    func testCaptureReadsGlobalVoiceKeys() {
        let suite = UserDefaults(suiteName: "voiceref-capture-test")!
        suite.removePersistentDomain(forName: "voiceref-capture-test")
        suite.set(AttacheSpeechProvider.elevenLabs.rawValue, forKey: AttachePreferenceKey.speechProvider)
        suite.set("v-123", forKey: AttachePreferenceKey.elevenLabsVoiceID)
        suite.set("Rachel", forKey: AttachePreferenceKey.elevenLabsVoiceName)
        let ref = PersonalityVoiceRef.capture(from: suite)
        XCTAssertEqual(ref.provider, .elevenLabs)
        XCTAssertEqual(ref.elevenLabsVoiceID, "v-123")
        XCTAssertEqual(ref.elevenLabsVoiceName, "Rachel")
        XCTAssertNil(ref.xaiVoiceID)
        suite.removePersistentDomain(forName: "voiceref-capture-test")
    }

    func testCaptureDefaultsToSystemWhenUnset() {
        let suite = UserDefaults(suiteName: "voiceref-empty-test")!
        suite.removePersistentDomain(forName: "voiceref-empty-test")
        let ref = PersonalityVoiceRef.capture(from: suite)
        XCTAssertEqual(ref.provider, .system)
        XCTAssertNil(ref.systemVoiceIdentifier)
        suite.removePersistentDomain(forName: "voiceref-empty-test")
    }

    func testResolvedDropsUnavailableSystemVoice() {
        let ref = PersonalityVoiceRef.systemVoice(Personality.cowboyPreferredVoiceID)
        let missing = ref.resolved(availableSystemVoiceIDs: ["com.apple.voice.compact.en-US.Samantha"])
        XCTAssertNil(missing.systemVoiceIdentifier)
        let present = ref.resolved(availableSystemVoiceIDs: [Personality.cowboyPreferredVoiceID])
        XCTAssertEqual(present.systemVoiceIdentifier, Personality.cowboyPreferredVoiceID)
    }

    func testApplyWritesProviderAndClearsSystemVoiceWhenDefault() {
        let suite = UserDefaults(suiteName: "voiceref-apply-test")!
        suite.removePersistentDomain(forName: "voiceref-apply-test")
        suite.set("stale-voice", forKey: AttachePreferenceKey.speechVoiceIdentifier)
        PersonalityVoiceRef.systemVoice(nil).apply(to: suite)
        XCTAssertEqual(suite.string(forKey: AttachePreferenceKey.speechProvider), "system")
        XCTAssertNil(suite.string(forKey: AttachePreferenceKey.speechVoiceIdentifier))
        suite.removePersistentDomain(forName: "voiceref-apply-test")
    }

    // MARK: - T2: persistence and one-time voice/character migration

    private func makeSuite(_ name: String) -> (UserDefaults, PersonalityStore) {
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return (suite, PersonalityStore(defaults: suite))
    }

    func testMigrationFoldsGlobalVoiceAndCharacterIntoActiveCustom() {
        let name = "personality-migrate-custom"
        let (suite, store) = makeSuite(name)
        // A v0.3.0 user: a custom personality is active, voice + character are globals.
        let custom = Personality(id: "custom.mine", name: "Mine", prompt: "Be brief.")
        store.save(Personality.builtIns + [custom], activeID: custom.id)
        suite.set(AttacheSpeechProvider.elevenLabs.rawValue, forKey: AttachePreferenceKey.speechProvider)
        suite.set("v-eleven", forKey: AttachePreferenceKey.elevenLabsVoiceID)
        suite.set(AttacheCharacter.cowboy.rawValue, forKey: AttachePreferenceKey.character)

        let loaded = store.load()
        let active = loaded.personalities.first { $0.id == loaded.activeID }
        XCTAssertEqual(loaded.activeID, "custom.mine")
        XCTAssertEqual(active?.voiceRef?.provider, .elevenLabs)
        XCTAssertEqual(active?.voiceRef?.elevenLabsVoiceID, "v-eleven")
        XCTAssertEqual(active?.character, .cowboy)
        XCTAssertTrue(suite.bool(forKey: "attache.personalityVoicePetMigrated"))
        suite.removePersistentDomain(forName: name)
    }

    func testMigrationIsIdempotentAndDoesNotOverwriteUserEdits() {
        let name = "personality-migrate-idempotent"
        let (suite, store) = makeSuite(name)
        let custom = Personality(id: "custom.mine", name: "Mine", prompt: "Be brief.")
        store.save(Personality.builtIns + [custom], activeID: custom.id)
        suite.set(AttacheSpeechProvider.elevenLabs.rawValue, forKey: AttachePreferenceKey.speechProvider)
        suite.set("v-eleven", forKey: AttachePreferenceKey.elevenLabsVoiceID)

        _ = store.load() // first load migrates
        // The user now edits their voice to xAI directly on the personality.
        var (list, activeID) = store.load()
        if let idx = list.firstIndex(where: { $0.id == "custom.mine" }) {
            list[idx].voiceRef = PersonalityVoiceRef(provider: .xai, xaiVoiceID: "x-1")
            store.save(list, activeID: activeID)
        }
        // A later launch must not re-run migration and clobber that edit.
        let reloaded = store.load()
        let active = reloaded.personalities.first { $0.id == "custom.mine" }
        XCTAssertEqual(active?.voiceRef?.provider, .xai)
        XCTAssertEqual(active?.voiceRef?.xaiVoiceID, "x-1")
        suite.removePersistentDomain(forName: name)
    }

    func testMigrationKeepsBuiltInPristineAndPreservesCustomizationAsCopy() {
        let name = "personality-migrate-builtin"
        let (suite, store) = makeSuite(name)
        // Active is a built-in (Big Picture), but the user customized voice + character.
        store.save(Personality.builtIns, activeID: "builtin.bigPicture")
        suite.set(AttacheSpeechProvider.elevenLabs.rawValue, forKey: AttachePreferenceKey.speechProvider)
        suite.set("v-eleven", forKey: AttachePreferenceKey.elevenLabsVoiceID)
        suite.set(AttacheCharacter.cowboy.rawValue, forKey: AttachePreferenceKey.character)

        let loaded = store.load()
        // The built-in keeps its canonical design and gets an explicit fallback
        // voice/model like every personality in the user-facing store.
        let bigPicture = loaded.personalities.first { $0.id == "builtin.bigPicture" }
        XCTAssertNotNil(bigPicture?.voiceRef)
        XCTAssertNotNil(bigPicture?.modelRef)
        XCTAssertEqual(bigPicture?.character, .robot)
        // A new owned copy carries the customization and is now active.
        XCTAssertEqual(loaded.activeID, "custom.migrated.builtin.bigPicture")
        let copy = loaded.personalities.first { $0.id == loaded.activeID }
        XCTAssertEqual(copy?.isBuiltIn, false)
        XCTAssertEqual(copy?.voiceRef?.elevenLabsVoiceID, "v-eleven")
        XCTAssertEqual(copy?.character, .cowboy)
        XCTAssertEqual(copy?.prompt, bigPicture?.prompt)
        suite.removePersistentDomain(forName: name)
    }

    func testMigrationNoOpForBuiltInActiveWithDefaultGlobals() {
        let name = "personality-migrate-noop"
        let (suite, store) = makeSuite(name)
        store.save(Personality.builtIns, activeID: "builtin.bigPicture")
        let loaded = store.load()
        // No customization to fold: no extra copy, still on the built-in.
        XCTAssertEqual(loaded.activeID, "builtin.bigPicture")
        XCTAssertFalse(loaded.personalities.contains { $0.id.hasPrefix("custom.migrated") })
        suite.removePersistentDomain(forName: name)
    }

    func testPersistsVoiceAndCharacterAcrossReload() {
        let name = "personality-persist"
        let (suite, store) = makeSuite(name)
        // Skip migration to isolate plain persistence.
        suite.set(true, forKey: "attache.personalityVoicePetMigrated")
        let custom = Personality(
            id: "custom.rich", name: "Rich", prompt: "Warmly.",
            voiceRef: PersonalityVoiceRef(provider: .elevenLabs, elevenLabsVoiceID: "v9", elevenLabsVoiceName: "Rae"),
            character: .cowboy, accentColorHex: "#112233"
        )
        store.save(Personality.builtIns + [custom], activeID: custom.id)

        let reloaded = PersonalityStore(defaults: suite).load()
        let found = reloaded.personalities.first { $0.id == "custom.rich" }
        XCTAssertEqual(found?.voiceRef?.elevenLabsVoiceName, "Rae")
        XCTAssertEqual(found?.character, .cowboy)
        XCTAssertEqual(found?.accentColorHex, "#112233")
        suite.removePersistentDomain(forName: name)
    }

    func testImportExportRoundTripAssignsFreshIDAndClearsBuiltIn() throws {
        let cowboy = Personality.builtIns.first { $0.id == "builtin.cowboy" }!
        let data = try PersonalityStore.exportData(cowboy)
        let imported = try PersonalityStore.importPersonality(from: data, newID: { "custom.fixed" })
        XCTAssertEqual(imported.id, "custom.fixed")
        XCTAssertFalse(imported.isBuiltIn)
        XCTAssertEqual(imported.name, cowboy.name)
        XCTAssertEqual(imported.prompt, cowboy.prompt)
        XCTAssertEqual(imported.character, .cowboy)
        XCTAssertEqual(imported.visualMode, .character)
        XCTAssertEqual(imported.voiceRef?.systemVoiceIdentifier, Personality.cowboyPreferredVoiceID)
    }

    func testShippingImportFixtureCoversTheCompleteCurrentSchema() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/personality-import.json")
        let imported = try JSONDecoder().decode(Personality.self, from: Data(contentsOf: fixtureURL))

        XCTAssertEqual(imported.character, .cowboy)
        XCTAssertEqual(imported.visualMode, .character)
        XCTAssertEqual(imported.voiceRef, .systemVoice(nil))
        XCTAssertEqual(imported.modelRef?.provider, .ollama)
        XCTAssertEqual(imported.modelRef?.fallbackProviders, [.codexCLI])
        XCTAssertEqual(imported.playbackSpeed, 1.15)
    }

    // MARK: - T3: manager UI summaries

    func testVoiceSummaryAndCharacterAvatarLabels() {
        XCTAssertEqual(Personality(id: "a", name: "A", prompt: "p").voiceSummary(in: []), "Voice not set")
        XCTAssertEqual(Personality(id: "b", name: "B", prompt: "p", voiceRef: .systemVoice(nil)).voiceSummary(in: []), "Voice not set")
        XCTAssertEqual(
            Personality(id: "c", name: "C", prompt: "p",
                        voiceRef: PersonalityVoiceRef(provider: .elevenLabs, elevenLabsVoiceName: "Rae")).voiceSummary(in: []),
            "ElevenLabs: Rae"
        )
        XCTAssertEqual(
            Personality(id: "d", name: "D", prompt: "p",
                        voiceRef: PersonalityVoiceRef(provider: .xai)).voiceSummary(in: []),
            "xAI voice"
        )
        // System voices resolve against the supplied options list, not a
        // fresh AttacheVoiceCatalog.options() call (INF-352 step 6).
        let systemOptions = [AttacheVoiceOption(id: "voice.x", name: "Xena", gender: "female", localeIdentifier: "en_US")]
        XCTAssertEqual(
            Personality(id: "j", name: "J", prompt: "p", voiceRef: .systemVoice("voice.x")).voiceSummary(in: systemOptions),
            "Xena (en-US)"
        )
        XCTAssertEqual(
            Personality(id: "k", name: "K", prompt: "p", voiceRef: .systemVoice("voice.missing")).voiceSummary(in: systemOptions),
            "voice.missing"
        )
        XCTAssertEqual(Personality(id: "e", name: "E", prompt: "p", character: .cowboy).characterAvatarEmoji, "🤠")
        XCTAssertEqual(Personality(id: "f", name: "F", prompt: "p").characterAvatarEmoji, "🤖")
        XCTAssertEqual(Personality(id: "g", name: "G", prompt: "p", visualMode: .bars).presenceSummary, "Echo voice bars")
        XCTAssertEqual(
            Personality(
                id: "h", name: "H", prompt: "p",
                modelRef: PersonalityModelRef(provider: .ollama, model: "qwen3:14b")
            ).modelSummary,
            "Ollama · qwen3:14b"
        )
        XCTAssertEqual(
            Personality(
                id: "i", name: "I", prompt: "p",
                modelRef: PersonalityModelRef(provider: .codexCLI, model: "gpt-5", reasoningEffort: "high")
            ).modelSummary,
            "Codex subscription · gpt-5 · High"
        )
    }

    func testStoreFillsEveryPersonalityWithExplicitVoiceAndModel() {
        let suiteName = "personality-explicit-configuration-test"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set(AttacheSpeechProvider.system.rawValue, forKey: AttachePreferenceKey.speechProvider)
        // Built-ins own their model rather than following these legacy global
        // values. The globals still fill truly old custom personalities.
        suite.set(AttachePresentationProvider.xai.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        suite.set("grok-4.5", forKey: AttachePreferenceKey.presentationLLMModel)
        suite.set("high", forKey: AttachePreferenceKey.presentationReasoningEffort)

        let loaded = PersonalityStore(defaults: suite).load().personalities

        XCTAssertFalse(loaded.isEmpty)
        XCTAssertTrue(loaded.allSatisfy { $0.voiceRef != nil })
        XCTAssertTrue(loaded.allSatisfy { $0.modelRef != nil })
        XCTAssertTrue(loaded.allSatisfy { $0.modelRef?.provider == .ollama })
        XCTAssertTrue(loaded.allSatisfy { $0.modelRef?.model == AttachePresentationProvider.ollama.defaultModel })
    }

    func testLegacyLMStudioPersonalityImportsAsOllama() throws {
        let data = Data(#"{"id":"legacy","name":"Legacy","prompt":"Speak plainly.","isBuiltIn":false,"modelRef":{"provider":"lmStudio","model":"old-model","reasoningEffort":"none"}}"#.utf8)

        let decoded = try JSONDecoder().decode(Personality.self, from: data)

        XCTAssertEqual(decoded.modelRef?.provider, .ollama)
        XCTAssertEqual(decoded.modelRef?.model, AttachePresentationProvider.ollama.defaultModel)
        XCTAssertEqual(decoded.modelRef?.reasoningEffort, AttachePresentationProvider.ollama.defaultReasoningEffort)
    }

    // MARK: - T9: onboarding bundles voice + character

    func testOnboardingIsTheFiveStepCharacterWorkflow() {
        XCTAssertEqual(
            OnboardingStep.allCases.map(\.title),
            [
                "Welcome to Attaché",
                "Connect your agents",
                "Pick a voice",
                "Connect a model",
                "Pick a character"
            ]
        )
    }

    func testOnboardingWelcomePersonalitiesAreCurrentBuiltIns() {
        let builtInIDs = Set(Personality.builtIns.map(\.id))
        XCTAssertEqual(OnboardingSheet.welcomePersonalities.map(\.id), ["builtin.bigPicture", "builtin.cowboy", "builtin.echo"])
        for entry in OnboardingSheet.welcomePersonalities {
            XCTAssertTrue(builtInIDs.contains(entry.id), "onboarding references \(entry.id), not a current built-in")
            XCTAssertFalse(Personality.retiredBuiltInIDs.contains(entry.id), "onboarding references retired \(entry.id)")
        }
    }

    // MARK: - MCP tool grants (INF-373)

    func testDefaultMCPToolGrantsAreEmpty() {
        let personality = Personality(id: "custom.mine", name: "Mine", prompt: "Be brief.")
        XCTAssertTrue(personality.mcpToolGrants.isEmpty)
    }

    func testMCPToolGrantsRoundTripThroughCoding() throws {
        var personality = Personality(id: "custom.grants", name: "Grants", prompt: "Be brief.")
        personality.mcpToolGrants = [
            "mcp__notes__search": .alwaysAllow,
            "mcp__notes__write": .askFirst
        ]
        let data = try JSONEncoder().encode(personality)
        let decoded = try JSONDecoder().decode(Personality.self, from: data)
        XCTAssertEqual(decoded.mcpToolGrants, personality.mcpToolGrants)

        // The interchange export path preserves grants too.
        let exported = try PersonalityStore.exportData(personality)
        let imported = try PersonalityStore.importPersonality(from: exported, newID: { "custom.new" })
        XCTAssertEqual(imported.mcpToolGrants, personality.mcpToolGrants)
    }

    func testLegacyPersonalityJSONWithoutGrantsDecodesAsEmpty() throws {
        let json = Data("""
        [{"id":"custom.mine","name":"Mine","prompt":"Be brief.","isBuiltIn":false}]
        """.utf8)
        let list = try JSONDecoder().decode([Personality].self, from: json)
        XCTAssertEqual(list.first?.mcpToolGrants, [:])
    }

    func testStorePersistsMCPToolGrants() {
        let suiteName = "personality-mcp-grants-test"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        suite.set(true, forKey: "attache.personalityVoicePetMigrated")
        let store = PersonalityStore(defaults: suite)

        var custom = Personality(id: "custom.mine", name: "Mine", prompt: "Be brief.")
        custom.mcpToolGrants = ["mcp__notes__search": .alwaysAllow]
        store.save([custom], activeID: custom.id)

        let loaded = store.load().personalities.first { $0.id == "custom.mine" }
        XCTAssertEqual(loaded?.mcpToolGrants, ["mcp__notes__search": .alwaysAllow])
        suite.removePersistentDomain(forName: suiteName)
    }
}
