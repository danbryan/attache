import Foundation

enum AttacheDocumentationLinks {
    enum ModelIntegrationGuide: String, CaseIterable {
        case ollama
        case xai = "xai--grok"
        case groq
        case openAICompatible = "openai-compatible"
        case codexCLI = "codex-cli"
        case claudeCode = "claude-code"
        case elevenLabs = "elevenlabs"
        case openAIVoice = "openai-voice"
        case onDeviceVoice = "on-device-voice"
    }

    private static let repositoryDocsBase =
        "https://github.com/danbryan/attache/blob/main"

    static func modelIntegration(_ guide: ModelIntegrationGuide) -> URL {
        URL(string: "\(repositoryDocsBase)/docs/model-integrations.md#\(guide.rawValue)")!
    }

    static let characterArtwork =
        URL(string: "\(repositoryDocsBase)/design/attache-animation-spec.md")!

    static let customSprite =
        URL(string: "\(repositoryDocsBase)/design/attache-animation-spec.md#bring-your-own-sprite")!
}
