import Foundation
import AttacheCore

enum AttacheSpeechProvider: String, CaseIterable, Identifiable, Codable {
    case system
    case elevenLabs
    case xai
    case openai

    var id: String { rawValue }

    /// On-device synthesis stays on the Mac; every other engine streams the recap
    /// text to a cloud voice API.
    var sendsToCloud: Bool { self != .system }

    var title: String {
        switch self {
        case .system: return "On-device"
        case .elevenLabs: return "ElevenLabs"
        case .xai: return "xAI"
        case .openai: return "OpenAI"
        }
    }

    var menuTitle: String {
        switch self {
        case .system: return "On-device Voices"
        case .elevenLabs: return "ElevenLabs Voices"
        case .xai: return "xAI Voices"
        case .openai: return "OpenAI Voices"
        }
    }
}

struct RemoteVoiceOption: Identifiable, Equatable {
    var id: String
    var name: String
    var provider: AttacheSpeechProvider
    var detail: String

    var title: String {
        detail.isEmpty ? name : "\(name) (\(detail))"
    }
}

struct AttacheSpeechConfiguration: Equatable {
    var provider: AttacheSpeechProvider
    var systemVoiceIdentifier: String?
    var elevenLabsAPIKey: String?
    var elevenLabsVoiceID: String
    var elevenLabsModelID: String
    var elevenLabsOutputFormat: String
    var xaiAPIKey: String?
    var xaiBaseURL: String
    var xaiVoiceID: String
    var xaiLanguage: String
    var openaiAPIKey: String?
    var openaiVoiceID: String
    var openaiModel: String
    var openaiInstructions: String

    static let systemDefault = AttacheSpeechConfiguration(
        provider: .system,
        systemVoiceIdentifier: nil,
        elevenLabsAPIKey: nil,
        elevenLabsVoiceID: "",
        elevenLabsModelID: "eleven_flash_v2_5",
        elevenLabsOutputFormat: "mp3_44100_128",
        xaiAPIKey: nil,
        xaiBaseURL: "https://api.x.ai/v1",
        xaiVoiceID: "ara",
        xaiLanguage: "en",
        openaiAPIKey: nil,
        openaiVoiceID: "marin",
        openaiModel: "gpt-4o-mini-tts",
        openaiInstructions: ""
    )

    /// Explains why the selected cloud provider cannot synthesize audio yet.
    /// Keeping this decision in the configuration makes playback fallback
    /// deterministic and independently testable instead of relying on UI state.
    var playbackUnavailableReason: String? {
        switch provider {
        case .system:
            return nil
        case .elevenLabs:
            if elevenLabsAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                return "ElevenLabs API key is not configured."
            }
            if elevenLabsVoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "ElevenLabs voice is not selected."
            }
        case .xai:
            if xaiAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                return "xAI API key is not configured."
            }
            if xaiVoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "xAI voice is not selected."
            }
        case .openai:
            if openaiAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                return "OpenAI API key is not configured."
            }
            if openaiVoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "OpenAI voice is not selected."
            }
        }
        return nil
    }

    func resolvedForPlayback(systemVoiceIdentifier: String?) -> AttacheSpeechConfiguration {
        guard playbackUnavailableReason != nil else { return self }
        var fallback = self
        fallback.provider = .system
        fallback.systemVoiceIdentifier = systemVoiceIdentifier
        return fallback
    }
}

enum AttacheDevelopmentSecretStore {
    private static let fileName = "DevelopmentSecrets.json"

