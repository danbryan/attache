import AttacheCore
import XCTest
import Foundation

final class AttacheTokenUsageCalibrationTests: XCTestCase {

    // Criterion 1: supported usage naming variants parse without breaking
    // providers that omit usage.
    func testParsesPromptAndCompletionTokens() {
        let usage = AttacheProviderUsageParser.parse(usageJSON: [
            "prompt_tokens": 100, "completion_tokens": 50, "total_tokens": 150
        ])
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 50)
        XCTAssertEqual(usage.totalTokens, 150)
        XCTAssertTrue(usage.isPresent)
    }

    func testParsesInputAndOutputTokensVariant() {
        let usage = AttacheProviderUsageParser.parse(usageJSON: [
            "input_tokens": 200, "output_tokens": 80
        ])
        XCTAssertEqual(usage.inputTokens, 200)
        XCTAssertEqual(usage.outputTokens, 80)
    }

    func testParsesCachedTokensNested() {
        let usage = AttacheProviderUsageParser.parse(usageJSON: [
            "prompt_tokens": 300,
            "prompt_tokens_details": ["cached_tokens": 120]
        ])
        XCTAssertEqual(usage.cachedTokens, 120)
    }

    func testParsesCachedTokensFlat() {
        let usage = AttacheProviderUsageParser.parse(usageJSON: [
            "cached_tokens": 90
        ])
        XCTAssertEqual(usage.cachedTokens, 90)
    }

    func testOmitsUsageGracefully() {
        let usage = AttacheProviderUsageParser.parse(usageJSON: nil)
        XCTAssertNil(usage.inputTokens)
        XCTAssertNil(usage.outputTokens)
        XCTAssertFalse(usage.isPresent)
    }

    func testParsesFromJSONStringWithNestedUsage() {
        let json = #"{"usage":{"prompt_tokens":42,"completion_tokens":7}}"#
        let usage = AttacheProviderUsageParser.parse(jsonString: json)
        XCTAssertEqual(usage.inputTokens, 42)
        XCTAssertEqual(usage.outputTokens, 7)
    }

    func testDoesNotScrapeProse() {
        // A response with no structured usage but lots of prose must not
        // produce a fabricated usage reading.
        let json = #"{"content":"You used about 500 tokens of context and 200 of output."}"#
        let usage = AttacheProviderUsageParser.parse(jsonString: json)
        XCTAssertFalse(usage.isPresent, "prose is never scraped for usage")
    }

    // Criterion 2: serialized calibration and diagnostics contain no content
    // or sensitive path/key material.
    func testDiagnosticsAreContentFree() throws {
        var lineage = AttacheCalibrationLineage(modelIdentityKey: "ollama|qwen3")
        for i in 0..<10 {
            lineage.record(1.2 + Double(i) * 0.01)
        }
        let diag = lineage.diagnostics()
        // Diagnostics carry only aggregate numbers and identity keys.
        let forbidden = ["password", "api_key", "secret", "/Users/", "transcript", "message"]
        let dump = "\(diag.modelIdentityKey)|\(diag.lineageID)|\(diag.sampleCount)|\(diag.aggregateEstimateError)|\(diag.correctionFactor)"
        for marker in forbidden {
            XCTAssertFalse(dump.contains(marker), "diagnostics must not contain \(marker)")
        }
    }

    func testStoreContainsNoContent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-calibration-\(UUID().uuidString).sqlite")
        let store = AttacheCalibrationStore(databaseURL: tmp)
        var lineage = AttacheCalibrationLineage(modelIdentityKey: "ollama|qwen3")
        for _ in 0..<6 { lineage.record(1.1) }
        XCTAssertTrue(store.save(lineage))
        let keys = store.dumpAllKeys()
        // Only identity keys and lineage IDs, no content.
        for key in keys {
            XCTAssertFalse(key.contains("password"))
            XCTAssertFalse(key.contains("api_key"))
            XCTAssertFalse(key.contains("transcript"))
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    func testStorePreservesPreActionableAggregateInsteadOfReplacingItWithOne() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-calibration-\(UUID().uuidString).sqlite")
        let store = AttacheCalibrationStore(databaseURL: tmp)
        var lineage = AttacheCalibrationLineage(modelIdentityKey: "ollama|early")
        for _ in 0..<4 { lineage.record(1.3) }
        XCTAssertTrue(store.save(lineage))
        let diagnostics = try XCTUnwrap(store.diagnostics(for: "ollama|early"))
        XCTAssertEqual(diagnostics.sampleCount, 4)
        XCTAssertFalse(diagnostics.isActionable)
        XCTAssertEqual(diagnostics.correctionFactor, 1.3, accuracy: 0.001)
        try? FileManager.default.removeItem(at: tmp)
    }

    // Criterion 3: data is isolated by endpoint and model fingerprint.
    func testIsolatedByIdentity() {
        var lineageA = AttacheCalibrationLineage(modelIdentityKey: "ollama|qwen3")
        var lineageB = AttacheCalibrationLineage(modelIdentityKey: "openai|gpt-4")
        for _ in 0..<6 { lineageA.record(1.3) }
        for _ in 0..<6 { lineageB.record(0.9) }
        let correctionA = lineageA.computeCorrection()
        let correctionB = lineageB.computeCorrection()
        XCTAssertNotEqual(correctionA.factor, correctionB.factor, "isolated by identity")
        XCTAssertGreaterThan(correctionA.factor, 1.0, "lineage A underestimates")
        XCTAssertLessThan(correctionB.factor, 1.0, "lineage B overestimates")
    }

    // Criterion 4: too few samples do not alter estimation.
    func testTooFewSamplesDoNotAlter() {
        var lineage = AttacheCalibrationLineage(modelIdentityKey: "k", minSamples: 5)
        lineage.record(2.0) // only 1 sample
        let correction = lineage.computeCorrection()
        XCTAssertFalse(correction.isActionable, "too few samples is not actionable")
        XCTAssertEqual(correction.factor, 1.0, "no adjustment with too few samples")
        let estimate = 1000
        XCTAssertEqual(AttacheTokenUsageCalibrator.applyCorrection(estimate: estimate, correction: correction), estimate,
                       "estimate unchanged when correction is not actionable")
    }

    // Criterion 5: outliers cannot produce zero, negative, or implausibly
    // optimistic corrections.
    func testOutliersClamped() {
        var lineage = AttacheCalibrationLineage(modelIdentityKey: "k", minSamples: 3)
        // Record extreme outliers.
        lineage.record(0.01)  // implausibly optimistic
        lineage.record(0.001) // near zero
        lineage.record(0.01)
        let correction = lineage.computeCorrection()
        XCTAssertGreaterThanOrEqual(correction.factor, 0.5, "cannot go below 0.5")
        XCTAssertLessThanOrEqual(correction.factor, 1.5, "cannot go above 1.5")
        XCTAssertGreaterThan(correction.factor, 0, "never zero or negative")
    }

    func testExtremeHighOutlierClamped() {
        var lineage = AttacheCalibrationLineage(modelIdentityKey: "k", minSamples: 3)
        lineage.record(100.0) // extreme high
        lineage.record(100.0)
        lineage.record(100.0)
        let correction = lineage.computeCorrection()
        XCTAssertLessThanOrEqual(correction.factor, 1.5, "extreme high clamped to 1.5")
    }

    // Criterion 6: calibration cannot raise effective capacity or overwrite
    // Custom policy.
    func testCalibrationDoesNotRaiseHardLimit() {
        let correction = AttacheCalibrationCorrection(factor: 1.5, sampleCount: 10, aggregateError: 0.5, isActionable: true)
        let hardLimit = 8_000
        XCTAssertEqual(AttacheTokenUsageCalibrator.applyCorrectionToHardLimit(hardLimit: hardLimit, correction: correction), hardLimit,
                       "hard limit is never raised by calibration")
    }

    func testCalibrationMakesEstimateMoreConservativeNotLess() {
        // A factor >1 means the estimator underestimated. Applying it should
        // make the estimate higher (more conservative), never lower.
        let correction = AttacheCalibrationCorrection(factor: 1.3, sampleCount: 10, aggregateError: 0.3, isActionable: true)
        let adjusted = AttacheTokenUsageCalibrator.applyCorrection(estimate: 1_000, correction: correction)
        XCTAssertGreaterThanOrEqual(adjusted, 1_000, "calibration never makes the estimate less safe")
    }

    func testNonActionableCorrectionLeavesEstimateUnchanged() {
        let estimate = 500
        let adjusted = AttacheTokenUsageCalibrator.applyCorrection(estimate: estimate, correction: .unactionable)
        XCTAssertEqual(adjusted, estimate)
    }

    // Criterion 7: alias/fingerprint changes retire the prior lineage.
    func testIdentityChangeRetiresLineage() {
        let oldKey = "ollama|qwen3"
        let newKey = "ollama|qwen3.5"
        XCTAssertTrue(AttacheTokenUsageCalibrator.shouldRetireLineage(oldKey: oldKey, newKey: newKey),
                      "identity change should retire lineage")
        let oldLineage = AttacheCalibrationLineage(modelIdentityKey: oldKey)
        let newLineage = oldLineage.retire(newIdentityKey: newKey)
        XCTAssertEqual(newLineage.modelIdentityKey, newKey)
        XCTAssertNotEqual(newLineage.lineageID, oldLineage.lineageID, "new lineage ID on retire")
        XCTAssertEqual(newLineage.sampleCount, 0, "retired lineage starts fresh")
    }

    func testSameIdentityDoesNotRetire() {
        let key = "ollama|qwen3"
        XCTAssertFalse(AttacheTokenUsageCalibrator.shouldRetireLineage(oldKey: key, newKey: key))
    }

    // Criterion 8: context-limit failures become warnings requiring stronger
    // evidence or user action.
    func testContextLimitFailureBecomesWarning() {
        let errorBody = #"{"error":{"message":"This model's maximum context length is 8192 tokens."}}"#
        let warning = AttacheProviderUsageParser.detectContextLimitFailure(errorBody: errorBody, modelIdentityKey: "k")
        XCTAssertNotNil(warning, "context-limit error detected")
        XCTAssertEqual(warning?.observedLimit, 8192)
        XCTAssertTrue(warning?.requiresUserAction ?? false, "requires user action, not auto-applied")
    }

    func testNonContextLimitErrorNotFlagged() {
        let errorBody = #"{"error":{"message":"Rate limit exceeded."}}"#
        let warning = AttacheProviderUsageParser.detectContextLimitFailure(errorBody: errorBody, modelIdentityKey: "k")
        XCTAssertNil(warning, "non-context error is not a capability warning")
    }

    func testWarningIsNeverAutoAppliedAsLimit() {
        let warning = AttacheCapabilityWarning(modelIdentityKey: "k", observedLimit: 4096)
        let recorded = AttacheTokenUsageCalibrator.recordContextLimitWarning(warning)
        // The recorded warning is the same warning: it does not become a
        // limit fact. It still requires user action.
        XCTAssertEqual(recorded, warning)
        XCTAssertTrue(recorded.requiresUserAction)
    }

    // Store round-trips a lineage.
    func testStoreRoundTripsLineage() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-calibration-\(UUID().uuidString).sqlite")
        let store = AttacheCalibrationStore(databaseURL: tmp)
        var lineage = AttacheCalibrationLineage(modelIdentityKey: "ollama|qwen3")
        for _ in 0..<6 { lineage.record(1.2) }
        XCTAssertTrue(store.save(lineage))
        let diag = store.diagnostics(for: "ollama|qwen3")
        XCTAssertNotNil(diag)
        XCTAssertEqual(diag?.sampleCount, 6)
        XCTAssertTrue(diag?.isActionable ?? false)
        XCTAssertEqual(
            try XCTUnwrap(diag?.lastUpdate).timeIntervalSince1970,
            try XCTUnwrap(lineage.lastUpdate).timeIntervalSince1970,
            accuracy: 0.001
        )
        try? FileManager.default.removeItem(at: tmp)
    }

    func testPersistedAggregateAccumulatesAcrossStoreReopenWithoutRawSamples() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-calibration-\(UUID().uuidString).sqlite")
        let identity = "ollama@http://127.0.0.1|qwen3"
        let estimatorVersion = "fallback-v2"
        let key = AttacheCalibrationStore.storageKey(
            modelIdentityKey: identity,
            estimatorVersion: estimatorVersion
        )

        for index in 0..<3 {
            let store = AttacheCalibrationStore(databaseURL: tmp)
            XCTAssertTrue(store.record(AttacheProviderUsageSample(
                modelIdentityKey: identity,
                estimatorVersion: estimatorVersion,
                strategyKind: "automatic",
                role: "conversation",
                estimatedInputTokens: 1_000,
                actualInputTokens: 1_250,
                actualOutputTokens: 50,
                timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
                receiptID: "receipt-\(index)"
            )))
        }
        let reopened = AttacheCalibrationStore(databaseURL: tmp)
        for index in 3..<5 {
            XCTAssertTrue(reopened.record(AttacheProviderUsageSample(
                modelIdentityKey: identity,
                estimatorVersion: estimatorVersion,
                strategyKind: "automatic",
                role: "conversation",
                estimatedInputTokens: 1_000,
                actualInputTokens: 1_250,
                actualOutputTokens: 50,
                timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
                receiptID: "receipt-\(index)"
            )))
        }
        let diagnostics = try XCTUnwrap(reopened.diagnostics(for: key))
        XCTAssertEqual(diagnostics.sampleCount, 5)
        XCTAssertTrue(diagnostics.isActionable)
        XCTAssertEqual(diagnostics.correctionFactor, 1.25, accuracy: 0.011)
        XCTAssertEqual(
            try XCTUnwrap(diagnostics.lastUpdate).timeIntervalSince1970,
            1_800_000_004,
            accuracy: 0.001
        )

        let keys = reopened.dumpAllKeys().joined(separator: "|")
        XCTAssertFalse(keys.contains("receipt-"))
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.removeItem(atPath: tmp.path + "-wal")
        try? FileManager.default.removeItem(atPath: tmp.path + "-shm")
    }

    func testEstimatorVersionsHaveIndependentPersistedLineages() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-calibration-\(UUID().uuidString).sqlite")
        let store = AttacheCalibrationStore(databaseURL: tmp)
        for version in ["v1", "v2"] {
            let actual = version == "v1" ? 1_400 : 1_100
            for index in 0..<5 {
                XCTAssertTrue(store.record(AttacheProviderUsageSample(
                    modelIdentityKey: "same-model",
                    estimatorVersion: version,
                    strategyKind: "automatic",
                    role: "conversation",
                    estimatedInputTokens: 1_000,
                    actualInputTokens: actual,
                    actualOutputTokens: 10,
                    timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
                    receiptID: "\(version)-\(index)"
                )))
            }
        }
        let v1 = try XCTUnwrap(store.diagnostics(for: AttacheCalibrationStore.storageKey(
            modelIdentityKey: "same-model", estimatorVersion: "v1"
        )))
        let v2 = try XCTUnwrap(store.diagnostics(for: AttacheCalibrationStore.storageKey(
            modelIdentityKey: "same-model", estimatorVersion: "v2"
        )))
        XCTAssertEqual(v1.correctionFactor, 1.4, accuracy: 0.011)
        XCTAssertEqual(v2.correctionFactor, 1.1, accuracy: 0.011)
        try? FileManager.default.removeItem(at: tmp)
    }

    func testInvalidRatiosAreRejectedInsteadOfPoisoningAggregate() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-calibration-\(UUID().uuidString).sqlite")
        let store = AttacheCalibrationStore(databaseURL: tmp)
        XCTAssertFalse(store.record(AttacheProviderUsageSample(
            modelIdentityKey: "model",
            estimatorVersion: "v2",
            strategyKind: "automatic",
            role: "conversation",
            estimatedInputTokens: 0,
            actualInputTokens: 100,
            actualOutputTokens: 0,
            receiptID: "invalid"
        )))
        XCTAssertNil(store.diagnostics(for: AttacheCalibrationStore.storageKey(
            modelIdentityKey: "model", estimatorVersion: "v2"
        )))
        try? FileManager.default.removeItem(at: tmp)
    }

    // Sample recording bounds the stored count.
    func testLineageBoundsSampleCount() {
        var lineage = AttacheCalibrationLineage(modelIdentityKey: "k", minSamples: 3, maxSamples: 10)
        for _ in 0..<20 { lineage.record(1.1) }
        XCTAssertLessThanOrEqual(lineage.sampleCount, 10, "bounded sample count")
    }

    // Estimate ratio computes correctly.
    func testEstimateRatio() {
        let sample = AttacheProviderUsageSample(
            modelIdentityKey: "k", estimatorVersion: "v1", strategyKind: "automatic",
            role: "conversation", estimatedInputTokens: 800, actualInputTokens: 1000,
            actualOutputTokens: 200, receiptID: "r1"
        )
        XCTAssertEqual(sample.estimateRatio, 1.25, accuracy: 0.001)
    }
}
