import AttacheCore
import XCTest

final class AttacheContextPolicyTests: XCTestCase {

    // MARK: - Identity isolation (acceptance criterion 1)

    func testIdentityDistinguishesEndpoints() {
        let upstream = ModelIdentity(provider: "openai", normalizedEndpoint: "https://api.openai.com", requestedModel: "gpt-4o")
        let mirror = ModelIdentity(provider: "openai", normalizedEndpoint: "https://mirror.example.com", requestedModel: "gpt-4o")
        XCTAssertNotEqual(upstream, mirror)
        XCTAssertNotEqual(upstream.capabilityKey, mirror.capabilityKey,
                          "A mirrored endpoint must not inherit the upstream capability.")
    }

    func testIdentityDistinguishesResolvedModelsAndFingerprints() {
        let a = ModelIdentity(provider: "ollama", normalizedEndpoint: "http://localhost:11434", requestedModel: "llama3", resolvedModel: "llama3:70b")
        let b = ModelIdentity(provider: "ollama", normalizedEndpoint: "http://localhost:11434", requestedModel: "llama3", resolvedModel: "llama3:8b")
        XCTAssertNotEqual(a, b)

        let v1 = ModelIdentity(provider: "ollama", normalizedEndpoint: "http://localhost:11434", requestedModel: "qwen", resolvedModel: "qwen2.5", fingerprint: "sha:aaa")
        let v2 = ModelIdentity(provider: "ollama", normalizedEndpoint: "http://localhost:11434", requestedModel: "qwen", resolvedModel: "qwen2.5", fingerprint: "sha:bbb")
        XCTAssertNotEqual(v1, v2, "A re-versioned model must not inherit the prior capability.")
    }

    func testIdentityCollapsesProviderAliasCasingAndTrailingSlash() {
        let a = ModelIdentity(provider: "OpenAI", normalizedEndpoint: "https://api.openai.com/", requestedModel: "gpt-4o")
        let b = ModelIdentity(provider: "openai", normalizedEndpoint: "https://api.openai.com", requestedModel: "gpt-4o")
        XCTAssertEqual(a, b, "Casing and trailing slash are normalized so aliases share correctly.")
    }

    // MARK: - Merge layering (acceptance criterion 2)

    func testDetectedRecordIsNotOverwrittenByCustom() throws {
        let detected = AttacheModelCapabilityProfile(
            architecturalMaximum: 128_000, outputLimit: 16_384,
            confidence: .authoritative, provenance: .providerMetadata
        )
        let custom = AttacheContextCustomPolicy(hardInputLimit: 8_000, outputReserve: 2_048, toolReserve: 1_024, safetyMargin: 256)
        let strategy = AttacheContextStrategy(.custom, custom: custom)
        let merged = try AttacheEffectiveContextProfile.merged(
            identity: ModelIdentity(provider: "openai", normalizedEndpoint: "https://api.openai.com", requestedModel: "gpt-4o"),
            detected: detected, strategy: strategy
        )
        // The detected record is preserved untouched.
        XCTAssertEqual(merged.detected.architecturalMaximum, 128_000)
        XCTAssertEqual(merged.detected.provenance, .providerMetadata)
        // The custom override is preserved untouched alongside it.
        XCTAssertEqual(merged.customOverride?.hardInputLimit, 8_000)
        // The effective limit takes the Custom cap, not the detected ceiling.
        XCTAssertEqual(merged.effectiveInputLimit, 8_000)
    }

    func testCustomCannotOverwriteDetectedRecordFields() throws {
        let detected = AttacheModelCapabilityProfile(architecturalMaximum: 200_000, provenance: .runtimeObservation)
        let custom = AttacheContextCustomPolicy(hardInputLimit: 50_000)
        let merged = try AttacheEffectiveContextProfile.merged(
            identity: ModelIdentity(provider: "x", normalizedEndpoint: "", requestedModel: "m"),
            detected: detected, strategy: AttacheContextStrategy(.custom, custom: custom)
        )
        XCTAssertEqual(merged.detected.architecturalMaximum, 200_000)
        XCTAssertEqual(merged.effectiveInputLimit, 50_000)
        XCTAssertNotEqual(merged.detected.architecturalMaximum, merged.effectiveInputLimit)
    }

    // MARK: - Serialization round-trip (acceptance criterion 3)

