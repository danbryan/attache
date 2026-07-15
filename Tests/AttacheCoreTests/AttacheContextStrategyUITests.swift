import AttacheCore
import XCTest

final class AttacheContextStrategyUITests: XCTestCase {

    // Criterion 1+2: Automatic is default, no numeric controls needed.
    func testAutomaticIsDefaultAndNeedsNoNumericControls() {
        let vm = ContextStrategyViewModel()
        XCTAssertEqual(vm.selectedKind, .automatic)
        XCTAssertFalse(AttacheContextStrategyDescription.requiresNumericControls(.automatic))
        XCTAssertTrue(AttacheContextStrategyDescription.requiresNumericControls(.custom))
    }

    // Criterion 2: concise explanations exist for each strategy.
    func testStrategyDescriptionsAreConciseAndNonEmpty() {
        for kind in AttacheContextStrategyKind.allCases {
            XCTAssertFalse(AttacheContextStrategyDescription.title(kind).isEmpty)
            XCTAssertFalse(AttacheContextStrategyDescription.explanation(kind).isEmpty)
        }
    }

    // Criterion 3: each personality can inherit the global strategy or choose its own.
    func testResolvedStrategyReflectsSelection() {
        var vm = ContextStrategyViewModel(globalDefault: .efficient)
        XCTAssertEqual(vm.resolvedStrategy?.kind, .efficient, "inherits global default")

        vm.select(.maximumCoverage)
        XCTAssertEqual(vm.resolvedStrategy?.kind, .maximumCoverage, "chooses its own")
    }

    // Criterion 4: the advanced view distinguishes detected, stale, unknown, and overridden.
    func testCapabilitySummaryDistinguishesDetectedStaleUnknownOverridden() {
        let detected = AttacheModelCapabilityProfile(
            architecturalMaximum: 128_000, freshness: Date(timeIntervalSince1970: 1_000),
            confidence: .authoritative, provenance: .providerMetadata
        )
        let now = Date(timeIntervalSince1970: 1_000_000)
        let summary = AttacheCapabilitySummary.from(detected: detected, override: nil, now: now)
        XCTAssertEqual(summary.effectiveCapacityLabel, "128000 tokens")
        XCTAssertTrue(summary.isStale)
        XCTAssertFalse(summary.isUnknown)
        XCTAssertFalse(summary.isOverridden)

        let withOverride = AttacheCapabilitySummary.from(detected: detected, override: AttacheContextCustomPolicy(), now: now)
        XCTAssertTrue(withOverride.isOverridden)
    }

    func testCapabilitySummaryShowsUnknown() {
        let unknown = AttacheModelCapabilityProfile(architecturalMaximum: nil, confidence: .unknown, provenance: .unknown)
        let summary = AttacheCapabilitySummary.from(detected: unknown)
        XCTAssertEqual(summary.effectiveCapacityLabel, "Unknown")
        XCTAssertTrue(summary.isUnknown)
        XCTAssertEqual(summary.reasoningSupportLabel, "Unknown")
    }

    // Criterion 5: unsupported reasoning levels are absent; unknown is not provider fact.
    func testReasoningLabelsDistinguishSupportedUnsupportedUnknown() {
        let supported = AttacheModelCapabilityProfile(architecturalMaximum: 32_000, supportsReasoning: true, reasoningLevels: ["low", "high"], confidence: .authoritative, provenance: .providerMetadata)
        XCTAssertEqual(AttacheCapabilitySummary.from(detected: supported).reasoningSupportLabel, "Levels: low, high")

        let unsupported = AttacheModelCapabilityProfile(architecturalMaximum: 32_000, supportsReasoning: false, confidence: .observed, provenance: .runtimeObservation)
        XCTAssertEqual(AttacheCapabilitySummary.from(detected: unsupported).reasoningSupportLabel, "Not supported")

        let unknownReasoning = AttacheModelCapabilityProfile(architecturalMaximum: 32_000, supportsReasoning: false, confidence: .unknown, provenance: .unknown)
        XCTAssertEqual(AttacheCapabilitySummary.from(detected: unknownReasoning).reasoningSupportLabel, "Unknown")
    }

    // Criterion 6: invalid Custom reserves cannot be saved and explain how to fix them.
    func testInvalidCustomCannotSaveAndExplains() {
        var vm = ContextStrategyViewModel()
        vm.select(.custom)
        vm.updateCustom(AttacheContextCustomPolicy(hardInputLimit: 4_000, effectiveInputLimit: 8_000))
        XCTAssertFalse(vm.canSave, "Invalid Custom cannot be saved.")
        XCTAssertNil(vm.resolvedStrategy, "An invalid strategy is not resolved.")
        XCTAssertNotNil(vm.validationError)
        XCTAssertTrue(vm.validationError?.errorDescription?.contains("effectiveInputLimit") ?? false,
                      "Error must explain how to fix it.")
    }

    func testValidCustomCanSave() {
        var vm = ContextStrategyViewModel()
        vm.select(.custom)
        vm.updateCustom(AttacheContextCustomPolicy(hardInputLimit: 32_000, effectiveInputLimit: 28_000, outputReserve: 2_048, toolReserve: 1_024, safetyMargin: 256))
        XCTAssertTrue(vm.canSave)
        XCTAssertNotNil(vm.resolvedStrategy)
        XCTAssertEqual(vm.resolvedStrategy?.kind, .custom)
    }

    // Criterion 7: Reset removes only the override and reveals current detected evidence.
    func testResetRemovesOverrideAndReturnsToGlobal() {
        var vm = ContextStrategyViewModel(globalDefault: .maximumCoverage)
        vm.select(.custom)
        vm.updateCustom(AttacheContextCustomPolicy(hardInputLimit: 16_000))
        XCTAssertEqual(vm.selectedKind, .custom)

        vm.reset()
        XCTAssertEqual(vm.selectedKind, .maximumCoverage, "Reset returns to the global default.")
        XCTAssertNil(vm.validationError)
    }

    // Criterion 10: import/export round-trips strategy (Personality Codable from INF-305).
    func testStrategyRoundTripsThroughCodable() throws {
        let strategy = AttacheContextStrategy(.custom, custom: AttacheContextCustomPolicy(
            hardInputLimit: 16_000, outputReserve: 1_024, toolReserve: 512, safetyMargin: 128
        ))
        let data = try JSONEncoder().encode(strategy)
        let restored = try JSONDecoder().decode(AttacheContextStrategy.self, from: data)
        XCTAssertEqual(restored, strategy)
        XCTAssertEqual(restored.custom?.hardInputLimit, 16_000)
    }

    // Fresh user: no numeric controls visible when Automatic.
    func testFreshUserSeesNoNumericControls() {
        let vm = ContextStrategyViewModel()
        XCTAssertEqual(vm.selectedKind, .automatic)
        XCTAssertFalse(AttacheContextStrategyDescription.requiresNumericControls(vm.selectedKind))
        XCTAssertTrue(vm.canSave)
        XCTAssertNotNil(vm.resolvedStrategy)
    }
}