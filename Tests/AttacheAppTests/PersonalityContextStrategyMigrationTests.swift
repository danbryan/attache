import AttacheCore
import XCTest
@testable import AttacheApp

final class PersonalityContextStrategyMigrationTests: XCTestCase {

    /// An existing personality persisted before INF-305 has no
    /// `contextStrategy` key. Decoding it must succeed with a nil override and
    /// never raise a first-launch prompt (silent migration).
    func testPreInf305PersonalityDecodesWithoutContextStrategy() throws {
        let json = """
        {
          "id": "custom.legacy",
          "name": "Legacy",
          "prompt": "Speak plainly.",
          "isBuiltIn": false,
          "voiceRef": { "provider": "system", "systemVoiceIdentifier": "com.apple.voice.something" },
          "visualMode": "character"
        }
        """.data(using: .utf8)!
        let personality = try JSONDecoder().decode(Personality.self, from: json)
        XCTAssertEqual(personality.id, "custom.legacy")
        XCTAssertNil(personality.contextStrategy, "Migration adds the field as nil, not a prompt.")
    }

    /// A personality with a context strategy override round-trips through
    /// Codable (acceptance criterion 3, applied to the personality payload).
    func testPersonalityWithContextStrategyRoundTrips() throws {
        let personality = Personality(
            id: "custom.strategy",
            name: "Tight",
            prompt: "Be terse.",
            contextStrategy: AttacheContextStrategy(.custom, custom: AttacheContextCustomPolicy(
                hardInputLimit: 16_000, outputReserve: 2_048, toolReserve: 1_024, safetyMargin: 256
            ))
        )
        let data = try JSONEncoder().encode(personality)
        let restored = try JSONDecoder().decode(Personality.self, from: data)
        XCTAssertEqual(restored.contextStrategy?.kind, .custom)
        XCTAssertEqual(restored.contextStrategy?.custom?.hardInputLimit, 16_000)
    }

    /// Per-personality override falls back cleanly to the global default
    /// (acceptance criterion 4): a personality without an override uses the
    /// global strategy; one with an override uses its own.
    func testPersonalityOverrideResolvesAgainstGlobal() {
        let global = AttacheContextStrategy.maximumCoverage
        let withoutOverride = Personality(id: "a", name: "A", prompt: "p")
        let withOverride = Personality(id: "b", name: "B", prompt: "p", contextStrategy: .efficient)

        XCTAssertEqual(
            AttacheContextStrategy.resolving(override: withoutOverride.contextStrategy, global: global),
            .maximumCoverage
        )
        XCTAssertEqual(
            AttacheContextStrategy.resolving(override: withOverride.contextStrategy, global: global),
            .efficient
        )
    }

    /// A built-in personality carries no detected capability facts, only an
    /// optional policy reference (INF-305 scope: a personality references
    /// policy, it does not duplicate mutable detected facts).
    func testBuiltinPersonalitiesDoNotCarryDetectedFacts() {
        for builtin in Personality.builtIns {
            XCTAssertNil(builtin.contextStrategy,
                         "Built-in \(builtin.name) ships with the global default, not a frozen detected profile.")
        }
    }

    func testInvalidLegacyCustomFallsBackToInheritanceWithVisibleNotice() throws {
        let invalid = Personality(
            id: "custom.invalid",
            name: "Legacy custom",
            prompt: "Speak plainly.",
            contextStrategy: AttacheContextStrategy(
                .custom,
                custom: AttacheContextCustomPolicy(
                    hardInputLimit: 1_000,
                    effectiveInputLimit: 2_000,
                    outputReserve: 700,
                    toolReserve: 700,
                    safetyMargin: 200
                )
            )
        )

        let restored = try JSONDecoder().decode(
            Personality.self,
            from: JSONEncoder().encode(invalid)
        )

        XCTAssertNil(restored.contextStrategy, "Unsafe legacy values must never be applied.")
        XCTAssertNotNil(restored.contextStrategyMigrationNotice)
        XCTAssertTrue(restored.contextStrategyMigrationNotice?.contains("incomplete Custom") == true)
    }

    func testDuplicatePreservesInheritanceAndEveryStrategyPreset() {
        let custom = AttacheContextStrategy(
            .custom,
            custom: AttacheContextCustomPolicy(
                hardInputLimit: 64_000,
                effectiveInputLimit: 48_000,
                outputReserve: 4_096,
                toolReserve: 4_096,
                safetyMargin: 1_024
            )
        )
        let strategies: [AttacheContextStrategy?] = [
            nil,
            .automatic,
            .maximumCoverage,
            .efficient,
            custom
        ]

        for (index, strategy) in strategies.enumerated() {
            let source = Personality(
                id: "source.\(index)",
                name: "Source",
                prompt: "p",
                voiceRef: .systemVoice(Personality.defaultPreferredVoiceID),
                character: .cowboy,
                visualMode: .character,
                modelRef: PersonalityModelRef(
                    provider: .ollama,
                    model: "qwen3",
                    reasoningEffort: "high",
                    fallbackProviders: [.groq]
                ),
                playbackSpeed: 1.2,
                accentColorHex: "#FFAA00",
                contextStrategy: strategy
            )

            let copy = source.duplicated(withID: "copy.\(index)")

            XCTAssertEqual(copy.contextStrategy, strategy)
            XCTAssertEqual(copy.voiceRef, source.voiceRef)
            XCTAssertEqual(copy.modelRef, source.modelRef)
            XCTAssertEqual(copy.playbackSpeed, source.playbackSpeed)
            XCTAssertFalse(copy.isBuiltIn)
        }
    }

    func testPersonalityImportExportRoundTripsNilNamedAndCustomStrategies() throws {
        let strategies: [AttacheContextStrategy?] = [
            nil,
            .automatic,
            .maximumCoverage,
            .efficient,
            AttacheContextStrategy(
                .custom,
                custom: AttacheContextCustomPolicy(
                    hardInputLimit: 32_000,
                    effectiveInputLimit: 24_000,
                    outputReserve: 2_048,
                    toolReserve: 2_048,
                    safetyMargin: 512
                )
            )
        ]

        for (index, strategy) in strategies.enumerated() {
            let exported = Personality(
                id: "export.\(index)",
                name: "Export",
                prompt: "p",
                contextStrategy: strategy
            )
            let imported = try JSONDecoder().decode(
                Personality.self,
                from: JSONEncoder().encode(exported)
            )
            XCTAssertEqual(imported.contextStrategy, strategy)
        }
    }
}
