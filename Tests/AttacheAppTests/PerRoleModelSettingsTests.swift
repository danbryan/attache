import XCTest
@testable import AttacheApp

/// INF-247 (D2): `AttachePresentationSettings.load(role:)` lets each LLM
/// consumer (conversation/presentation/recap/tagging) pick its own
/// provider/model while falling back to the existing global
/// `presentationLLM*` keys when a role hasn't been overridden. These tests
/// cover the guarantees the ticket calls out: with no per-role key ever set
/// every role resolves identically to the pre-INF-247 global-only behavior
/// (the regression gate), a role-specific override only ever changes the one
/// field it targets, one role's override never leaks into another's, and the
/// `ATTACHE_LLM_*` / `COMPANION_LLM_*` environment overrides keep winning for
/// every role, not just one.
final class PerRoleModelSettingsTests: XCTestCase {
    private func makeIsolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "PerRoleModelSettingsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create isolated defaults for per-role settings test")
            return (UserDefaults.standard, suiteName)
        }
        return (defaults, suiteName)
    }

    func testRoleKeyNamingMatchesTheDocumentedShape() {
        XCTAssertEqual(
            AttachePreferenceKey.presentationLLMRoleKey(.recap, .provider),
            "attache.presentationLLM.recap.provider"
        )
        XCTAssertEqual(
            AttachePreferenceKey.presentationLLMRoleKey(.recap, .model),
            "attache.presentationLLM.recap.model"
        )
        XCTAssertEqual(
            AttachePreferenceKey.presentationLLMRoleKey(.conversation, .apiKeySecretRef),
            "attache.presentationLLM.conversation.apiKeySecretRef"
        )
    }

    /// Regression gate: with no per-role keys set anywhere, every role must
    /// resolve to exactly the settings the old global-only
    /// `load(defaults:environment:resolveSecrets:)` produced. Groq is chosen
    /// because it's the one bundled provider that exercises every field
    /// (requires an API key, supports both reasoning effort and service
    /// tier), so this pins the full field set, not just model/provider.
    func testNoRoleKeysSetIsByteForByteIdenticalAcrossAllRoles() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AttachePresentationProvider.groq.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        defaults.set("global-model-x", forKey: AttachePreferenceKey.presentationLLMModel)
        defaults.set("high", forKey: AttachePreferenceKey.presentationReasoningEffort)
        defaults.set("priority", forKey: AttachePreferenceKey.presentationServiceTier)
        defaults.set("global-api-key", forKey: AttachePreferenceKey.presentationLLMAPIKey)

        let results = ModelRole.allCases.map {
            AttachePresentationSettings.load(role: $0, defaults: defaults, environment: [:], resolveSecrets: false)
        }

        for settings in results {
            XCTAssertEqual(settings.provider, .groq)
            XCTAssertEqual(settings.model, "global-model-x")
            XCTAssertEqual(settings.reasoningEffort, "high")
            XCTAssertEqual(settings.serviceTier, "priority")
            XCTAssertEqual(settings.apiKey, "global-api-key")
            XCTAssertEqual(settings.baseURL.absoluteString, AttachePresentationProvider.groq.defaultBaseURL)
        }
        for settings in results.dropFirst() {
            XCTAssertEqual(settings, results[0], "every role must resolve identically when no role key is set")
        }
    }

    /// Same regression gate, but for the "nothing configured at all" case
    /// (defaults untouched): every role must fall back to the same
    /// provider-default settings (ollama, unconfigured until a key is set).
    func testNoKeysAtAllStillMatchesAcrossRoles() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let results = ModelRole.allCases.map {
            AttachePresentationSettings.load(role: $0, defaults: defaults, environment: [:], resolveSecrets: false)
        }
        for settings in results.dropFirst() {
            XCTAssertEqual(settings, results[0])
        }
        XCTAssertEqual(results[0].provider, .ollama)
        XCTAssertEqual(results[0].model, AttachePresentationProvider.ollama.defaultModel)
    }

    /// A role-specific key set for ONE field (just the model) still falls
    /// back to the global key for every other field (provider, API key).
    func testRoleSpecificFieldOverrideOnlyChangesThatField() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AttachePresentationProvider.groq.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        defaults.set("global-model", forKey: AttachePreferenceKey.presentationLLMModel)
        defaults.set("global-api-key", forKey: AttachePreferenceKey.presentationLLMAPIKey)

        // Only recap's model is overridden.
        defaults.set("recap-only-model", forKey: AttachePreferenceKey.presentationLLMRoleKey(.recap, .model))

        let recap = AttachePresentationSettings.load(role: .recap, defaults: defaults, environment: [:], resolveSecrets: false)
        XCTAssertEqual(recap.model, "recap-only-model", "the role-specific model key should win")
        XCTAssertEqual(recap.provider, .groq, "provider should still fall back to the global key")
        XCTAssertEqual(recap.apiKey, "global-api-key", "api key should still fall back to the global key")

        for role in ModelRole.allCases where role != .recap {
            let settings = AttachePresentationSettings.load(role: role, defaults: defaults, environment: [:], resolveSecrets: false)
            XCTAssertEqual(settings.model, "global-model", "\(role) must not see recap's model override")
            XCTAssertEqual(settings.provider, .groq)
            XCTAssertEqual(settings.apiKey, "global-api-key")
        }
    }

    /// Role isolation both ways: overriding recap's provider/model does not
    /// leak into conversation (or any other role), and vice versa.
    func testRoleIsolationIsSymmetric() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AttachePresentationProvider.ollama.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        defaults.set("global-model", forKey: AttachePreferenceKey.presentationLLMModel)

        defaults.set(AttachePresentationProvider.groq.rawValue, forKey: AttachePreferenceKey.presentationLLMRoleKey(.recap, .provider))
        defaults.set("recap-model", forKey: AttachePreferenceKey.presentationLLMRoleKey(.recap, .model))

        let recap = AttachePresentationSettings.load(role: .recap, defaults: defaults, environment: [:], resolveSecrets: false)
        XCTAssertEqual(recap.provider, .groq)
        XCTAssertEqual(recap.model, "recap-model")

        for role: ModelRole in [.conversation, .presentation, .tagging] {
            let settings = AttachePresentationSettings.load(role: role, defaults: defaults, environment: [:], resolveSecrets: false)
            XCTAssertEqual(settings.provider, .ollama, "\(role) must not see recap's provider override")
            XCTAssertEqual(settings.model, "global-model", "\(role) must not see recap's model override")
        }

        // And the other direction: overriding conversation must not move recap.
        defaults.set(AttachePresentationProvider.custom.rawValue, forKey: AttachePreferenceKey.presentationLLMRoleKey(.conversation, .provider))
        defaults.set("conversation-model", forKey: AttachePreferenceKey.presentationLLMRoleKey(.conversation, .model))

        let recapAfter = AttachePresentationSettings.load(role: .recap, defaults: defaults, environment: [:], resolveSecrets: false)
        XCTAssertEqual(recapAfter.provider, .groq, "recap's override must survive conversation being overridden too")
        XCTAssertEqual(recapAfter.model, "recap-model")
    }

    /// The `ATTACHE_LLM_*` / `COMPANION_LLM_*` env overrides stay global: they
    /// must win over both a role-specific key and the global default key,
    /// for every role, so smoke scripts setting one env var still affect all
    /// four consumers.
    func testEnvironmentOverrideWinsForEveryRole() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AttachePresentationProvider.ollama.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        defaults.set("global-model", forKey: AttachePreferenceKey.presentationLLMModel)
        for role in ModelRole.allCases {
            defaults.set(AttachePresentationProvider.groq.rawValue, forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .provider))
            defaults.set("role-model-\(role.rawValue)", forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .model))
        }

        let environment = [
            "ATTACHE_LLM_PROVIDER": "xai",
            "ATTACHE_LLM_MODEL": "env-model-wins"
        ]

        for role in ModelRole.allCases {
            let settings = AttachePresentationSettings.load(role: role, defaults: defaults, environment: environment, resolveSecrets: false)
            XCTAssertEqual(settings.provider, .xai, "\(role) should honor the env override over its own role key and the global key")
            XCTAssertEqual(settings.model, "env-model-wins", "\(role) should honor the env override over its own role key and the global key")
        }
    }

    /// The legacy `COMPANION_LLM_*` alias must win too, and still for every role.
    func testLegacyEnvironmentAliasAlsoWinsForEveryRole() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for role in ModelRole.allCases {
            defaults.set("role-model-\(role.rawValue)", forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .model))
        }
        let environment = ["COMPANION_LLM_MODEL": "legacy-env-model"]

        for role in ModelRole.allCases {
            let settings = AttachePresentationSettings.load(role: role, defaults: defaults, environment: environment, resolveSecrets: false)
            XCTAssertEqual(settings.model, "legacy-env-model")
        }
    }
}
