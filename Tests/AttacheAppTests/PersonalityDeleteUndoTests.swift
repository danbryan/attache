import AppKit
import AttacheCore
import XCTest
@testable import AttacheApp

/// INF-348: personality delete requires confirmation and offers undo.
/// The confirmation dialog itself is UI (exercised by ui-smoke); these tests
/// cover the AppModel state machine backing it: active-id reassignment on
/// delete, exact-value restoration at the same index on undo, and the
/// ten-second undo window expiring correctly using an injected clock.
@MainActor
final class PersonalityDeleteUndoTests: XCTestCase {
    private static let touchedKeys = [
        "attache.personalities", "attache.activePersonalityID",
        "attache.deletedBuiltInPersonalityIDs",
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

    func testDeletingActivePersonalityReassignsActiveID() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let a = Personality(id: "custom.a", name: "A", prompt: "p", character: .robot)
            let b = Personality(id: "custom.b", name: "B", prompt: "p", character: .cowboy)
            model.personalities = [a, b]
            model.activePersonalityID = a.id

            model.deletePersonality(id: a.id)

            XCTAssertNotNil(model.activePersonalityID)
            XCTAssertFalse(model.activePersonalityID.isEmpty)
            XCTAssertNotEqual(model.activePersonalityID, a.id)
            XCTAssertEqual(model.activePersonalityID, b.id)
            XCTAssertEqual(model.personalities.map(\.id), [b.id])
        }
    }

    func testUndoRestoresExactPersonalityAtSameIndex() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let a = Personality(id: "custom.a", name: "A", prompt: "p", character: .robot)
            let b = Personality(
                id: "custom.b", name: "B", prompt: "Be plain.",
                voiceRef: PersonalityVoiceRef(provider: .elevenLabs, elevenLabsVoiceID: "v", elevenLabsVoiceName: "Rae"),
                character: .cowboy,
                modelRef: PersonalityModelRef(provider: .ollama, model: "qwen3:8b")
            )
            let c = Personality(id: "custom.c", name: "C", prompt: "p", character: .robot)
            model.personalities = [a, b, c]
            model.activePersonalityID = a.id
            let fixedNow = Date()
            model.personalityUndoClock = { fixedNow }

            model.deletePersonality(id: b.id)
            XCTAssertEqual(model.personalities.map(\.id), [a.id, c.id])
            XCTAssertNotNil(model.recentlyDeletedPersonality)

            model.undoDeletePersonality()

            XCTAssertEqual(model.personalities.count, 3)
            XCTAssertEqual(model.personalities.map(\.id), [a.id, b.id, c.id])
            let restored = try XCTUnwrap(model.personalities.first { $0.id == b.id })
            XCTAssertEqual(restored, b)
            // Deleting a non-active personality never touches active selection.
            XCTAssertEqual(model.activePersonalityID, a.id)
            XCTAssertNil(model.recentlyDeletedPersonality)
        }
    }

    func testUndoRestoresActiveSelectionWhenDeletedWasActive() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let a = Personality(id: "custom.a", name: "A", prompt: "p", character: .robot)
            let b = Personality(id: "custom.b", name: "B", prompt: "p", character: .cowboy)
            model.personalities = [a, b]
            model.activePersonalityID = a.id
            let fixedNow = Date()
            model.personalityUndoClock = { fixedNow }

            model.deletePersonality(id: a.id)
            XCTAssertEqual(model.activePersonalityID, b.id)

            model.undoDeletePersonality()

            XCTAssertEqual(model.personalities.map(\.id), [a.id, b.id])
            XCTAssertEqual(model.activePersonalityID, a.id)
        }
    }

    func testUndoAfterWindowExpiresDoesNothing() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let a = Personality(id: "custom.a", name: "A", prompt: "p", character: .robot)
            let b = Personality(id: "custom.b", name: "B", prompt: "p", character: .cowboy)
            model.personalities = [a, b]
            model.activePersonalityID = a.id
            var now = Date()
            model.personalityUndoClock = { now }

            model.deletePersonality(id: b.id)
            XCTAssertEqual(model.personalities.map(\.id), [a.id])

            // Advance the injected clock past the ten-second undo window.
            now = now.addingTimeInterval(AppModel.personalityUndoWindow + 0.5)

            model.undoDeletePersonality()

            XCTAssertEqual(model.personalities.map(\.id), [a.id])
            XCTAssertNil(model.recentlyDeletedPersonality)
        }
    }

    func testConfirmedDeleteExposesRecentlyDeletedForUndoBar() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let a = Personality(id: "custom.a", name: "A", prompt: "p", character: .robot)
            let b = Personality(id: "custom.b", name: "B", prompt: "p", character: .cowboy)
            model.personalities = [a, b]
            model.activePersonalityID = a.id

            model.deletePersonality(id: b.id)

            let snapshot = try XCTUnwrap(model.recentlyDeletedPersonality)
            XCTAssertEqual(snapshot.personality, b)
            XCTAssertEqual(snapshot.index, 1)
            XCTAssertFalse(snapshot.wasActive)
        }
    }

    // INF-390: built-ins are now deletable, tombstoned, and restorable.
    func testDeletingBuiltInTombstonesItAndOffersUndo() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let builtIn = try XCTUnwrap(model.personalities.first { $0.id == "builtin.echo" })
            let originalCount = model.personalities.count

            model.deletePersonality(id: builtIn.id)

            XCTAssertEqual(model.personalities.count, originalCount - 1)
            XCTAssertFalse(model.personalities.contains { $0.id == builtIn.id })
            XCTAssertTrue(model.hasDeletedBuiltInPersonalities)
            let snapshot = try XCTUnwrap(model.recentlyDeletedPersonality)
            XCTAssertEqual(snapshot.personality.id, builtIn.id)
        }
    }

    func testUndoRestoresDeletedBuiltInAndClearsTombstone() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let builtIn = try XCTUnwrap(model.personalities.first { $0.id == "builtin.echo" })
            let fixedNow = Date()
            model.personalityUndoClock = { fixedNow }

            model.deletePersonality(id: builtIn.id)
            XCTAssertTrue(model.hasDeletedBuiltInPersonalities)

            model.undoDeletePersonality()

            XCTAssertTrue(model.personalities.contains { $0.id == builtIn.id })
            XCTAssertFalse(model.hasDeletedBuiltInPersonalities)
        }
    }

    func testRestoreDefaultPersonalitiesReAddsDeletedBuiltIn() throws {
        try restoringDefaults {
            let model = try AppModel(store: CardStore.inMemory())
            let builtIn = try XCTUnwrap(model.personalities.first { $0.id == "builtin.echo" })
            let custom = Personality(id: "custom.mine", name: "Mine", prompt: "p", character: .robot)
            model.personalities.append(custom)

            model.deletePersonality(id: builtIn.id)
            XCTAssertFalse(model.personalities.contains { $0.id == builtIn.id })

            model.restoreDefaultPersonalities()

            XCTAssertTrue(model.personalities.contains { $0.id == builtIn.id })
            XCTAssertTrue(model.personalities.contains { $0.id == custom.id })
            XCTAssertFalse(model.hasDeletedBuiltInPersonalities)
        }
    }

    func testLastRemainingPersonalityCannotBeDeleted() throws {
        try restoringDefaults {
            let only = Personality(id: "custom.only", name: "Only", prompt: "p", character: .robot)
            let model = try AppModel(store: CardStore.inMemory())
            model.personalities = [only]
            model.activePersonalityID = only.id

            model.deletePersonality(id: only.id)

            XCTAssertEqual(model.personalities.map(\.id), [only.id])
            XCTAssertNil(model.recentlyDeletedPersonality)
        }
    }
}
