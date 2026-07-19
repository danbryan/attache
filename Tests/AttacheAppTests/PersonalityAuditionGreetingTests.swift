import AppKit
import AttacheCore
import XCTest
@testable import AttacheApp

/// The stable "Preview personality" audition line: cached per brain (name plus
/// prompt), reused verbatim on every click, regenerated only on a brain change
/// or an explicit New take. Voice and engine switches keep the same words.
@MainActor
final class PersonalityAuditionGreetingTests: XCTestCase {

    func testCacheValidityFollowsBrainNotVoice() {
        var personality = Personality(
            id: "p1",
            name: "Echoline",
            prompt: "Warm, brief, encouraging."
        )
        personality.cacheAuditionGreeting("Well hello there, ready to dive in?")
        XCTAssertEqual(personality.validAuditionGreeting, "Well hello there, ready to dive in?")

        // An engine or voice switch keeps the exact same words.
        personality.voiceRef = PersonalityVoiceRef(provider: .attachePremium)
        XCTAssertEqual(personality.validAuditionGreeting, "Well hello there, ready to dive in?")
        personality.voiceRef = .systemVoice("com.apple.voice.premium.en-GB.Jamie")
        XCTAssertEqual(personality.validAuditionGreeting, "Well hello there, ready to dive in?")

        // A prompt change invalidates the cache.
        var promptChanged = personality
        promptChanged.prompt = "Dry, terse, sardonic."
        XCTAssertNil(promptChanged.validAuditionGreeting)

        // A name change invalidates the cache.
        var nameChanged = personality
        nameChanged.name = "Volt"
        XCTAssertNil(nameChanged.validAuditionGreeting)
    }

    func testCachedGreetingSurvivesCodableRoundTrip() throws {
        var personality = Personality(id: "p2", name: "Colt", prompt: "Weathered cowboy.")
        personality.cacheAuditionGreeting("Howdy partner, saddle up and let's ride.")
        let decoded = try JSONDecoder().decode(
            Personality.self,
            from: JSONEncoder().encode(personality)
        )
        XCTAssertEqual(decoded.validAuditionGreeting, "Howdy partner, saddle up and let's ride.")

        // A legacy personality without the fields decodes with no cache.
        let legacy = try JSONDecoder().decode(
            Personality.self,
            from: Data(#"{"id":"p3","name":"Echo","prompt":"Voice only."}"#.utf8)
        )
        XCTAssertNil(legacy.validAuditionGreeting)
    }

    /// A valid cache is spoken verbatim with no model call: the completion
    /// returns the exact cached words synchronously, on every click.
    func testPreviewSpeaksCachedGreetingVerbatim() throws {
        _ = NSApplication.shared
        let model = AppModel(store: try CardStore.inMemory())
        let id = model.createPersonality(name: "Echoline", prompt: "Warm, brief, encouraging.")
        let index = try XCTUnwrap(model.personalities.firstIndex { $0.id == id })
        model.personalities[index].cacheAuditionGreeting("Steady cached hello from the test rig.")

        var spoken: [String] = []
        model.previewPersonality(model.personalities[index]) { spoken.append($0) }
        model.previewPersonality(model.personalities[index]) { spoken.append($0) }

        XCTAssertEqual(spoken, [
            "Steady cached hello from the test rig.",
            "Steady cached hello from the test rig."
        ])

        // A voice switch on the draft keeps the cached words.
        var draft = model.personalities[index]
        draft.voiceRef = PersonalityVoiceRef.systemVoice("com.apple.voice.premium.en-GB.Jamie")
        var switched: String?
        model.previewPersonality(draft) { switched = $0 }
        XCTAssertEqual(switched, "Steady cached hello from the test rig.")
    }

    /// A brain change misses the cache and, with no model configured, the
    /// deterministic offline fallback speaks instead of the stale words. An
    /// explicit New take also bypasses a valid cache.
    func testBrainChangeAndNewTakeBypassTheCache() throws {
        _ = NSApplication.shared
        let model = AppModel(store: try CardStore.inMemory())
        let id = model.createPersonality(name: "Echoline", prompt: "Warm, brief, encouraging.")
        let index = try XCTUnwrap(model.personalities.firstIndex { $0.id == id })
        model.personalities[index].cacheAuditionGreeting("Steady cached hello from the test rig.")
        // Pin the brain to a provider that is never connected in tests, so a
        // cache miss deterministically takes the offline fallback path instead
        // of dialing a local model server.
        model.personalities[index].modelRef = PersonalityModelRef(
            provider: .codexCLI,
            model: "codex-test"
        )

        var promptChanged = model.personalities[index]
        promptChanged.prompt = "Dry, terse, sardonic."
        var afterPromptChange: String?
        model.previewPersonality(promptChanged) { afterPromptChange = $0 }
        XCTAssertEqual(afterPromptChange, "Hi, I'm Echoline. Ready when you are.")

        var newTake: String?
        model.regeneratePersonalityPreview(model.personalities[index]) { newTake = $0 }
        XCTAssertEqual(newTake, "Hi, I'm Echoline. Ready when you are.")
    }
}
