import XCTest
@testable import AttacheApp

/// The pure per-engine readiness decision behind the personality editor's
/// warning banner and the speak-time fallback disclosure. Every engine state
/// is driven directly; no AV, network, or dlopen probes.
final class PersonalityVoiceReadinessTests: XCTestCase {

    private let installed: Set<String> = [
        "com.apple.voice.compact.en-US.Samantha",
        "com.apple.voice.premium.en-GB.Serena"
    ]

    private func evaluate(
        _ ref: PersonalityVoiceRef,
        premiumReady: Bool = false,
        connected: Set<AttacheSpeechProvider> = [.system]
    ) -> PersonalityVoiceReadiness {
        PersonalityVoiceReadiness.evaluate(
            ref: ref,
            installedSystemVoiceIDs: installed,
            premiumVoiceReady: premiumReady,
            connectedCloudEngines: connected
        )
    }

    func testSystemVoiceStatesFollowInstalledAssets() {
        XCTAssertEqual(evaluate(.systemVoice("com.apple.voice.premium.en-GB.Serena")), .ready)
        XCTAssertEqual(evaluate(.systemVoice(nil)), .ready, "the default voice needs no asset")
        XCTAssertEqual(
            evaluate(.systemVoice("com.apple.voice.premium.en-GB.Jamie")),
            .systemVoiceAssetMissing(identifier: "com.apple.voice.premium.en-GB.Jamie"),
            "an undownloaded Apple premium asset must warn instead of silently substituting"
        )
    }

    func testAttachePremiumStatesFollowRuntimeReadiness() {
        let ref = PersonalityVoiceRef(provider: .attachePremium)
        XCTAssertEqual(evaluate(ref, premiumReady: true), .ready)
        XCTAssertEqual(evaluate(ref, premiumReady: false), .attachePremiumNotInstalled)
    }

    func testCloudEngineStatesFollowConfiguredKeys() {
        for provider in [AttacheSpeechProvider.elevenLabs, .xai, .openai] {
            let ref = PersonalityVoiceRef(provider: provider)
            XCTAssertEqual(
                evaluate(ref, connected: [.system, provider]),
                .ready,
                "\(provider) with a key is ready"
            )
            XCTAssertEqual(
                evaluate(ref, connected: [.system]),
                .cloudKeyMissing(provider: provider),
                "\(provider) without a key is not configured"
            )
        }
    }

    /// Banner truth per engine: no warning when ready; the premium warning
    /// points at Settings > Voice and never Integrations; the Apple-asset
    /// warning points at System Settings; only cloud engines mention a key
    /// in Integrations.
    func testWarningTextMatchesEngineReality() {
        XCTAssertNil(PersonalityVoiceReadiness.ready.warningText)

        let premium = PersonalityVoiceReadiness.attachePremiumNotInstalled.warningText
        XCTAssertTrue(premium?.contains("Attaché Premium voice is not installed yet") == true)
        XCTAssertTrue(premium?.contains("Settings > Voice") == true)
        XCTAssertFalse(premium?.contains("Integrations") == true)
        XCTAssertFalse(premium?.contains("key") == true)

        let apple = PersonalityVoiceReadiness
            .systemVoiceAssetMissing(identifier: "com.apple.voice.premium.en-GB.Jamie")
            .warningText
        XCTAssertTrue(apple?.contains("not downloaded on this Mac") == true)
        XCTAssertTrue(apple?.contains("System Settings > Accessibility > Spoken Content") == true)
        XCTAssertFalse(apple?.contains("Integrations") == true)

        let cloud = PersonalityVoiceReadiness.cloudKeyMissing(provider: .elevenLabs).warningText
        XCTAssertTrue(cloud?.contains("ElevenLabs is not configured") == true)
        XCTAssertTrue(cloud?.contains("Integrations") == true)
    }

    /// The speak-time disclosure names the substitute voice and the reason,
    /// and stays silent when the chosen voice actually speaks.
    func testFallbackDisclosureDerivation() {
        XCTAssertNil(PersonalityVoiceReadiness.ready.fallbackDisclosure(fallbackVoiceName: "Samantha"))

        let premium = PersonalityVoiceReadiness.attachePremiumNotInstalled
            .fallbackDisclosure(fallbackVoiceName: "Samantha")
        XCTAssertEqual(
            premium,
            "Using fallback voice: Samantha. Attaché Premium voice is not installed yet."
        )

        let apple = PersonalityVoiceReadiness
            .systemVoiceAssetMissing(identifier: "com.apple.voice.premium.en-GB.Jamie")
            .fallbackDisclosure(fallbackVoiceName: "the default system voice")
        XCTAssertEqual(
            apple,
            "Using fallback voice: the default system voice. The chosen Apple voice is not downloaded on this Mac."
        )

        let cloud = PersonalityVoiceReadiness.cloudKeyMissing(provider: .xai)
            .fallbackDisclosure(fallbackVoiceName: "Samantha")
        XCTAssertTrue(cloud?.contains("Using fallback voice: Samantha.") == true)
        XCTAssertTrue(cloud?.contains("has no API key configured") == true)
    }
}
