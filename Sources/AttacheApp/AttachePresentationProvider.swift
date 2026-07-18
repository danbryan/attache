import AttacheCore
import Foundation

enum AttachePresentationProvider: String, CaseIterable, Hashable, Identifiable, Codable {
    case xai
    case ollama
    case custom
    case claudeCLI = "claude_cli"
    case codexCLI = "codex_cli"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xai: return "xAI / Grok"
        case .ollama: return "Ollama"
        case .custom: return "Custom"
        case .claudeCLI: return "Claude subscription"
        case .codexCLI: return "Codex subscription"
        }
    }

    var menuTitle: String {
        switch self {
        case .xai: return "xAI Grok"
        case .ollama: return "Ollama Local"
        case .custom: return "Custom OpenAI Compatible"
        case .claudeCLI: return "Claude (your Claude Code login)"
        case .codexCLI: return "Codex (your ChatGPT login)"
        }
    }

    /// CLI providers run the tool you're already logged into instead of calling an
    /// HTTP endpoint, so they use your subscription with no API key.
    var cliTool: CLILanguageModel.Tool? {
        switch self {
        case .claudeCLI: return .claude
        case .codexCLI: return .codex
        default: return nil
        }
    }

    var isCLI: Bool { cliTool != nil }

    /// Only providers whose subprocess/API boundary can prevent the model from
    /// reading host files are eligible for personality inference. Codex CLI's
    /// current `read-only` sandbox prevents writes but still exposes arbitrary
    /// user-readable files through native tools, so keep the persisted enum case
    /// for import/backward compatibility while refusing to offer or execute it.
    var supportsSafePersonalityInference: Bool {
        self != .codexCLI
    }

    static var personalityInferenceCases: [Self] {
        allCases.filter(\.supportsSafePersonalityInference)
    }

    var defaultBaseURL: String {
        switch self {
        case .xai: return "https://api.x.ai/v1"
        case .ollama: return "http://127.0.0.1:11434/v1"
        case .custom: return "https://api.openai.com/v1"
        case .claudeCLI, .codexCLI: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .xai: return "grok-4.3"
        case .ollama: return "qwen3:7b"
        case .custom: return "gpt-4o-mini"
        case .claudeCLI, .codexCLI: return "default"   // "default" = use the tool's own configured model
        }
    }

    var defaultReasoningEffort: String {
        switch self {
        case .xai, .custom, .codexCLI, .claudeCLI:
            return "default"
        case .ollama:
            return "none"
        }
    }

    var supportsServiceTier: Bool {
        switch self {
        case .xai, .custom, .codexCLI:
            return true
        case .ollama, .claudeCLI:
            return false
        }
    }

    var defaultServiceTier: String {
        supportsServiceTier ? "default" : ""
    }

    /// Legacy fallback only. The settings UI uses selected-model capabilities.
    var serviceTierOptions: [String] {
        AttachePresentationModelService
            .fallbackServiceTierOptions(provider: self, modelID: defaultModel)
            .map(\.id)
    }

    var requiresAPIKey: Bool {
        switch self {
        case .ollama, .claudeCLI, .codexCLI:
            return false
        case .xai, .custom:
            return true
        }
    }

    var supportsReasoningEffort: Bool {
        switch self {
        case .xai, .ollama, .custom, .codexCLI, .claudeCLI:
            return true
        }
    }

    var developmentSecretAccount: String {
        // Brand-level account shared across features (e.g. xAI's key powers both
        // the presentation model and xAI voices, entered once in Integrations).
        "\(rawValue)-api-key"
    }

    static func from(explicitValue: String?, baseURLText: String?) -> AttachePresentationProvider {
        let explicit = explicitValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let provider = AttachePresentationProvider(rawValue: explicit) {
            return provider
        }

        switch explicit.lowercased() {
        case "xai", "grok", "xai_grok", "xai-grok":
            return .xai
        case "ollama", "ollama_llm", "ollama-llm":
            return .ollama
        case "lmstudio", "lm_studio", "lm-studio", "lmstudio_llm", "lmstudio-llm":
            return .ollama
        case "custom", "openai_compatible", "openai-compatible", "openai_compatible_llm",
             // Groq was a hosted OpenAI-compatible provider; it was retired
             // (INF-388). Any stray "groq" identifier resolves to Custom, the
             // generic OpenAI-compatible option, never crashing or resetting to
             // a different cloud provider.
             "groq", "groq_llm", "groq-llm":
            return .custom
        case "claude", "claude_cli", "claude-cli", "claude_code", "anthropic_subscription":
            return .claudeCLI
        case "codex", "codex_cli", "codex-cli", "chatgpt", "openai_subscription":
            return .codexCLI
        default:
            break
        }

        let lowercasedBaseURL = (baseURLText ?? "").lowercased()
        if lowercasedBaseURL.contains("api.x.ai") {
            return .xai
        }
        if lowercasedBaseURL.contains("11434") || lowercasedBaseURL.contains("ollama") {
            return .ollama
        }
        if lowercasedBaseURL.contains("1234") || lowercasedBaseURL.contains("lmstudio") || lowercasedBaseURL.contains("lm-studio") {
            return .ollama
        }
        if !lowercasedBaseURL.isEmpty {
            return .custom
        }
        return .ollama
    }

    static func isLegacyLMStudio(explicitValue: String?, baseURLText: String?) -> Bool {
        let explicit = explicitValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let base = baseURLText?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return ["lmstudio", "lm_studio", "lm-studio", "lmstudio_llm", "lmstudio-llm"].contains(explicit)
            || base.contains("lmstudio")
            || base.contains("lm-studio")
            || base.contains("127.0.0.1:1234")
            || base.contains("localhost:1234")
    }

    /// Personality exports and defaults written before LM Studio or Groq were
    /// retired still decode safely. LM Studio maps to Ollama; Groq (a hosted
    /// OpenAI-compatible provider, INF-388) maps to Custom. A stray retired
    /// value never makes the whole personality/settings file unreadable.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if ["lmStudio", "lmstudio", "lm_studio", "lm-studio"].contains(raw) {
            self = .ollama
            return
        }
        if ["groq", "groq_llm", "groq-llm"].contains(raw) {
            self = .custom
            return
        }
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown presentation provider \(raw)"
            )
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension AttachePresentationProvider {
    /// The real data-egress classification for this provider at a resolved
    /// endpoint (INF-307). One classification drives onboarding, integration
    /// settings, personality model selection, consent, memory egress, and
    /// diagnostics. A CLI that runs locally but sends to a subscription is
    /// `.subscriptionRemoteCLI`, not on-device.
    func dataEgress(endpoint: String?, enabled: Bool = true) -> AttacheDataEgress {
        AttacheDataEgressClassifier.classify(
            providerRawValue: rawValue,
            endpoint: endpoint,
            isCLI: isCLI,
            enabled: enabled
        )
    }
}
