import Foundation
import AttacheCore

struct CompanionPresentationModelOption: Identifiable, Hashable {
    var id: String
    var detail: String
    var reasoningEfforts: [String]
    var serviceTiers: [CompanionPresentationServiceTierOption] = []

    var title: String {
        detail.isEmpty ? id : "\(id) - \(detail)"
    }
}

struct CompanionPresentationServiceTierOption: Identifiable, Hashable {
    var id: String
    var title: String
    var detail: String
}

enum CompanionPresentationModelService {
    static func fetchModels(
        provider: CompanionPresentationProvider,
        baseURLText: String,
        apiKey: String
    ) async throws -> [CompanionPresentationModelOption] {
        // CLI providers have no HTTP endpoint, so resolve their models before building
        // a base URL (an empty URL would crash the force-unwrap below).
        if provider.isCLI {
            return cliModels(for: provider)
        }

        guard let baseURL = URL(string: baseURLText.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: provider.defaultBaseURL) else {
            throw URLError(.badURL)
        }

        // Model discovery is an idempotent GET; retry once on a transient failure.
        switch provider {
        case .xai:
            return try await retrying(attempts: 2) { try await fetchXAIModels(baseURL: baseURL, apiKey: apiKey) }
        case .ollama:
            return try await retrying(attempts: 2) { try await fetchOllamaModels(baseURL: baseURL) }
        case .lmStudio, .groq, .custom:
            return try await retrying(attempts: 2) {
                try await fetchOpenAICompatibleModels(baseURL: baseURL, apiKey: apiKey, provider: provider)
            }
        case .claudeCLI, .codexCLI:
            return cliModels(for: provider)   // handled above; keeps the switch exhaustive
        }
    }

    /// Models for the subscription CLIs. Claude's aliases always map to current models;
    /// Codex's real list lives in its own cache so we show exactly what Codex offers.
    private static func cliModels(for provider: CompanionPresentationProvider) -> [CompanionPresentationModelOption] {
        switch provider {
        case .claudeCLI:
            // Claude exposes no model-list command and its catalog isn't cached on
            // disk, so we offer the aliases, which always resolve to the latest of
            // each tier (so they never go stale). Effort maps to `claude --effort`.
            let efforts = ["default", "low", "medium", "high", "xhigh", "max"]
            return [
                ("default", "use Claude Code's configured model"),
                ("opus", "most capable"),
                ("sonnet", "most efficient"),
                ("haiku", "fastest")
            ].map { CompanionPresentationModelOption(id: $0.0, detail: $0.1, reasoningEfforts: efforts) }
        case .codexCLI:
            return codexModelsFromCache()
        default:
            return []
        }
    }

    /// Read Codex's own model cache (~/.codex/models_cache.json) so the list matches
    /// what `codex` shows. Falls back to just "default" if the cache is missing.
    private static func codexModelsFromCache() -> [CompanionPresentationModelOption] {
        var options = [CompanionPresentationModelOption(id: "default", detail: "use Codex's configured model", reasoningEfforts: [])]
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return options
        }
        for model in models {
            guard let slug = (model["slug"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !slug.isEmpty else { continue }
            if let visibility = model["visibility"] as? String, visibility != "list" { continue }
            let name = (model["display_name"] as? String) ?? slug
            let levels = (model["supported_reasoning_levels"] as? [[String: Any]])?.compactMap { $0["effort"] as? String } ?? []
            let efforts = levels.isEmpty ? [] : (["default"] + levels)
            let serviceTiers = serviceTiers(in: model, provider: .codexCLI, modelID: slug)
            options.append(CompanionPresentationModelOption(
                id: slug,
                detail: name.lowercased() == slug.lowercased() ? "" : name,
                reasoningEfforts: efforts,
                serviceTiers: serviceTiers
            ))
        }
        return options
    }

    private static func fetchXAIModels(baseURL: URL, apiKey: String) async throws -> [CompanionPresentationModelOption] {
        do {
            let data = try await data(
                url: endpoint(baseURL: baseURL, path: "language-models"),
                apiKey: apiKey,
                providerName: "xAI"
            )
            let options = try parseXAILanguageModels(data)
            if !options.isEmpty {
                return options
            }
        } catch {
            let fallbackData = try await data(
                url: endpoint(baseURL: baseURL, path: "models"),
                apiKey: apiKey,
                providerName: "xAI"
            )
            return try parseOpenAIModels(fallbackData, provider: .xai)
        }

        let fallbackData = try await data(
            url: endpoint(baseURL: baseURL, path: "models"),
            apiKey: apiKey,
            providerName: "xAI"
        )
        return try parseOpenAIModels(fallbackData, provider: .xai)
    }

    private static func fetchOllamaModels(baseURL: URL) async throws -> [CompanionPresentationModelOption] {
        do {
            let data = try await data(
                url: endpoint(baseURL: baseURL, path: "models"),
                apiKey: "",
                providerName: "Ollama"
            )
            let options = try parseOpenAIModels(data, provider: .ollama)
            if !options.isEmpty {
                return options
            }
        } catch {
            let tagsURL = ollamaNativeBaseURL(from: baseURL)
                .appendingPathComponent("api")
                .appendingPathComponent("tags")
            let data = try await data(url: tagsURL, apiKey: "", providerName: "Ollama")
            return try parseOllamaTags(data)
        }

        let tagsURL = ollamaNativeBaseURL(from: baseURL)
            .appendingPathComponent("api")
            .appendingPathComponent("tags")
        let data = try await data(url: tagsURL, apiKey: "", providerName: "Ollama")
        return try parseOllamaTags(data)
    }

    private static func fetchOpenAICompatibleModels(
        baseURL: URL,
        apiKey: String,
        provider: CompanionPresentationProvider
    ) async throws -> [CompanionPresentationModelOption] {
        let data = try await data(
            url: endpoint(baseURL: baseURL, path: "models"),
            apiKey: apiKey,
            providerName: provider.title
        )
        return try parseOpenAIModels(data, provider: provider)
    }

    private static func data(url: URL, apiKey: String, providerName: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, NetworkSecurity.allowsBearer(url) {
            request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelDiscoveryError.invalidResponse(providerName)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ModelDiscoveryError.httpStatus(providerName, httpResponse.statusCode, String(body.prefix(240)))
        }
        return data
    }

    private static func parseXAILanguageModels(_ data: Data) throws -> [CompanionPresentationModelOption] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            throw ModelDiscoveryError.invalidPayload("xAI")
        }

