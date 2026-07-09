import XCTest
@testable import AttacheApp

final class SpeechConfigurationTests: XCTestCase {
    func testMissingElevenLabsKeyFallsBackToSystemVoice() {
        var configuration = CompanionSpeechConfiguration.systemDefault
        configuration.provider = .elevenLabs
        configuration.elevenLabsVoiceID = "voice-id"

        let resolved = configuration.resolvedForPlayback(systemVoiceIdentifier: "system-voice")

        XCTAssertEqual(configuration.playbackUnavailableReason, "ElevenLabs API key is not configured.")
        XCTAssertEqual(resolved.provider, .system)
        XCTAssertEqual(resolved.systemVoiceIdentifier, "system-voice")
    }

    func testMissingCloudVoiceFallsBackEvenWhenKeyExists() {
        var configuration = CompanionSpeechConfiguration.systemDefault
        configuration.provider = .xai
        configuration.xaiAPIKey = "configured"
        configuration.xaiVoiceID = "  "

        let resolved = configuration.resolvedForPlayback(systemVoiceIdentifier: nil)

        XCTAssertEqual(configuration.playbackUnavailableReason, "xAI voice is not selected.")
        XCTAssertEqual(resolved.provider, .system)
    }

    func testMissingOpenAIKeyFallsBackToSystemVoice() {
        var configuration = CompanionSpeechConfiguration.systemDefault
        configuration.provider = .openai
        configuration.openaiVoiceID = "marin"

        let resolved = configuration.resolvedForPlayback(systemVoiceIdentifier: nil)

        XCTAssertEqual(configuration.playbackUnavailableReason, "OpenAI API key is not configured.")
        XCTAssertEqual(resolved.provider, .system)
    }

    func testConfiguredCloudVoiceRemainsSelected() {
        var configuration = CompanionSpeechConfiguration.systemDefault
        configuration.provider = .elevenLabs
        configuration.elevenLabsAPIKey = "configured"
        configuration.elevenLabsVoiceID = "voice-id"

        let resolved = configuration.resolvedForPlayback(systemVoiceIdentifier: "system-voice")

        XCTAssertNil(configuration.playbackUnavailableReason)
        XCTAssertEqual(resolved, configuration)
    }

    func testSystemVoiceNeverFallsBack() {
        let configuration = CompanionSpeechConfiguration.systemDefault

        XCTAssertNil(configuration.playbackUnavailableReason)
        XCTAssertEqual(configuration.resolvedForPlayback(systemVoiceIdentifier: "system-voice"), configuration)
    }
}
