import XCTest
import AttacheCore
@testable import AttacheApp

/// The `.attachePremium` provider is on-device (no egress) and, when its runtime
/// or weights are missing, falls back to the system voice through the SAME
/// visible-status path the cloud engines use.
final class AttachePremiumVoiceProviderTests: XCTestCase {

    override func tearDown() {
        AttachePremiumVoiceAvailability.probeOverride = nil
        super.tearDown()
    }

    private func premiumConfiguration() -> AttacheSpeechConfiguration {
        var config = AttacheSpeechConfiguration.systemDefault
        config.provider = .attachePremium
        return config
    }

    func testProviderIsOnDeviceAndNeedsNoConsent() {
        XCTAssertFalse(AttacheSpeechProvider.attachePremium.sendsToCloud, "premium voice must stay on this Mac")
        let config = premiumConfiguration()
        XCTAssertTrue(config.hasRemoteEgressConsent, "on-device engine needs no remote egress consent")
    }

    func testTitlesDoNotLeakUpstreamNames() {
        // Decisions of Record: pocket-tts / Kyutai / OpenVox must never surface.
        let strings = [
            AttacheSpeechProvider.attachePremium.title,
            AttacheSpeechProvider.attachePremium.menuTitle
        ]
        for s in strings {
            let lowered = s.lowercased()
            XCTAssertFalse(lowered.contains("pocket"))
            XCTAssertFalse(lowered.contains("kyutai"))
            XCTAssertFalse(lowered.contains("openvox"))
            XCTAssertTrue(s.contains("Attaché Premium"))
        }
    }

    func testUnavailableSurfacesReasonAndFallsBackToSystem() {
        AttachePremiumVoiceAvailability.probeOverride = { false }
        let config = premiumConfiguration()

        let reason = config.playbackUnavailableReason
        XCTAssertNotNil(reason, "an unavailable premium voice must surface a visible reason")

        let resolved = config.resolvedForPlayback(systemVoiceIdentifier: "com.apple.voice.test")
        XCTAssertEqual(resolved.provider, .system, "must fall back to the on-device system voice")
        XCTAssertEqual(resolved.systemVoiceIdentifier, "com.apple.voice.test")
    }

    func testAvailableHasNoUnavailableReasonAndDoesNotFallBack() {
        AttachePremiumVoiceAvailability.probeOverride = { true }
        let config = premiumConfiguration()
        XCTAssertNil(config.playbackUnavailableReason)
        let resolved = config.resolvedForPlayback(systemVoiceIdentifier: "com.apple.voice.test")
        XCTAssertEqual(resolved.provider, .attachePremium, "available premium voice must not fall back")
    }

    func testSynthesizeThrowsTypedErrorWhenWeightsMissing() async throws {
        // Point weights resolution at an empty temp dir so the missing-weights
        // path is exercised deterministically, whether or not this machine has
        // real weights installed. The typed error must still surface through the
        // shared remote-voice dispatch, never a silent success.
        AttachePremiumVoiceAvailability.probeOverride = { false }
        let emptyWeights = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-weights-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyWeights, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyWeights) }
        let config = premiumConfiguration()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("premium-\(UUID().uuidString).wav")
        do {
            try await AttacheRemoteVoiceService.synthesize(
                text: "hi",
                configuration: config,
                outputURL: out,
                environment: [AttachePremiumVoiceSynthesizer.weightsInstallRootEnvOverride: emptyWeights.path]
            )
            XCTFail("expected a typed premium-voice error")
        } catch let error as PremiumVoiceRuntimeError {
            XCTAssertEqual(error, .weightsUnavailable, "got \(error)")
        } catch {
            XCTFail("expected PremiumVoiceRuntimeError, got \(error)")
        }
    }
}
