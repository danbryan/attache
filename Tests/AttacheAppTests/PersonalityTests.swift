import XCTest
@testable import AttacheApp

final class PersonalityTests: XCTestCase {
    func testWelcomeArchetypesExistWithSubstantivePrompts() {
        for id in ["builtin.explainer", "builtin.bigPicture", "builtin.inquisitive"] {
            let personality = Personality.builtIns.first { $0.id == id }
            XCTAssertNotNil(personality, "\(id) missing from builtins")
            XCTAssertGreaterThan(personality?.prompt.count ?? 0, 120, "\(id) prompt is too thin")
        }
    }

    func testStoreMergesNewBuiltinsIntoOlderLists() {
        let suite = UserDefaults(suiteName: "personality-merge-test")!
        suite.removePersistentDomain(forName: "personality-merge-test")
        let store = PersonalityStore(defaults: suite)

        // Simulate an install persisted before Big Picture and Inquisitive existed.
        let old = Personality.builtIns.filter { !["builtin.bigPicture", "builtin.inquisitive"].contains($0.id) }
            + [Personality(id: "custom.mine", name: "Mine", prompt: "Be nice.")]
        store.save(old, activeID: "custom.mine")

        let loaded = store.load()
        XCTAssertTrue(loaded.personalities.contains { $0.id == "builtin.bigPicture" })
        XCTAssertTrue(loaded.personalities.contains { $0.id == "builtin.inquisitive" })
        XCTAssertTrue(loaded.personalities.contains { $0.id == "custom.mine" })
        XCTAssertEqual(loaded.activeID, "custom.mine")
        suite.removePersistentDomain(forName: "personality-merge-test")
    }

    // MARK: - T1: personality owns its voice and pet

    func testBuiltInsCarryPetAndCowboyIsColt() {
        let byID = Dictionary(uniqueKeysWithValues: Personality.builtIns.map { ($0.id, $0) })
        XCTAssertEqual(byID["builtin.explainer"]?.petCharacter, .robot)
        XCTAssertEqual(byID["builtin.bigPicture"]?.petCharacter, .robot)
        XCTAssertEqual(byID["builtin.inquisitive"]?.petCharacter, .robot)
        XCTAssertEqual(byID["builtin.cowboy"]?.petCharacter, .cowboy)
        XCTAssertEqual(byID["builtin.cowboy"]?.voiceRef?.provider, .system)
        XCTAssertEqual(byID["builtin.cowboy"]?.voiceRef?.systemVoiceIdentifier, Personality.cowboyPreferredVoiceID)
        // The three robots inherit the global voice (nil ref) rather than pin one.
        XCTAssertNil(byID["builtin.bigPicture"]?.voiceRef)
    }

