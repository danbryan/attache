import Foundation

/// Shared, pure classifier that decides whether a session is running on a
/// local (non-cloud) model, and if so returns the raw model tag for the UI
/// badge tooltip (INF-398, follow-up to INF-363). Every session scanner routes
/// its per-source model evidence through this one function so the
/// local-model badge means the same thing across Claude Code, opencode, and any
/// future source, rather than each scanner re-deriving the rule.
///
/// Two evidence shapes are supported by the one entry point:
///
/// - Sources that report an explicit provider id (opencode: each message's
///   `data.model.providerID` + `data.model.modelID`). The provider id is the
///   primary signal: `ollama`/`lmstudio`/`localhost`-shaped providers are
///   local, `anthropic`/`openai`/`xai`/etc. are cloud. A local provider whose
///   model tag is suffixed `:cloud` (e.g. Ollama's `glm-5.2:cloud`) is proxied
///   cloud inference and is NOT local.
///
/// - Sources that report only a model id, no provider (Claude Code: an
///   assistant record's `message.model`). A cloud Claude session carries a
///   `claude-*` id; anything else non-empty is treated as local-model evidence
///   and returned verbatim. This preserves `ClaudeCodeSessionScanner`'s
///   original behavior byte-for-byte.
public enum LocalModelHint {
    /// Provider ids that denote a local / self-hosted inference engine.
    private static let localProviderIDs: Set<String> = [
        "ollama", "lmstudio", "lm-studio", "llamacpp", "llama.cpp", "localhost"
    ]

    /// Returns the raw model tag when the evidence points to a local model,
    /// otherwise nil (cloud session, or no usable evidence).
    ///
    /// - Parameters:
    ///   - providerID: the source's provider id, or nil for model-id-only
    ///     sources (Claude Code).
    ///   - modelID: the model tag/id, or nil when absent.
    public static func classify(providerID: String?, modelID: String?) -> String? {
        let provider = (providerID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (modelID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Provider-keyed path (opencode and any future explicit-provider source).
        if !provider.isEmpty {
            guard isLocalProvider(provider) else { return nil } // named cloud provider
            // A local-engine model tag suffixed `:cloud` is proxied cloud
            // inference, not local (Ollama's cloud tier: `glm-5.2:cloud`).
            if model.lowercased().hasSuffix(":cloud") { return nil }
            return model.isEmpty ? provider : model
        }

        // Model-id-only path (Claude Code). Absent field or a `claude-*` id
        // yields nil; any other non-empty tag is local-model evidence.
        guard !model.isEmpty else { return nil }
        guard !model.lowercased().hasPrefix("claude") else { return nil }
        return model
    }

    private static func isLocalProvider(_ provider: String) -> Bool {
        let lower = provider.lowercased()
        if localProviderIDs.contains(lower) { return true }
        // Custom/self-hosted opencode providers can carry a host-shaped id.
        if lower.contains("localhost") || lower.contains("127.0.0.1") { return true }
        return false
    }
}