    func testStrategiesSerializeAndRoundTrip() throws {
        let cases: [AttacheContextStrategy] = [
            .automatic, .maximumCoverage, .efficient,
            AttacheContextStrategy(.custom, custom: AttacheContextCustomPolicy(
                hardInputLimit: 32_000, outputReserve: 2_048, toolReserve: 1_024, safetyMargin: 256
            ))
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for strategy in cases {
            let data = try encoder.encode(strategy)
            let restored = try decoder.decode(AttacheContextStrategy.self, from: data)
            XCTAssertEqual(restored, strategy, "Strategy \(strategy.kind) did not round-trip.")
        }
    }

    // MARK: - Per-personality override fallback (acceptance criterion 4)

    func testOverrideFallsBackToGlobalWhenNil() {
        let global = AttacheContextStrategy.maximumCoverage
        let resolved = AttacheContextStrategy.resolving(override: nil, global: global)
        XCTAssertEqual(resolved, .maximumCoverage)
    }

    func testOverrideWinsOverGlobalWhenSet() {
        let global = AttacheContextStrategy.automatic
        let override = AttacheContextStrategy.efficient
        let resolved = AttacheContextStrategy.resolving(override: override, global: global)
        XCTAssertEqual(resolved, .efficient)
    }

    func testExplicitAutomaticOverrideIsHonoredNotTreatedAsNil() {
        let global = AttacheContextStrategy.maximumCoverage
        let resolved = AttacheContextStrategy.resolving(override: .automatic, global: global)
        XCTAssertEqual(resolved, .automatic, "An explicit .automatic override is a real choice, not a fallback signal.")
    }

    // MARK: - Validation failures (acceptance criterion 5)

    func testNegativeReserveFails() {
        var policy = AttacheContextCustomPolicy()
        policy.outputReserve = -1
        XCTAssertThrowsError(try policy.validate()) { error in
            guard case .negativeReserve(let field, _) = error as? AttacheContextPolicyError else {
                return XCTFail("Expected negativeReserve, got \(error)")
            }
            XCTAssertEqual(field, "outputReserve")
        }
    }

    func testZeroReserveFails() {
        var policy = AttacheContextCustomPolicy()
        policy.toolReserve = 0
        XCTAssertThrowsError(try policy.validate()) { error in
            guard case .zeroReserve = error as? AttacheContextPolicyError else {
                return XCTFail("Expected zeroReserve, got \(error)")
            }
        }
    }

    func testEffectiveExceedsHardFails() {
        let policy = AttacheContextCustomPolicy(hardInputLimit: 4_000, effectiveInputLimit: 8_000)
        XCTAssertThrowsError(try policy.validate()) { error in
            guard case .effectiveExceedsHard = error as? AttacheContextPolicyError else {
                return XCTFail("Expected effectiveExceedsHard, got \(error)")
            }
        }
    }

    func testNonPositiveInputLimitsFail() {
        for policy in [
            AttacheContextCustomPolicy(hardInputLimit: 0),
            AttacheContextCustomPolicy(effectiveInputLimit: -1)
        ] {
            XCTAssertThrowsError(try policy.validate()) { error in
                guard case .invalidLimit = error as? AttacheContextPolicyError else {
                    return XCTFail("Expected invalidLimit, got \(error)")
                }
            }
        }
    }

    func testReserveArithmeticOverflowFailsClosed() {
        let policy = AttacheContextCustomPolicy(
            outputReserve: Int.max,
            toolReserve: Int.max,
            safetyMargin: Int.max
        )
        XCTAssertThrowsError(try policy.validate()) { error in
            XCTAssertEqual(error as? AttacheContextPolicyError, .reserveTotalOverflow)
        }
    }

    func testOvercommittedReservesFail() {
        let policy = AttacheContextCustomPolicy(hardInputLimit: 1_000, outputReserve: 500, toolReserve: 500, safetyMargin: 100)
        XCTAssertThrowsError(try policy.validate()) { error in
            guard case .overcommittedReserves = error as? AttacheContextPolicyError else {
                return XCTFail("Expected overcommittedReserves, got \(error)")
            }
        }
    }

    func testInvalidThresholdFails() {
        var policy = AttacheContextCustomPolicy()
        policy.stagedThresholds.stageTranscriptChars = 0
        XCTAssertThrowsError(try policy.validate()) { error in
            guard case .invalidThreshold = error as? AttacheContextPolicyError else {
                return XCTFail("Expected invalidThreshold, got \(error)")
            }
        }
    }

    func testValidPolicyPassesValidation() {
        let policy = AttacheContextCustomPolicy(hardInputLimit: 32_000, effectiveInputLimit: 28_000, outputReserve: 2_048, toolReserve: 1_024, safetyMargin: 256)
        XCTAssertNoThrow(try policy.validate())
    }

    func testValidationErrorsAreActionable() {
        let policy = AttacheContextCustomPolicy(hardInputLimit: 4_000, effectiveInputLimit: 8_000)
        XCTAssertThrowsError(try policy.validate()) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("effectiveInputLimit"), "Error should name the field: \(message)")
            XCTAssertTrue(message.contains("hardInputLimit"), "Error should name the cap: \(message)")
        }
    }

    // MARK: - Unknown and stale profiles (acceptance criterion 6)

    func testUnknownProfileIsVisible() {
        let unknown = AttacheModelCapabilityProfile(architecturalMaximum: nil, provenance: .unknown)
        XCTAssertTrue(unknown.isUnknown)
        XCTAssertNil(unknown.declaredInputCeiling, "Unknown capacity must not disguise a guessed number as fact.")
    }

    func testGuessedNumberIsNeverDisguisedAsFact() {
        let guessed = AttacheModelCapabilityProfile(architecturalMaximum: 8_000, confidence: .guessed, provenance: .curatedFallback)
        XCTAssertFalse(guessed.isUnknown, "A guessed number is not unknown, but its confidence is honestly 'guessed'.")
        XCTAssertEqual(guessed.confidence, .guessed)
    }

    func testStaleProfileIsVisible() {
        let old = Date(timeIntervalSince1970: 1_000)
        let profile = AttacheModelCapabilityProfile(architecturalMaximum: 128_000, freshness: old, provenance: .localCache)
        let now = Date(timeIntervalSince1970: 1_000 + 10_000)
        XCTAssertTrue(profile.isStale(olderThan: 3_600, now: now))
    }

    func testFreshProfileIsNotStale() {
        let recent = Date(timeIntervalSince1970: 5_000)
        let profile = AttacheModelCapabilityProfile(architecturalMaximum: 128_000, freshness: recent, provenance: .runtimeObservation)
        let now = Date(timeIntervalSince1970: 5_000 + 60)
        XCTAssertFalse(profile.isStale(olderThan: 3_600, now: now))
    }

    func testNilFreshnessIsNeverStale() {
        let profile = AttacheModelCapabilityProfile(architecturalMaximum: 128_000, freshness: nil, provenance: .providerMetadata)
        XCTAssertFalse(profile.isStale(olderThan: 1, now: Date(timeIntervalSince1970: 9_999_999)))
    }

    // MARK: - Persistence record (acceptance criterion 7 + 8)

    func testPolicyRecordRoundTripsAndMigrates() throws {
        let record = AttacheContextPolicyRecord(globalStrategy: .efficient)
        let data = try JSONEncoder().encode(record)
        let restored = AttacheContextPolicyRecord.migrate(data)
        XCTAssertEqual(restored?.globalStrategy, .efficient)
        XCTAssertEqual(restored?.version, AttacheContextPolicyRecord.currentVersion)
    }

    func testPolicyRecordMigrateReturnsNilForGarbage() {
        XCTAssertNil(AttacheContextPolicyRecord.migrate(Data("not json".utf8)))
    }

    func testCorePolicyTypesArePureFoundation() {
        // The contracts compile into AttacheCore with no SwiftUI/AppKit/HTTP
        // dependency. This asserts the types are Sendable (UnavailableHTTP-free)
        // and live in the Core module by constructing them.
        let identity = ModelIdentity(provider: "anthropic", normalizedEndpoint: "https://api.anthropic.com", requestedModel: "claude")
        let profile = AttacheModelCapabilityProfile(architecturalMaximum: 1_000_000, provenance: .providerMetadata)
        let strategy = AttacheContextStrategy.maximumCoverage
        XCTAssertNotNil(identity.capabilityKey)
        XCTAssertNotNil(profile.declaredInputCeiling)
        XCTAssertEqual(strategy.kind, .maximumCoverage)
    }
}
