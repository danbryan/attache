import Foundation
import AttacheCore

struct AttachePresentationModelOption: Identifiable, Hashable {
    var id: String
    var detail: String
    var reasoningEfforts: [String]
    var serviceTiers: [AttachePresentationServiceTierOption] = []
    var capabilityProfile: AttacheModelCapabilityProfile = .unknown

    var title: String {
        detail.isEmpty ? id : "\(id) - \(detail)"
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.detail == rhs.detail
            && lhs.reasoningEfforts == rhs.reasoningEfforts
            && lhs.serviceTiers == rhs.serviceTiers
            && lhs.capabilityProfile == rhs.capabilityProfile
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(detail)
        hasher.combine(reasoningEfforts)
        hasher.combine(serviceTiers)
        hasher.combine(capabilityProfile.declaredInputCeiling)
        hasher.combine(capabilityProfile.outputLimit)
        hasher.combine(capabilityProfile.estimatorFamily)
        hasher.combine(capabilityProfile.provenance.rawValue)
    }
}

struct AttachePresentationServiceTierOption: Identifiable, Hashable {
    var id: String
    var title: String
    var detail: String
}

enum AttachePresentationModelService {
    /// Runtime capability facts discovered from the exact provider endpoint.
    /// The cache key includes provider, normalized endpoint, and model, so a
    /// Custom URL change or a second Ollama host cannot inherit stale limits.
    private static let capabilityCache: AttacheCapabilityCache = {
        let cache = AttacheCapabilityCache()
        if let data = try? Data(contentsOf: capabilityCacheURL),
           let persisted = try? JSONDecoder().decode(
            [String: AttacheCapabilityCacheRecord].self,
            from: data
           ) {
            cache.restore(persisted)
        }
        return cache
    }()