    func testOldPersonalityJSONWithoutVoiceOrPetStillDecodes() throws {
        // A list persisted by v0.3.0, before personalities owned a voice or pet.
        let json = Data("""
        [{"id":"custom.mine","name":"Mine","prompt":"Be brief.","isBuiltIn":false}]
        """.utf8)
        let list = try JSONDecoder().decode([Personality].self, from: json)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.id, "custom.mine")
        XCTAssertNil(list.first?.voiceRef)
        XCTAssertNil(list.first?.petCharacter)
        XCTAssertNil(list.first?.accentColorHex)
    }

    func testPersonalityRoundTripsVoiceAndPet() throws {
        let original = Personality(
            id: "custom.eleven", name: "Eleven", prompt: "Narrate warmly.",
            voiceRef: PersonalityVoiceRef(
                provider: .elevenLabs,
                elevenLabsVoiceID: "abc123", elevenLabsVoiceName: "Rachel",
                elevenLabsModelID: "eleven_turbo_v2", elevenLabsOutputFormat: "mp3_44100_128"
            ),
            petCharacter: .cowboy,
            accentColorHex: "#BB87FC"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Personality.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.voiceRef?.provider, .elevenLabs)
        XCTAssertEqual(decoded.voiceRef?.elevenLabsVoiceName, "Rachel")
        XCTAssertEqual(decoded.petCharacter, .cowboy)
    }

    func testCaptureReadsGlobalVoiceKeys() {
        let suite = UserDefaults(suiteName: "voiceref-capture-test")!
        suite.removePersistentDomain(forName: "voiceref-capture-test")
        suite.set(CompanionSpeechProvider.elevenLabs.rawValue, forKey: CompanionPreferenceKey.speechProvider)
        suite.set("v-123", forKey: CompanionPreferenceKey.elevenLabsVoiceID)
        suite.set("Rachel", forKey: CompanionPreferenceKey.elevenLabsVoiceName)
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
        suite.set("stale-voice", forKey: CompanionPreferenceKey.speechVoiceIdentifier)
        PersonalityVoiceRef.systemVoice(nil).apply(to: suite)
        XCTAssertEqual(suite.string(forKey: CompanionPreferenceKey.speechProvider), "system")
        XCTAssertNil(suite.string(forKey: CompanionPreferenceKey.speechVoiceIdentifier))
        suite.removePersistentDomain(forName: "voiceref-apply-test")
    }

    // MARK: - T2: persistence and one-time voice/pet migration

    private func makeSuite(_ name: String) -> (UserDefaults, PersonalityStore) {
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return (suite, PersonalityStore(defaults: suite))
    }

    func testMigrationFoldsGlobalVoiceAndPetIntoActiveCustom() {
        let name = "personality-migrate-custom"
        let (suite, store) = makeSuite(name)
        // A v0.3.0 user: a custom personality is active, voice + pet are globals.
        let custom = Personality(id: "custom.mine", name: "Mine", prompt: "Be brief.")
        store.save(Personality.builtIns + [custom], activeID: custom.id)
        suite.set(CompanionSpeechProvider.elevenLabs.rawValue, forKey: CompanionPreferenceKey.speechProvider)
        suite.set("v-eleven", forKey: CompanionPreferenceKey.elevenLabsVoiceID)
        suite.set(BubblesPetCharacter.cowboy.rawValue, forKey: CompanionPreferenceKey.petCharacter)

        let loaded = store.load()
        let active = loaded.personalities.first { $0.id == loaded.activeID }
        XCTAssertEqual(loaded.activeID, "custom.mine")
        XCTAssertEqual(active?.voiceRef?.provider, .elevenLabs)
        XCTAssertEqual(active?.voiceRef?.elevenLabsVoiceID, "v-eleven")
        XCTAssertEqual(active?.petCharacter, .cowboy)
        XCTAssertTrue(suite.bool(forKey: "attache.personalityVoicePetMigrated"))
        suite.removePersistentDomain(forName: name)
    }

    func testMigrationIsIdempotentAndDoesNotOverwriteUserEdits() {
        let name = "personality-migrate-idempotent"
        let (suite, store) = makeSuite(name)
        let custom = Personality(id: "custom.mine", name: "Mine", prompt: "Be brief.")
        store.save(Personality.builtIns + [custom], activeID: custom.id)
        suite.set(CompanionSpeechProvider.elevenLabs.rawValue, forKey: CompanionPreferenceKey.speechProvider)
        suite.set("v-eleven", forKey: CompanionPreferenceKey.elevenLabsVoiceID)

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
        // Active is a built-in (Big Picture), but the user customized voice + pet.
        store.save(Personality.builtIns, activeID: "builtin.bigPicture")
        suite.set(CompanionSpeechProvider.elevenLabs.rawValue, forKey: CompanionPreferenceKey.speechProvider)
        suite.set("v-eleven", forKey: CompanionPreferenceKey.elevenLabsVoiceID)
        suite.set(BubblesPetCharacter.cowboy.rawValue, forKey: CompanionPreferenceKey.petCharacter)

        let loaded = store.load()
        // The built-in stays pristine.
        let bigPicture = loaded.personalities.first { $0.id == "builtin.bigPicture" }
        XCTAssertNil(bigPicture?.voiceRef)
        XCTAssertEqual(bigPicture?.petCharacter, .robot)
        // A new owned copy carries the customization and is now active.
        XCTAssertEqual(loaded.activeID, "custom.migrated.builtin.bigPicture")
        let copy = loaded.personalities.first { $0.id == loaded.activeID }
        XCTAssertEqual(copy?.isBuiltIn, false)
        XCTAssertEqual(copy?.voiceRef?.elevenLabsVoiceID, "v-eleven")
        XCTAssertEqual(copy?.petCharacter, .cowboy)
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

    func testPersistsVoiceAndPetAcrossReload() {
        let name = "personality-persist"
        let (suite, store) = makeSuite(name)
        // Skip migration to isolate plain persistence.
        suite.set(true, forKey: "attache.personalityVoicePetMigrated")
        let custom = Personality(
            id: "custom.rich", name: "Rich", prompt: "Warmly.",
            voiceRef: PersonalityVoiceRef(provider: .elevenLabs, elevenLabsVoiceID: "v9", elevenLabsVoiceName: "Rae"),
            petCharacter: .cowboy, accentColorHex: "#112233"
        )
        store.save(Personality.builtIns + [custom], activeID: custom.id)

        let reloaded = PersonalityStore(defaults: suite).load()
        let found = reloaded.personalities.first { $0.id == "custom.rich" }
        XCTAssertEqual(found?.voiceRef?.elevenLabsVoiceName, "Rae")
        XCTAssertEqual(found?.petCharacter, .cowboy)
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
        XCTAssertEqual(imported.petCharacter, .cowboy)
        XCTAssertEqual(imported.voiceRef?.systemVoiceIdentifier, Personality.cowboyPreferredVoiceID)
    }

    // MARK: - T3: manager UI summaries

    func testVoiceSummaryAndPetAvatarLabels() {
        XCTAssertEqual(Personality(id: "a", name: "A", prompt: "p").voiceSummary, "Inherits app voice")
        XCTAssertEqual(Personality(id: "b", name: "B", prompt: "p", voiceRef: .systemVoice(nil)).voiceSummary, "On-device voice")
        XCTAssertEqual(
            Personality(id: "c", name: "C", prompt: "p",
                        voiceRef: PersonalityVoiceRef(provider: .elevenLabs, elevenLabsVoiceName: "Rae")).voiceSummary,
            "ElevenLabs: Rae"
        )
        XCTAssertEqual(
            Personality(id: "d", name: "D", prompt: "p",
                        voiceRef: PersonalityVoiceRef(provider: .xai)).voiceSummary,
            "xAI voice"
        )
        XCTAssertEqual(Personality(id: "e", name: "E", prompt: "p", petCharacter: .cowboy).petAvatarEmoji, "🤠")
        XCTAssertEqual(Personality(id: "f", name: "F", prompt: "p").petAvatarEmoji, "🤖")
    }

    // MARK: - T9: onboarding bundles voice + pet

    func testOnboardingWelcomePersonalitiesAreCurrentBuiltIns() {
        let builtInIDs = Set(Personality.builtIns.map(\.id))
        XCTAssertFalse(OnboardingSheet.welcomePersonalities.isEmpty)
        for entry in OnboardingSheet.welcomePersonalities {
            XCTAssertTrue(builtInIDs.contains(entry.id), "onboarding references \(entry.id), not a current built-in")
            XCTAssertFalse(Personality.retiredBuiltInIDs.contains(entry.id), "onboarding references retired \(entry.id)")
        }
    }
}
