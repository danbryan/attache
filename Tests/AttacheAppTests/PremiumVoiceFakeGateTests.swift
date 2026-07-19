import XCTest
import AttacheCore
@testable import AttacheApp

/// Proves the ATTACHE_FAKE_PREMIUM_VOICE affordance: the pure gate activates
/// only when BOTH flags are set (the same non-bypass contract as the two-way
/// expiry override), the fake path writes a parseable non-silent WAV with no
/// runtime or weights present, `isReady()` reports ready under the fake, and the
/// real synthesis path is untouched when the fake is inactive.
final class PremiumVoiceFakeGateTests: XCTestCase {

    // MARK: Pure gate matrix (mirrors testExpiryWindowOverrideRequiresUITestFlag)

    func testFakeGateRequiresBothFlags() {
        XCTAssertFalse(PremiumVoiceFakeGate.isActive(environment: [:]))
        XCTAssertFalse(PremiumVoiceFakeGate.isActive(environment: [
            "ATTACHE_FAKE_PREMIUM_VOICE": "1"
        ]))
        XCTAssertFalse(PremiumVoiceFakeGate.isActive(environment: [
            "ATTACHE_UI_TEST": "1"
        ]))
        XCTAssertTrue(PremiumVoiceFakeGate.isActive(environment: [
            "ATTACHE_UI_TEST": "1",
            "ATTACHE_FAKE_PREMIUM_VOICE": "1"
        ]))
    }

    func testFakeGateRejectsNearMissValues() {
        // A truthy-but-wrong value is not the exact string the harness sets.
        XCTAssertFalse(PremiumVoiceFakeGate.isActive(environment: [
            "ATTACHE_UI_TEST": "true",
            "ATTACHE_FAKE_PREMIUM_VOICE": "1"
        ]))
        XCTAssertFalse(PremiumVoiceFakeGate.isActive(environment: [
            "ATTACHE_UI_TEST": "1",
            "ATTACHE_FAKE_PREMIUM_VOICE": "yes"
        ]))
    }

    // MARK: Fake synthesis path

    func testFakePathWritesNonSilentWavWithoutRuntimeOrWeights() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-premium-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }

        try AttachePremiumVoiceSynthesizer.synthesize(
            text: "anything",
            configuration: .systemDefault,
            outputURL: out,
            environment: [
                "ATTACHE_UI_TEST": "1",
                "ATTACHE_FAKE_PREMIUM_VOICE": "1"
            ]
        )

        let data = try Data(contentsOf: out)
        let parsed = try PremiumVoiceWav.parse(data)
        XCTAssertEqual(parsed.format.sampleRate, AttachePremiumVoiceSynthesizer.sampleRate)
        XCTAssertGreaterThan(parsed.durationSeconds, 1)
        XCTAssertGreaterThan(Self.rms(ofFloatWav: data, frameCount: parsed.frameCount), 0.001,
                             "fake tone must carry nonzero energy")
    }

    func testFakeToneIsDeterministic() {
        XCTAssertEqual(
            AttachePremiumVoiceSynthesizer.fakeToneSamples(),
            AttachePremiumVoiceSynthesizer.fakeToneSamples()
        )
    }

    func testIsReadyTrueUnderFakeGate() {
        XCTAssertTrue(AttachePremiumVoiceAvailability.isReady(environment: [
            "ATTACHE_UI_TEST": "1",
            "ATTACHE_FAKE_PREMIUM_VOICE": "1"
        ]))
    }

    // MARK: Real path untouched when the fake is inactive

    func testRealPathUntouchedWhenFakeInactive() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-fake-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }
        // Point weights resolution at an empty temp dir so the real path fails
        // closed even on a machine that has real weights installed.
        let emptyWeights = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-weights-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyWeights, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyWeights) }

        // With the fake inactive (only one of the two flags set) and weights
        // resolved against an empty dir, synthesize must reach the real path and
        // fail closed rather than silently writing a tone.
        XCTAssertThrowsError(try AttachePremiumVoiceSynthesizer.synthesize(
            text: "anything",
            configuration: .systemDefault,
            outputURL: out,
            environment: [
                "ATTACHE_FAKE_PREMIUM_VOICE": "1",
                AttachePremiumVoiceSynthesizer.weightsInstallRootEnvOverride: emptyWeights.path
            ]
        )) { error in
            XCTAssertEqual(error as? PremiumVoiceRuntimeError, .weightsUnavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path),
                       "the real path must not have written any audio file")
    }

    private static func rms(ofFloatWav data: Data, frameCount: Int) -> Float {
        let offset = 44
        guard frameCount > 0, data.count >= offset + frameCount * 4 else { return 0 }
        var sumSquares: Double = 0
        data.withUnsafeBytes { raw in
            let floats = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: Float.self)
            for i in 0..<frameCount { sumSquares += Double(floats[i]) * Double(floats[i]) }
        }
        return Float((sumSquares / Double(frameCount)).squareRoot())
    }
}
