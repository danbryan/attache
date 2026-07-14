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
}