    static func read(account: String) -> String? {
        let value = load()[account]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func save(_ value: String, account: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var secrets = load()
        if trimmed.isEmpty {
            secrets.removeValue(forKey: account)
            try persist(secrets)
            return
        }

        secrets[account] = trimmed
        try persist(secrets)
    }

    static func delete(account: String) {
        var secrets = load()
        secrets.removeValue(forKey: account)
        try? persist(secrets)
    }

    static var fileURL: URL {
        AttacheAppSupport.supportDirectory().appendingPathComponent(fileName)
    }

    /// All stored secrets, used to migrate the plaintext file into the Keychain.
    static func loadAll() -> [String: String] {
        load()
    }

    /// Removes the plaintext file once its contents have been migrated.
    static func deleteFile() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func persist(_ secrets: [String: String]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(secrets)
        // Create the file 0600 up front so the key bytes are never briefly world-readable.
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try data.write(to: fileURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

enum AttacheRemoteVoiceService {
    /// OpenAI's voices are a fixed set (no list endpoint), newest first.
    static let builtInOpenAIVoices: [RemoteVoiceOption] = [
        RemoteVoiceOption(id: "marin", name: "Marin", provider: .openai, detail: "natural, newest"),
        RemoteVoiceOption(id: "cedar", name: "Cedar", provider: .openai, detail: "natural, newest"),
        RemoteVoiceOption(id: "coral", name: "Coral", provider: .openai, detail: "warm"),
        RemoteVoiceOption(id: "alloy", name: "Alloy", provider: .openai, detail: "neutral"),
        RemoteVoiceOption(id: "ash", name: "Ash", provider: .openai, detail: "expressive"),
        RemoteVoiceOption(id: "ballad", name: "Ballad", provider: .openai, detail: "soft"),
        RemoteVoiceOption(id: "echo", name: "Echo", provider: .openai, detail: "crisp"),
        RemoteVoiceOption(id: "fable", name: "Fable", provider: .openai, detail: "storyteller"),
        RemoteVoiceOption(id: "nova", name: "Nova", provider: .openai, detail: "bright"),
        RemoteVoiceOption(id: "onyx", name: "Onyx", provider: .openai, detail: "deep"),
        RemoteVoiceOption(id: "sage", name: "Sage", provider: .openai, detail: "calm"),
        RemoteVoiceOption(id: "shimmer", name: "Shimmer", provider: .openai, detail: "gentle"),
        RemoteVoiceOption(id: "verse", name: "Verse", provider: .openai, detail: "lively")
    ]

    /// Confirm an OpenAI key works (the voice list itself is fixed) by hitting the
    /// models endpoint, used by the Integrations health check.
    static func verifyOpenAIKey(apiKey: String) async throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VoiceProviderError.missingAPIKey("OpenAI") }
        guard let url = URL(string: "https://api.openai.com/v1/models") else {
            throw VoiceProviderError.invalidEndpoint("OpenAI")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        _ = try await validatedData(for: request, provider: "OpenAI")
    }

    static func fetchElevenLabsVoices(apiKey: String) async throws -> [RemoteVoiceOption] {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VoiceProviderError.missingAPIKey("ElevenLabs") }
        var components = URLComponents(string: "https://api.elevenlabs.io/v2/voices")
        components?.queryItems = [
            URLQueryItem(name: "page_size", value: "100"),
            URLQueryItem(name: "include_total_count", value: "false")
        ]
        guard let url = components?.url else {
            throw VoiceProviderError.invalidEndpoint("ElevenLabs voices request URL could not be built.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(trimmed, forHTTPHeaderField: "xi-api-key")

        // Voice discovery is an idempotent GET: retry once on a transient failure.
        let data = try await retrying(attempts: 2) {
            try await Self.validatedData(for: request, provider: "ElevenLabs")
        }
        let response = try JSONDecoder().decode(ElevenLabsVoicesResponse.self, from: data)
        return response.voices
            .map {
                RemoteVoiceOption(
                    id: $0.voiceID,
                    name: $0.name,
                    provider: .elevenLabs,
                    detail: [$0.category, $0.labels?["accent"], $0.labels?["gender"]]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " / ")
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func fetchXAIVoices(apiKey: String, baseURL: String) async throws -> [RemoteVoiceOption] {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VoiceProviderError.missingAPIKey("xAI") }
        guard let url = URL(string: "\(baseURL.trimmingTrailingSlash())/tts/voices") else {
            throw VoiceProviderError.invalidEndpoint("xAI")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if NetworkSecurity.allowsBearer(url) {
            request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        }

        let data = try await validatedData(for: request, provider: "xAI")
        let response = try JSONDecoder().decode(XAIVoicesResponse.self, from: data)
        let builtIn = response.voices
            .map { RemoteVoiceOption(id: $0.voiceID, name: $0.name, provider: .xai, detail: $0.language ?? "") }
        let custom = (try? await fetchXAICustomVoices(apiKey: apiKey, baseURL: baseURL)) ?? []
        return mergeRemoteVoices(builtIn + custom)
    }

    static func synthesize(text: String, configuration: AttacheSpeechConfiguration, outputURL: URL) async throws {
        switch configuration.provider {
        case .system:
            throw VoiceProviderError.unsupportedProvider
        case .elevenLabs:
            try await synthesizeElevenLabs(text: text, configuration: configuration, outputURL: outputURL)
        case .xai:
            try await synthesizeXAI(text: text, configuration: configuration, outputURL: outputURL)
        case .openai:
            try await synthesizeOpenAI(text: text, configuration: configuration, outputURL: outputURL)
        }
    }

    private static func synthesizeOpenAI(text: String, configuration: AttacheSpeechConfiguration, outputURL: URL) async throws {
        let apiKey = configuration.openaiAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else { throw VoiceProviderError.missingAPIKey("OpenAI") }
        guard !configuration.openaiVoiceID.isEmpty else { throw VoiceProviderError.missingVoice("OpenAI") }
        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
            throw VoiceProviderError.invalidEndpoint("OpenAI")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let instructions = configuration.openaiInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        request.httpBody = try JSONEncoder().encode(
            OpenAISpeechRequest(
                model: configuration.openaiModel.isEmpty ? "gpt-4o-mini-tts" : configuration.openaiModel,
                voice: configuration.openaiVoiceID,
                input: text,
                responseFormat: "mp3",
                instructions: instructions.isEmpty ? nil : instructions
            )
        )

        let data = try await validatedData(for: request, provider: "OpenAI")
        try writeAudio(data, to: outputURL)
    }

    private static func synthesizeElevenLabs(text: String, configuration: AttacheSpeechConfiguration, outputURL: URL) async throws {
        let apiKey = configuration.elevenLabsAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else { throw VoiceProviderError.missingAPIKey("ElevenLabs") }
        guard !configuration.elevenLabsVoiceID.isEmpty else { throw VoiceProviderError.missingVoice("ElevenLabs") }

        var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(configuration.elevenLabsVoiceID)")!
        components.queryItems = [
            URLQueryItem(name: "output_format", value: configuration.elevenLabsOutputFormat)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.httpBody = try JSONEncoder().encode(
            ElevenLabsSpeechRequest(
                text: text,
                modelID: configuration.elevenLabsModelID,
                voiceSettings: ElevenLabsVoiceSettings(
                    stability: 0.5,
                    similarityBoost: 0.8,
                    style: 0.0,
                    useSpeakerBoost: false
                )
            )
        )

        let data = try await validatedData(for: request, provider: "ElevenLabs")
        try writeAudio(data, to: outputURL)
    }

    private static func synthesizeXAI(text: String, configuration: AttacheSpeechConfiguration, outputURL: URL) async throws {
        let apiKey = configuration.xaiAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else { throw VoiceProviderError.missingAPIKey("xAI") }
        guard !configuration.xaiVoiceID.isEmpty else { throw VoiceProviderError.missingVoice("xAI") }

        guard let url = URL(string: "\(configuration.xaiBaseURL.trimmingTrailingSlash())/tts") else {
            throw VoiceProviderError.invalidEndpoint("xAI")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if NetworkSecurity.allowsBearer(url) {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(
            XAISpeechRequest(
                text: text,
                voiceID: configuration.xaiVoiceID,
                language: configuration.xaiLanguage,
                textNormalization: true,
                outputFormat: XAISpeechOutputFormat(codec: "mp3", sampleRate: 44_100, bitRate: 192_000)
            )
        )

        let data = try await validatedData(for: request, provider: "xAI")
        try writeAudio(data, to: outputURL)
    }

    private static func fetchXAICustomVoices(apiKey: String, baseURL: String) async throws -> [RemoteVoiceOption] {
        guard var components = URLComponents(string: "\(baseURL.trimmingTrailingSlash())/custom-voices") else {
            throw VoiceProviderError.invalidEndpoint("xAI custom voices")
        }
        components.queryItems = [
            URLQueryItem(name: "limit", value: "100")
        ]
        guard let url = components.url else { throw VoiceProviderError.invalidEndpoint("xAI custom voices") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if NetworkSecurity.allowsBearer(url) {
            request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        }

        let data = try await validatedData(for: request, provider: "xAI custom voices")
        let response = try JSONDecoder().decode(XAICustomVoicesResponse.self, from: data)
        return response.voices.map {
            let detail = [$0.description, $0.gender, "custom"]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " / ")
            return RemoteVoiceOption(
                id: $0.voiceID,
                name: $0.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? $0.name! : $0.voiceID,
                provider: .xai,
                detail: detail
            )
        }
    }

    private static func mergeRemoteVoices(_ voices: [RemoteVoiceOption]) -> [RemoteVoiceOption] {
        var seen = Set<String>()
        return voices
            .filter { voice in
                guard !seen.contains(voice.id) else { return false }
                seen.insert(voice.id)
                return true
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func validatedData(for request: URLRequest, provider: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceProviderError.invalidResponse(provider)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw VoiceProviderError.http(provider: provider, status: httpResponse.statusCode, body: String(body.prefix(300)))
        }
        return data
    }

    private static func writeAudio(_ data: Data, to outputURL: URL) throws {
        guard !data.isEmpty else { throw VoiceProviderError.emptyAudio }
        try data.write(to: outputURL, options: .atomic)
    }
}

enum VoiceProviderError: Error, LocalizedError {
    case missingAPIKey(String)
    case missingVoice(String)
    case invalidEndpoint(String)
    case invalidResponse(String)
    case http(provider: String, status: Int, body: String)
    case emptyAudio
    case unsupportedProvider

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "\(provider) API key is not configured."
        case .missingVoice(let provider):
            return "\(provider) voice is not selected."
        case .invalidEndpoint(let provider):
            return "\(provider) endpoint URL is invalid."
        case .invalidResponse(let provider):
            return "\(provider) returned a non-HTTP response."
        case .http(let provider, let status, let body):
            return "\(provider) failed with HTTP \(status): \(body)"
        case .emptyAudio:
            return "The voice provider returned an empty audio file."
        case .unsupportedProvider:
            return "This voice provider is handled by the local speech engine."
        }
    }
}

private struct ElevenLabsVoicesResponse: Decodable {
    var voices: [ElevenLabsVoice]
}

private struct ElevenLabsVoice: Decodable {
    var voiceID: String
    var name: String
    var category: String?
    var labels: [String: String]?

    enum CodingKeys: String, CodingKey {
        case voiceID = "voice_id"
        case name
        case category
        case labels
    }
}

private struct XAIVoicesResponse: Decodable {
    var voices: [XAIVoice]
}

private struct XAIVoice: Decodable {
    var voiceID: String
    var name: String
    var language: String?

    enum CodingKeys: String, CodingKey {
        case voiceID = "voice_id"
        case name
        case language
    }
}

private struct XAICustomVoicesResponse: Decodable {
    var voices: [XAICustomVoice]
}

private struct XAICustomVoice: Decodable {
    var voiceID: String
    var name: String?
    var description: String?
    var gender: String?

    enum CodingKeys: String, CodingKey {
        case voiceID = "voice_id"
        case name
        case description
        case gender
    }
}

private struct ElevenLabsSpeechRequest: Encodable {
    var text: String
    var modelID: String
    var voiceSettings: ElevenLabsVoiceSettings

    enum CodingKeys: String, CodingKey {
        case text
        case modelID = "model_id"
        case voiceSettings = "voice_settings"
    }
}

private struct ElevenLabsVoiceSettings: Encodable {
    var stability: Double
    var similarityBoost: Double
    var style: Double
    var useSpeakerBoost: Bool

    enum CodingKeys: String, CodingKey {
        case stability
        case similarityBoost = "similarity_boost"
        case style
        case useSpeakerBoost = "use_speaker_boost"
    }
}

private struct XAISpeechRequest: Encodable {
    var text: String
    var voiceID: String
    var language: String
    var textNormalization: Bool
    var outputFormat: XAISpeechOutputFormat

    enum CodingKeys: String, CodingKey {
        case text
        case voiceID = "voice_id"
        case language
        case textNormalization = "text_normalization"
        case outputFormat = "output_format"
    }
}

private struct XAISpeechOutputFormat: Encodable {
    var codec: String
    var sampleRate: Int
    var bitRate: Int

    enum CodingKeys: String, CodingKey {
        case codec
        case sampleRate = "sample_rate"
        case bitRate = "bit_rate"
    }
}

private struct OpenAISpeechRequest: Encodable {
    var model: String
    var voice: String
    var input: String
    var responseFormat: String
    var instructions: String?

    enum CodingKeys: String, CodingKey {
        case model
        case voice
        case input
        case responseFormat = "response_format"
        case instructions
    }
}

private extension String {
    func trimmingTrailingSlash() -> String {
        var result = trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result.isEmpty ? self : result
    }
}