        return models.compactMap { model in
            guard let id = model["id"] as? String, !id.isEmpty else { return nil }
            let aliases = (model["aliases"] as? [String] ?? []).filter { !$0.isEmpty }
            let modalities = [model["input_modalities"], model["output_modalities"]]
                .compactMap { $0 as? [String] }
                .flatMap { $0 }
                .filter { !$0.isEmpty }
            let detailParts = [
                aliases.isEmpty ? nil : "aliases \(aliases.joined(separator: ", "))",
                modalities.isEmpty ? nil : modalities.uniqued().joined(separator: "/")
            ].compactMap { $0 }
            return CompanionPresentationModelOption(
                id: id,
                detail: detailParts.joined(separator: " / "),
                reasoningEfforts: fallbackReasoningEfforts(provider: .xai, modelID: id),
                serviceTiers: fallbackServiceTierOptions(provider: .xai, modelID: id)
            )
        }
        .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    private static func parseOpenAIModels(_ data: Data, provider: CompanionPresentationProvider) throws -> [CompanionPresentationModelOption] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["data"] as? [[String: Any]] else {
            throw ModelDiscoveryError.invalidPayload(provider.title)
        }

        return models.compactMap { model in
            guard let id = model["id"] as? String, !id.isEmpty else { return nil }
            let owner = model["owned_by"] as? String ?? ""
            return CompanionPresentationModelOption(
                id: id,
                detail: owner,
                reasoningEfforts: reasoningEfforts(in: model, provider: provider, modelID: id),
                serviceTiers: serviceTiers(in: model, provider: provider, modelID: id)
            )
        }
        .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    private static func parseOllamaTags(_ data: Data) throws -> [CompanionPresentationModelOption] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            throw ModelDiscoveryError.invalidPayload("Ollama")
        }

        return models.compactMap { model in
            let name = (model["name"] as? String) ?? (model["model"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            let detail = (model["details"] as? [String: Any])?["parameter_size"] as? String ?? ""
            return CompanionPresentationModelOption(
                id: name,
                detail: detail,
                reasoningEfforts: []
            )
        }
        .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    static func fallbackReasoningEfforts(provider: CompanionPresentationProvider, modelID: String) -> [String] {
        let normalizedID = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch provider {
        case .xai:
            switch normalizedID {
            case "grok-4.3", "grok-4-0709":
                return ["none", "low", "medium", "high"]
            default:
                return []
            }
        case .groq:
            if normalizedID.contains("qwen3-32b") || normalizedID.contains("qwen-3-32b") {
                return ["default", "none"]
            }
            if normalizedID.contains("gpt-oss") {
                return ["low", "medium", "high"]
            }
            return []
        case .custom:
            if normalizedID.hasPrefix("gpt-5") {
                return ["none", "minimal", "low", "medium", "high", "xhigh"]
            }
            return []
        case .claudeCLI:
            return ["default", "low", "medium", "high", "xhigh", "max"]
        case .codexCLI, .ollama, .lmStudio:
            return []
        }
    }

    static func fallbackServiceTierOptions(provider: CompanionPresentationProvider, modelID: String) -> [CompanionPresentationServiceTierOption] {
        switch provider {
        case .xai:
            return [
                CompanionPresentationServiceTierOption(id: "default", title: "Default", detail: "Use xAI's default processing tier"),
                CompanionPresentationServiceTierOption(id: "priority", title: "Priority", detail: "Request priority processing")
            ]
        case .groq:
            return [
                CompanionPresentationServiceTierOption(id: "default", title: "Default", detail: "Use Groq's default tier"),
                CompanionPresentationServiceTierOption(id: "auto", title: "Auto", detail: "Let Groq choose the best available tier"),
                CompanionPresentationServiceTierOption(id: "on_demand", title: "On demand", detail: "Standard Groq processing"),
                CompanionPresentationServiceTierOption(id: "flex", title: "Flex", detail: "Best-effort high-throughput processing"),
                CompanionPresentationServiceTierOption(id: "performance", title: "Performance", detail: "Enterprise low-latency tier")
            ]
        case .codexCLI:
            return []
        case .custom:
            let normalizedID = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalizedID.hasPrefix("gpt-5") else { return [] }
            return [
                CompanionPresentationServiceTierOption(id: "default", title: "Default", detail: "Use the project default tier"),
                CompanionPresentationServiceTierOption(id: "flex", title: "Flex", detail: "Lower-cost flex processing"),
                CompanionPresentationServiceTierOption(id: "priority", title: "Priority", detail: "Priority processing")
            ]
        case .ollama, .lmStudio, .claudeCLI:
            return []
        }
    }

    private static func reasoningEfforts(
        in model: [String: Any],
        provider: CompanionPresentationProvider,
        modelID: String
    ) -> [String] {
        let keys = [
            "reasoning_efforts",
            "supported_reasoning_efforts",
            "reasoning_levels",
            "supported_reasoning_levels"
        ]
        for key in keys {
            let values = stringValues(in: model[key], preferredKeys: ["effort", "id", "name"])
            if !values.isEmpty {
                return values
            }
        }
        if let capabilities = model["capabilities"] as? [String: Any] {
            for key in keys {
                let values = stringValues(in: capabilities[key], preferredKeys: ["effort", "id", "name"])
                if !values.isEmpty {
                    return values
                }
            }
        }
        return fallbackReasoningEfforts(provider: provider, modelID: modelID)
    }

    private static func serviceTiers(
        in model: [String: Any],
        provider: CompanionPresentationProvider,
        modelID: String
    ) -> [CompanionPresentationServiceTierOption] {
        let keys = [
            "service_tiers",
            "supported_service_tiers",
            "processing_tiers",
            "supported_processing_tiers"
        ]
        for key in keys {
            let tiers = serviceTierValues(in: model[key])
            if !tiers.isEmpty {
                return tiers
            }
        }
        if let capabilities = model["capabilities"] as? [String: Any] {
            for key in keys {
                let tiers = serviceTierValues(in: capabilities[key])
                if !tiers.isEmpty {
                    return tiers
                }
            }
        }
        return fallbackServiceTierOptions(provider: provider, modelID: modelID)
    }

    private static func stringValues(in value: Any?, preferredKeys: [String]) -> [String] {
        if let values = value as? [String] {
            return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.uniqued()
        }
        if let objects = value as? [[String: Any]] {
            return objects.compactMap { object in
                for key in preferredKeys {
                    if let value = object[key] as? String {
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { return trimmed }
                    }
                }
                return nil
            }.uniqued()
        }
        return []
    }

    private static func serviceTierValues(in value: Any?) -> [CompanionPresentationServiceTierOption] {
        if let values = value as? [String] {
            return values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .uniqued()
                .map { CompanionPresentationServiceTierOption(id: $0, title: serviceTierTitle($0), detail: "") }
        }
        if let objects = value as? [[String: Any]] {
            return objects.compactMap { object in
                let id = ((object["id"] as? String) ?? (object["tier"] as? String) ?? (object["name"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { return nil }
                let title = ((object["name"] as? String) ?? serviceTierTitle(id))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = ((object["description"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return CompanionPresentationServiceTierOption(id: id, title: title.isEmpty ? serviceTierTitle(id) : title, detail: detail)
            }.uniqued()
        }
        return []
    }

    private static func serviceTierTitle(_ tier: String) -> String {
        switch tier {
        case "on_demand": return "On demand"
        case "xhigh": return "Extra high"
        default:
            return tier
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    private static func endpoint(baseURL: URL, path: String) -> URL {
        let url = baseURL
        if url.path.hasSuffix("/\(path)") {
            return url
        }
        return url.appendingPathComponent(path)
    }

    private static func ollamaNativeBaseURL(from baseURL: URL) -> URL {
        if baseURL.lastPathComponent == "v1" {
            return baseURL.deletingLastPathComponent()
        }
        return baseURL
    }
}

private enum ModelDiscoveryError: LocalizedError {
    case invalidResponse(String)
    case invalidPayload(String)
    case httpStatus(String, Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let provider):
            return "\(provider) model discovery returned a non-HTTP response."
        case .invalidPayload(let provider):
            return "\(provider) model discovery returned an unexpected payload."
        case .httpStatus(let provider, let status, let body):
            return "\(provider) model discovery failed with HTTP \(status): \(body)"
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
