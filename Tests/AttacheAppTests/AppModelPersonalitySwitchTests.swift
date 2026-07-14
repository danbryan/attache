import AppKit
import AttacheCore
import XCTest
@testable import AttacheApp

/// T4 (INF-296): switching a personality applies its voice and pet as one unit,
/// falls back gracefully when a cloud key is missing, inherits the current voice
/// when the personality has none, and folds voice/pet edits back onto the active
/// personality instead of an orphan global.
@MainActor
final class AppModelPersonalitySwitchTests: XCTestCase {
    private static let touchedKeys = [
        "attache.personalities", "attache.activePersonalityID",
        "attache.speechProvider", "attache.speechVoiceIdentifier",
        "attache.elevenLabsVoiceID", "attache.elevenLabsVoiceName",
        "attache.petCharacter", "attache.personalityVoicePetMigrated"
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

    func testSwitchingAppliesVoiceAndPetTogether() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            model.elevenLabsAPIKey = "configured-key"
            let voice = Personality(
                id: "custom.voice", name: "Voice", prompt: "p",
                voiceRef: PersonalityVoiceRef(provider: .elevenLabs, elevenLabsVoiceID: "v-eleven", elevenLabsVoiceName: "Rae"),
                petCharacter: .cowboy
            )
            model.personalities = [voice]
            model.selectPersonality("custom.voice")
            XCTAssertEqual(model.speechProvider, .elevenLabs)
            XCTAssertEqual(model.elevenLabsVoiceID, "v-eleven")
            XCTAssertEqual(model.petCharacter, .cowboy)
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
                petCharacter: .robot
            )
            model.personalities = [personality]
            model.selectPersonality("custom.nokey")
            XCTAssertEqual(model.speechProvider, .system)
            XCTAssertEqual(model.petCharacter, .robot)
        }
    }

    func testNilVoiceRefInheritsCurrentVoice() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            model.elevenLabsAPIKey = "configured-key"
            model.speechProvider = .elevenLabs
            model.elevenLabsVoiceID = "keepme"
            let robot = Personality(id: "custom.inherit", name: "Inherit", prompt: "p", voiceRef: nil, petCharacter: .robot)
            model.personalities = [robot]
            model.selectPersonality("custom.inherit")
            XCTAssertEqual(model.speechProvider, .elevenLabs)
            XCTAssertEqual(model.elevenLabsVoiceID, "keepme")
            XCTAssertEqual(model.petCharacter, .robot)
        }
    }

    func testChangingPetCapturesIntoActivePersonality() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let custom = Personality(id: "custom.pet", name: "Pet", prompt: "p", voiceRef: nil, petCharacter: .robot)
            model.personalities = [custom]
            model.activePersonalityID = "custom.pet"
            model.selectPetCharacter(.cowboy)
            XCTAssertEqual(model.petCharacter, .cowboy)
            XCTAssertEqual(model.personalities.first { $0.id == "custom.pet" }?.petCharacter, .cowboy)
        }
    }

    func testSwitchingToADifferentPersonalityGreetsAndFollowsCharacter() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let a = Personality(id: "custom.a", name: "A", prompt: "p", petCharacter: .robot)
            let b = Personality(id: "custom.b", name: "B", prompt: "p", petCharacter: .cowboy)
            model.personalities = [a, b]
            model.activePersonalityID = "custom.a"
            model.selectPersonality("custom.b")
            XCTAssertEqual(model.companionMoment?.kind, .greet)
            XCTAssertEqual(model.petCharacter, .cowboy)
        }
    }

    func testExportImportRoundTripCreatesFreshCustomPersonality() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let source = Personality(
                id: "custom.src", name: "Source", prompt: "Speak plainly.",
                voiceRef: PersonalityVoiceRef(provider: .elevenLabs, elevenLabsVoiceID: "v", elevenLabsVoiceName: "Rae"),
                petCharacter: .cowboy
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
            XCTAssertEqual(imported?.petCharacter, .cowboy)
            XCTAssertEqual(imported?.voiceRef?.elevenLabsVoiceName, "Rae")
            XCTAssertEqual(model.personalities.count, 2)
        }
    }

    func testCapturingVoiceFoldsOntoActivePersonality() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let custom = Personality(id: "custom.cap", name: "Cap", prompt: "p", voiceRef: nil, petCharacter: .robot)
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
