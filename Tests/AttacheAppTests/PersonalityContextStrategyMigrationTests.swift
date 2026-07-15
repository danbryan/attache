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
}