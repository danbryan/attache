import XCTest
@testable import AttacheApp

final class SpeechConfigurationTests: XCTestCase {
    func testOpenAIVoiceKeyReuseRequiresExactOfficialAuthority() {
        XCTAssertTrue(AppModel.isOfficialOpenAIEndpoint("HTTPS://API.OPENAI.COM:443/v1/"))
        XCTAssertFalse(AppModel.isOfficialOpenAIEndpoint("https://api.openai.com.evil.example/v1"))
        XCTAssertFalse(AppModel.isOfficialOpenAIEndpoint("https://evil.example/v1?next=api.openai.com"))
        XCTAssertFalse(AppModel.isOfficialOpenAIEndpoint("http://api.openai.com/v1"))
        XCTAssertFalse(AppModel.isOfficialOpenAIEndpoint("https://user@api.openai.com/v1"))
        XCTAssertFalse(AppModel.isOfficialOpenAIEndpoint("https://api.openai.com/proxy/v1"))
    }

    func testRemoteVoiceRedirectPolicyRefusesASecondDestination() {
        var redirected = URLRequest(url: URL(string: "https://unclassified.example/v1/audio/speech")!)
        redirected.httpMethod = "POST"
        redirected.httpBody = Data("SENSITIVE_SPOKEN_TEXT".utf8)

        XCTAssertNil(AttacheNoRedirectDelegate.redirectedRequest(redirected))
    }

    func testMissingElevenLabsKeyFallsBackToSystemVoice() {
        var configuration = AttacheSpeechConfiguration.systemDefault
        configuration.provider = .elevenLabs
        configuration.remoteEgressConsentScope = VoiceConsentScope(provider: .elevenLabs).storageKey
        configuration.elevenLabsVoiceID = "voice-id"

        let resolved = configuration.resolvedForPlayback(systemVoiceIdentifier: "system-voice")

        XCTAssertEqual(configuration.playbackUnavailableReason, "ElevenLabs API key is not configured.")
        XCTAssertEqual(resolved.provider, .system)
        XCTAssertEqual(resolved.systemVoiceIdentifier, "system-voice")
    }

    func testMissingCloudVoiceFallsBackEvenWhenKeyExists() {
        var configuration = AttacheSpeechConfiguration.systemDefault
        configuration.provider = .xai
        configuration.remoteEgressConsentScope = VoiceConsentScope(
            provider: .xai,
            xaiBaseURL: configuration.xaiBaseURL
        ).storageKey
        configuration.xaiAPIKey = "configured"
        configuration.xaiVoiceID = "  "

        let resolved = configuration.resolvedForPlayback(systemVoiceIdentifier: nil)

        XCTAssertEqual(configuration.playbackUnavailableReason, "xAI voice is not selected.")
        XCTAssertEqual(resolved.provider, .system)
    }

    func testMissingOpenAIKeyFallsBackToSystemVoice() {
        var configuration = AttacheSpeechConfiguration.systemDefault
        configuration.provider = .openai
        configuration.remoteEgressConsentScope = VoiceConsentScope(provider: .openai).storageKey
        configuration.openaiVoiceID = "marin"

        let resolved = configuration.resolvedForPlayback(systemVoiceIdentifier: nil)

        XCTAssertEqual(configuration.playbackUnavailableReason, "OpenAI API key is not configured.")
        XCTAssertEqual(resolved.provider, .system)
    }

    func testConfiguredCloudVoiceRemainsSelected() {
        var configuration = AttacheSpeechConfiguration.systemDefault
        configuration.provider = .elevenLabs
        configuration.remoteEgressConsentScope = VoiceConsentScope(provider: .elevenLabs).storageKey
        configuration.elevenLabsAPIKey = "configured"
        configuration.elevenLabsVoiceID = "voice-id"

        let resolved = configuration.resolvedForPlayback(systemVoiceIdentifier: "system-voice")

        XCTAssertNil(configuration.playbackUnavailableReason)
        XCTAssertEqual(resolved, configuration)
    }

    func testSystemVoiceNeverFallsBack() {
        let configuration = AttacheSpeechConfiguration.systemDefault

        XCTAssertNil(configuration.playbackUnavailableReason)
        XCTAssertEqual(configuration.resolvedForPlayback(systemVoiceIdentifier: "system-voice"), configuration)
    }

    func testConfiguredCloudVoiceWithoutEndpointScopedConsentFallsBack() {
        var configuration = AttacheSpeechConfiguration.systemDefault
        configuration.provider = .elevenLabs
        configuration.elevenLabsAPIKey = "configured"
        configuration.elevenLabsVoiceID = "voice-id"

        XCTAssertEqual(
            configuration.playbackUnavailableReason,
            "ElevenLabs cloud voice approval is required."
        )
        XCTAssertEqual(
            configuration.resolvedForPlayback(systemVoiceIdentifier: nil).provider,
            .system
        )
    }

    func testXAIConsentIsBoundToExactNormalizedEndpoint() {
        var configuration = AttacheSpeechConfiguration.systemDefault
        configuration.provider = .xai
        configuration.xaiAPIKey = "configured"
        configuration.xaiVoiceID = "ara"
        configuration.xaiBaseURL = "https://first.example/v1"
        configuration.remoteEgressConsentScope = VoiceConsentScope(
            provider: .xai,
            xaiBaseURL: "HTTPS://FIRST.EXAMPLE:443/v1/"
        ).storageKey

        XCTAssertTrue(configuration.hasRemoteEgressConsent)

        configuration.xaiBaseURL = "https://second.example/v1"
        XCTAssertFalse(configuration.hasRemoteEgressConsent)
        XCTAssertEqual(configuration.resolvedForPlayback(systemVoiceIdentifier: nil).provider, .system)
    }

    func testRemoteSynthesisFailsBeforeNetworkWithoutConsent() async {
        var configuration = AttacheSpeechConfiguration.systemDefault
        configuration.provider = .openai
        configuration.openaiAPIKey = "must-not-be-used"
        configuration.openaiVoiceID = "marin"
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-consent-test-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: output) }

        do {
            try await AttacheRemoteVoiceService.synthesize(
                text: "must not leave this process",
                configuration: configuration,
                outputURL: output
            )
            XCTFail("Expected endpoint-scoped consent refusal")
        } catch let error as VoiceProviderError {
            XCTAssertEqual(error.localizedDescription, "OpenAI cloud voice approval is required.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testXAIPlaintextRemoteEndpointIsRejectedBeforeNetwork() async {
        var configuration = AttacheSpeechConfiguration.systemDefault
        configuration.provider = .xai
        configuration.xaiAPIKey = "must-not-be-used"
        configuration.xaiVoiceID = "ara"
        configuration.xaiBaseURL = "http://voice-exfil.example/v1"
        configuration.remoteEgressConsentScope = VoiceConsentScope(
            provider: .xai,
            xaiBaseURL: configuration.xaiBaseURL
        ).storageKey
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-http-voice-test-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: output) }

        do {
            try await AttacheRemoteVoiceService.synthesize(
                text: "must not be sent in plaintext",
                configuration: configuration,
                outputURL: output
            )
            XCTFail("Expected insecure endpoint refusal")
        } catch let error as VoiceProviderError {
            XCTAssertEqual(error.localizedDescription, "xAI voice endpoints must use HTTPS or loopback.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