    private static let capabilityCacheURL: URL = {
        // Unit tests must never read or mutate the user's live capability
        // cache. The production app uses its restrictive support directory.
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("attache-capabilities-test-\(getpid()).json")
        }
        return AttacheAppSupport.supportDirectory()
            .appendingPathComponent("ModelCapabilities.json")
    }()

    static func fetchModels(
        provider: AttachePresentationProvider,
        baseURLText: String,
        apiKey: String
    ) async throws -> [AttachePresentationModelOption] {
        // CLI providers have no HTTP endpoint, so resolve their models before building
        // a base URL (an empty URL would crash the force-unwrap below).
        if provider.isCLI {
            let options = cliModels(for: provider)
            recordCapabilities(options, provider: provider, baseURLText: "")
            return options
        }

        guard let baseURL = URL(string: baseURLText.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: provider.defaultBaseURL) else {
            throw URLError(.badURL)
        }

        // Model discovery is an idempotent GET; retry once on a transient failure.
        let options: [AttachePresentationModelOption]
        switch provider {
        case .xai:
            options = try await retrying(attempts: 2) { try await fetchXAIModels(baseURL: baseURL, apiKey: apiKey) }
        case .ollama:
            options = try await retrying(attempts: 2) { try await fetchOllamaModels(baseURL: baseURL) }
        case .groq, .custom:
            options = try await retrying(attempts: 2) {
                try await fetchOpenAICompatibleModels(baseURL: baseURL, apiKey: apiKey, provider: provider)
            }
        case .claudeCLI, .codexCLI:
            options = cliModels(for: provider)   // handled above; keeps the switch exhaustive
        }
        recordCapabilities(options, provider: provider, baseURLText: baseURL.absoluteString)
        return options
    }

    static func modelIdentity(
        provider: AttachePresentationProvider,
        baseURLText: String,
        modelID: String
    ) -> ModelIdentity {
        ModelIdentity(
            provider: provider.rawValue,
            normalizedEndpoint: provider.isCLI ? "" : baseURLText,
            requestedModel: modelID
        )
    }

    /// Last provider-confirmed facts for one exact destination. Unknown is a
    /// first-class result and activates the compiler's conservative envelope.
    static func capabilityProfile(
        provider: AttachePresentationProvider,
        baseURLText: String,
        modelID: String
    ) -> AttacheModelCapabilityProfile {
        let identity = modelIdentity(provider: provider, baseURLText: baseURLText, modelID: modelID)
        guard let record = capabilityCache.record(for: identity) else {
            return provider == .xai ? documentedXAICapability(for: modelID) ?? .unknown : .unknown
        }
        let stored = record.profile
        let profile = AttacheModelCapabilityProfile(
            architecturalMaximum: stored.architecturalMaximum,
            configuredRuntimeLimit: stored.configuredRuntimeLimit,
            outputLimit: stored.outputLimit,
            estimatorFamily: stored.estimatorFamily,
            supportsReasoning: stored.supportsReasoning,
            reasoningLevels: stored.reasoningLevels,
            freshness: stored.freshness ?? record.recordedAt,
            confidence: stored.confidence,
            provenance: stored.provenance
        )
        guard provider == .xai else { return profile }
        let efforts = profile.reasoningLevels.isEmpty
            ? (documentedXAICapability(for: modelID)?.reasoningLevels ?? [])
            : profile.reasoningLevels
        return mergedXAICapability(
            live: profile,
            liveEfforts: profile.reasoningLevels,
            documented: documentedXAICapability(for: modelID),
            effectiveEfforts: efforts
        )
    }

    private static func recordCapabilities(
        _ options: [AttachePresentationModelOption],
        provider: AttachePresentationProvider,
        baseURLText: String
    ) {
        for option in options {
            let identity = modelIdentity(
                provider: provider,
                baseURLText: baseURLText,
                modelID: option.id
            )
            capabilityCache.record(identity: identity, profile: option.capabilityProfile)
        }
        persistCapabilityCache()
    }

    private static func persistCapabilityCache() {
        guard let data = try? JSONEncoder().encode(capabilityCache.snapshot()) else { return }
        do {
            try FileManager.default.createDirectory(
                at: capabilityCacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: capabilityCacheURL, options: [.atomic])
            _ = chmod(capabilityCacheURL.path, 0o600)
        } catch {
            // Discovery remains usable in memory if persistence is unavailable.
        }
    }

    /// Models for the subscription CLIs. Claude's aliases always map to current models;
    /// Codex's real list lives in its own cache so we show exactly what Codex offers.
    private static func cliModels(for provider: AttachePresentationProvider) -> [AttachePresentationModelOption] {
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
            ].map {
                AttachePresentationModelOption(
                    id: $0.0,
                    detail: $0.1,
                    reasoningEfforts: efforts,
                    capabilityProfile: AttacheModelCapabilityProfile(
                        architecturalMaximum: nil,
                        supportsReasoning: true,
                        reasoningLevels: efforts,
                        confidence: .unknown,
                        provenance: .unknown
                    )
                )
            }
        case .codexCLI:
            return codexModelsFromCache()
        default:
            return []
        }
    }

    /// Read Codex's own model cache so the list matches
    /// what `codex` shows. Falls back to just "default" if the cache is missing.
    private static func codexModelsFromCache() -> [AttachePresentationModelOption] {
        var options = [AttachePresentationModelOption(
            id: "default",
            detail: "use Codex's configured model",
            reasoningEfforts: fallbackReasoningEfforts(provider: .codexCLI, modelID: "default")
        )]
        let url = CodexPaths.home().appendingPathComponent("models_cache.json")
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
            let efforts = levels.isEmpty
                ? fallbackReasoningEfforts(provider: .codexCLI, modelID: slug)
                : (["default"] + levels)
            let serviceTiers = serviceTiers(in: model, provider: .codexCLI, modelID: slug)
            var capabilityJSON = model
            capabilityJSON["reasoning_levels"] = levels
            let profile = AttacheCapabilityParser.parseCodexCache(capabilityJSON) ?? .unknown
            options.append(AttachePresentationModelOption(
                id: slug,
                detail: name.lowercased() == slug.lowercased() ? "" : name,
                reasoningEfforts: efforts,
                serviceTiers: serviceTiers,
                capabilityProfile: profile
            ))
        }
        return options
    }

    private static func fetchXAIModels(baseURL: URL, apiKey: String) async throws -> [AttachePresentationModelOption] {
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

    private static func fetchOllamaModels(baseURL: URL) async throws -> [AttachePresentationModelOption] {
        let options: [AttachePresentationModelOption]
        do {
            let data = try await data(
                url: endpoint(baseURL: baseURL, path: "models"),
                apiKey: "",
                providerName: "Ollama"
            )
            let openAIOptions = try parseOpenAIModels(data, provider: .ollama)
            if !openAIOptions.isEmpty {
                options = openAIOptions
            } else {
                options = try await fetchOllamaNativeTags(baseURL: baseURL)
            }
        } catch {
            options = try await fetchOllamaNativeTags(baseURL: baseURL)
        }
        return await enrichOllamaCapabilities(options, baseURL: baseURL)
    }

    private static func fetchOllamaNativeTags(baseURL: URL) async throws -> [AttachePresentationModelOption] {
        let tagsURL = ollamaNativeBaseURL(from: baseURL)
            .appendingPathComponent("api")
            .appendingPathComponent("tags")
        let data = try await data(url: tagsURL, apiKey: "", providerName: "Ollama")
        return try parseOllamaTags(data)
    }

    /// Ollama's list endpoints do not include thinking capabilities. `/api/show`
    /// does, so query the installed model itself and attach only the controls it
    /// actually supports. These are local loopback calls and contain no prompts.
    private static func enrichOllamaCapabilities(
        _ options: [AttachePresentationModelOption],
        baseURL: URL
    ) async -> [AttachePresentationModelOption] {
        await withTaskGroup(of: (String, [String], AttacheModelCapabilityProfile).self) { group in
            for option in options {
                group.addTask {
                    let capability = try? await fetchOllamaCapability(
                        baseURL: baseURL,
                        modelID: option.id
                    )
                    return (
                        option.id,
                        capability?.reasoningEfforts ?? [],
                        capability?.profile ?? .unknown
                    )
                }
            }

            var effortsByID: [String: [String]] = [:]
            var profileByID: [String: AttacheModelCapabilityProfile] = [:]
            for await (id, efforts, profile) in group {
                effortsByID[id] = efforts
                profileByID[id] = profile
            }
            return options.map { option in
                var enriched = option
                enriched.reasoningEfforts = effortsByID[option.id] ?? []
                enriched.capabilityProfile = profileByID[option.id] ?? .unknown
                return enriched
            }
        }
    }

    private static func fetchOllamaCapability(
        baseURL: URL,
        modelID: String
    ) async throws -> (reasoningEfforts: [String], profile: AttacheModelCapabilityProfile) {
        let showURL = ollamaNativeBaseURL(from: baseURL)
            .appendingPathComponent("api")
            .appendingPathComponent("show")
        var request = URLRequest(url: showURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": modelID])
        let data = try await data(request: request, providerName: "Ollama")
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelDiscoveryError.invalidPayload("Ollama")
        }
        root["name"] = modelID
        let efforts = try parseOllamaShowReasoningEfforts(data, modelID: modelID)
        let parsed = AttacheCapabilityParser.parseOllama(show: root) ?? .unknown
        let profile = AttacheModelCapabilityProfile(
            architecturalMaximum: parsed.architecturalMaximum,
            configuredRuntimeLimit: parsed.configuredRuntimeLimit,
            outputLimit: parsed.outputLimit,
            estimatorFamily: parsed.estimatorFamily,
            supportsReasoning: !efforts.isEmpty,
            reasoningLevels: efforts,
            freshness: parsed.freshness,
            confidence: parsed.confidence,
            provenance: parsed.provenance
        )
        return (efforts, profile)
    }

    private static func fetchOpenAICompatibleModels(
        baseURL: URL,
        apiKey: String,
        provider: AttachePresentationProvider
    ) async throws -> [AttachePresentationModelOption] {
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
        return try await data(request: request, providerName: providerName)
    }

    private static func data(request: URLRequest, providerName: String) async throws -> Data {
        // Model discovery is an egress too. A redirect can forward the bearer
        // credential (or Ollama's model identifier) to a destination that was
        // never classified or consented, so expose the 3xx response instead of
        // following it. This is the same fail-closed policy as inference.
        let (data, response) = try await URLSession.shared.data(
            for: request,
            delegate: AttacheNoRedirectDelegate()
        )
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelDiscoveryError.invalidResponse(providerName)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ModelDiscoveryError.httpStatus(providerName, httpResponse.statusCode, String(body.prefix(240)))
        }
        return data
    }

    static func parseXAILanguageModels(_ data: Data) throws -> [AttachePresentationModelOption] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            throw ModelDiscoveryError.invalidPayload("xAI")
        }

        return models.compactMap { model in
            guard let id = model["id"] as? String, !id.isEmpty else { return nil }
            guard supportsXAIChatCompletions(modelID: id) else { return nil }
            let liveEfforts = reasoningEfforts(in: model, provider: .xai, modelID: id)
            let documented = documentedXAICapability(for: id)
            // xAI's team-scoped catalog is authoritative for availability, but
            // its current list response omits window and reasoning fields. Use
            // a versioned, exact-ID catalog derived from xAI's public model
            // pages only when those live fields are absent. Any future catalog
            // fields override the bundled record immediately.
            let efforts = liveEfforts.isEmpty ? (documented?.reasoningLevels ?? []) : liveEfforts
            let liveProfile = hostedCapabilityProfile(model, reasoningEfforts: liveEfforts)
            let capability = mergedXAICapability(
                live: liveProfile,
                liveEfforts: liveEfforts,
                documented: documented,
                effectiveEfforts: efforts
            )
            let aliases = (model["aliases"] as? [String] ?? []).filter { !$0.isEmpty }
            let modalities = [model["input_modalities"], model["output_modalities"]]
                .compactMap { $0 as? [String] }
                .flatMap { $0 }
                .filter { !$0.isEmpty }
            let detailParts = [
                aliases.isEmpty ? nil : "aliases \(aliases.joined(separator: ", "))",
                modalities.isEmpty ? nil : modalities.uniqued().joined(separator: "/")
            ].compactMap { $0 }
            return AttachePresentationModelOption(
                id: id,
                detail: detailParts.joined(separator: " / "),
                // xAI's live catalog is authoritative for which models exist,
                // but its published schema does not include reasoning levels.
                // Prefer any future advertised levels, then use the documented
                // capability table for known model families.
                reasoningEfforts: efforts,
                serviceTiers: serviceTiers(in: model, provider: .xai, modelID: id),
                capabilityProfile: capability
            )
        }
        .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    private static func parseOpenAIModels(_ data: Data, provider: AttachePresentationProvider) throws -> [AttachePresentationModelOption] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["data"] as? [[String: Any]] else {
            throw ModelDiscoveryError.invalidPayload(provider.title)
        }

        return models.compactMap { model in
            guard let id = model["id"] as? String, !id.isEmpty else { return nil }
            if provider == .xai, !supportsXAIChatCompletions(modelID: id) { return nil }
            let owner = model["owned_by"] as? String ?? ""
            let liveEfforts = reasoningEfforts(in: model, provider: provider, modelID: id)
            let documented = provider == .xai ? documentedXAICapability(for: id) : nil
            let efforts = liveEfforts.isEmpty ? (documented?.reasoningLevels ?? []) : liveEfforts
            let liveProfile = hostedCapabilityProfile(model, reasoningEfforts: liveEfforts)
            let capability = provider == .xai
                ? mergedXAICapability(
                    live: liveProfile,
                    liveEfforts: liveEfforts,
                    documented: documented,
                    effectiveEfforts: efforts
                )
                : hostedCapabilityProfile(model, reasoningEfforts: efforts)
            return AttachePresentationModelOption(
                id: id,
                detail: owner,
                reasoningEfforts: efforts,
                serviceTiers: serviceTiers(in: model, provider: provider, modelID: id),
                capabilityProfile: capability
            )
        }
        .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    private static func parseOllamaTags(_ data: Data) throws -> [AttachePresentationModelOption] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            throw ModelDiscoveryError.invalidPayload("Ollama")
        }

        return models.compactMap { model in
            let name = (model["name"] as? String) ?? (model["model"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            let detail = (model["details"] as? [String: Any])?["parameter_size"] as? String ?? ""
            return AttachePresentationModelOption(
                id: name,
                detail: detail,
                reasoningEfforts: []
            )
        }
        .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    static func parseOllamaShowReasoningEfforts(_ data: Data, modelID: String) throws -> [String] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelDiscoveryError.invalidPayload("Ollama")
        }
        let capabilities = (root["capabilities"] as? [String] ?? []).map { $0.lowercased() }
        guard capabilities.contains("thinking") else { return [] }

        let details = root["details"] as? [String: Any]
        let family = details?["family"] as? String ?? ""
        let families = details?["families"] as? [String] ?? []
        let identity = ([modelID, family] + families)
            .joined(separator: " ")
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        if identity.contains("gpt-oss") || identity.contains("gptoss") {
            return ["low", "medium", "high"]
        }
        // Ollama's OpenAI-compatible endpoint accepts these reasoning_effort
        // values for thinking-capable models. `/api/show` remains the source of
        // truth for whether the selected installed model can think at all.
        return ["none", "low", "medium", "high"]
    }

    static func fallbackReasoningEfforts(provider: AttachePresentationProvider, modelID: String) -> [String] {
        switch provider {
        case .xai:
            return documentedXAICapability(for: modelID)?.reasoningLevels ?? []
        case .groq, .custom:
            // Hosted model names never imply capability. The selected model's
            // live catalog metadata is the only authority.
            return []
        case .claudeCLI:
            return ["default", "low", "medium", "high", "xhigh", "max"]
        case .codexCLI:
            // Codex accepts this setting even when a newly released or custom
            // model has not appeared in its local capability cache yet. Keep a
            // saved choice instead of silently replacing it with `none`.
            return ["default", "low", "medium", "high", "xhigh"]
        case .ollama:
            return []
        }
    }

    static func preferredReasoningEffort(
        provider: AttachePresentationProvider,
        modelID: String,
        supported: [String]
    ) -> String {
        guard !supported.isEmpty else { return "none" }
        let normalizedID = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if provider == .xai,
           (normalizedID == "grok-4.5" || normalizedID.hasPrefix("grok-4.5-")),
           supported.contains("high") {
            return "high"
        }
        if provider == .ollama {
            if supported == ["none", "high"] { return "high" }
            if supported.contains("medium") { return "medium" }
        }
        if supported.contains("default") { return "default" }
        if supported.contains(provider.defaultReasoningEffort) {
            return provider.defaultReasoningEffort
        }
        return supported[0]
    }

    static func fallbackServiceTierOptions(provider: AttachePresentationProvider, modelID: String) -> [AttachePresentationServiceTierOption] {
        switch provider {
        case .xai:
            return [
                AttachePresentationServiceTierOption(id: "default", title: "Default", detail: "Use xAI's default processing tier"),
                AttachePresentationServiceTierOption(id: "priority", title: "Priority", detail: "Request priority processing")
            ]
        case .groq:
            return [
                AttachePresentationServiceTierOption(id: "default", title: "Default", detail: "Use Groq's default tier"),
                AttachePresentationServiceTierOption(id: "auto", title: "Auto", detail: "Let Groq choose the best available tier"),
                AttachePresentationServiceTierOption(id: "on_demand", title: "On demand", detail: "Standard Groq processing"),
                AttachePresentationServiceTierOption(id: "flex", title: "Flex", detail: "Best-effort high-throughput processing"),
                AttachePresentationServiceTierOption(id: "performance", title: "Performance", detail: "Enterprise low-latency tier")
            ]
        case .codexCLI:
            return []
        case .custom:
            let normalizedID = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalizedID.hasPrefix("gpt-5") else { return [] }
            return [
                AttachePresentationServiceTierOption(id: "default", title: "Default", detail: "Use the project default tier"),
                AttachePresentationServiceTierOption(id: "flex", title: "Flex", detail: "Lower-cost flex processing"),
                AttachePresentationServiceTierOption(id: "priority", title: "Priority", detail: "Priority processing")
            ]
        case .ollama, .claudeCLI:
            return []
        }
    }

    private static func reasoningEfforts(
        in model: [String: Any],
        provider: AttachePresentationProvider,
        modelID: String
    ) -> [String] {
        _ = provider
        _ = modelID
        // Hosted providers are the authority for a discovered model. A model
        // name is not a capability contract, so a newly released alias must not
        // inherit a hard-coded reasoning menu from a similarly named model.
        // Local CLI catalogs and Ollama's /api/show path attach their own
        // explicit levels before reaching this helper.
        return advertisedReasoningEfforts(in: model)
    }

    private static func hostedCapabilityProfile(
        _ model: [String: Any],
        reasoningEfforts: [String]
    ) -> AttacheModelCapabilityProfile {
        let parsed = AttacheCapabilityParser.parseHostedModel(model) ?? .unknown
        return AttacheModelCapabilityProfile(
            architecturalMaximum: parsed.architecturalMaximum,
            configuredRuntimeLimit: parsed.configuredRuntimeLimit,
            outputLimit: parsed.outputLimit,
            estimatorFamily: parsed.estimatorFamily,
            supportsReasoning: !reasoningEfforts.isEmpty,
            reasoningLevels: reasoningEfforts,
            freshness: parsed.freshness,
            confidence: reasoningEfforts.isEmpty ? parsed.confidence : .authoritative,
            provenance: reasoningEfforts.isEmpty ? parsed.provenance : .providerMetadata
        )
    }

    /// Exact xAI model records verified against xAI's public model pages on
    /// 2026-07-16. This table supplements, but never replaces, fields returned
    /// by the authenticated xAI catalog. Keep unknown future IDs unknown.
    private static func documentedXAICapability(for modelID: String) -> AttacheModelCapabilityProfile? {
        let verifiedAt = Date(timeIntervalSince1970: 1_784_160_000)
        switch modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "grok-4.3":
            return AttacheModelCapabilityProfile(
                architecturalMaximum: 1_000_000,
                supportsReasoning: true,
                reasoningLevels: ["none", "low", "medium", "high"],
                freshness: verifiedAt,
                confidence: .authoritative,
                provenance: .curatedFallback
            )
        case "grok-4.5":
            return AttacheModelCapabilityProfile(
                architecturalMaximum: 500_000,
                supportsReasoning: true,
                reasoningLevels: ["low", "medium", "high"],
                freshness: verifiedAt,
                confidence: .authoritative,
                provenance: .curatedFallback
            )
        case "grok-build-0.1":
            return AttacheModelCapabilityProfile(
                architecturalMaximum: 256_000,
                supportsReasoning: true,
                freshness: verifiedAt,
                confidence: .authoritative,
                provenance: .curatedFallback
            )
        case "grok-4.20-0309-reasoning":
            return AttacheModelCapabilityProfile(
                architecturalMaximum: 1_000_000,
                supportsReasoning: true,
                freshness: verifiedAt,
                confidence: .authoritative,
                provenance: .curatedFallback
            )
        case "grok-4.20-0309-non-reasoning":
            return AttacheModelCapabilityProfile(
                architecturalMaximum: 1_000_000,
                supportsReasoning: false,
                freshness: verifiedAt,
                confidence: .authoritative,
                provenance: .curatedFallback
            )
        default:
            return nil
        }
    }

    private static func mergedXAICapability(
        live: AttacheModelCapabilityProfile,
        liveEfforts: [String],
        documented: AttacheModelCapabilityProfile?,
        effectiveEfforts: [String]
    ) -> AttacheModelCapabilityProfile {
        guard let documented else { return live }
        let hasLiveFacts = live.architecturalMaximum != nil
            || live.configuredRuntimeLimit != nil
            || live.outputLimit != nil
            || !liveEfforts.isEmpty
        guard hasLiveFacts else { return documented }

        let usesDocumentedCapacity = live.architecturalMaximum == nil
            && live.configuredRuntimeLimit == nil
            && documented.declaredInputCeiling != nil

        return AttacheModelCapabilityProfile(
            architecturalMaximum: live.architecturalMaximum ?? documented.architecturalMaximum,
            configuredRuntimeLimit: live.configuredRuntimeLimit ?? documented.configuredRuntimeLimit,
            outputLimit: live.outputLimit ?? documented.outputLimit,
            estimatorFamily: live.estimatorFamily ?? documented.estimatorFamily,
            supportsReasoning: !effectiveEfforts.isEmpty || documented.supportsReasoning,
            reasoningLevels: effectiveEfforts,
            freshness: usesDocumentedCapacity ? documented.freshness : live.freshness,
            confidence: .authoritative,
            provenance: usesDocumentedCapacity ? .curatedFallback : .providerMetadata
        )
    }

    /// Attaché currently sends xAI turns through `/v1/chat/completions`.
    /// xAI's multi-agent models are Responses-API-only, so showing them would
    /// create a configuration that can never complete successfully.
    private static func supportsXAIChatCompletions(modelID: String) -> Bool {
        !modelID.lowercased().contains("multi-agent")
    }

    private static func advertisedReasoningEfforts(in model: [String: Any]) -> [String] {
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
        return []
    }

    private static func serviceTiers(
        in model: [String: Any],
        provider: AttachePresentationProvider,
        modelID: String
    ) -> [AttachePresentationServiceTierOption] {
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

    private static func serviceTierValues(in value: Any?) -> [AttachePresentationServiceTierOption] {
        if let values = value as? [String] {
            return values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .uniqued()
                .map { AttachePresentationServiceTierOption(id: $0, title: serviceTierTitle($0), detail: "") }
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
                return AttachePresentationServiceTierOption(id: id, title: title.isEmpty ? serviceTierTitle(id) : title, detail: detail)
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
