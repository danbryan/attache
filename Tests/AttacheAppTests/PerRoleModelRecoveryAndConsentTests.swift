import XCTest
import AppKit
import AttacheCore
@testable import AttacheApp

/// INF-247 (D2): two behavior changes that only show up through `AppModel`,
/// not through `AttachePresentationSettings.load(role:)` directly.
///
/// 1. The Switch-model recovery action after a conversation failure
///    (`selectConversationRecoveryProvider`/`selectConversationRecoveryModel`)
///    must persist to the `conversation` role's per-role keys, never the
///    global `presentationLLM*` keys presentation/recap/tagging fall back to.
/// 2. Cloud consent is tracked per provider, normalized endpoint, and egress
///    class. Legacy provider-only consent is migrated to the endpoint configured
///    at migration time, and that migration never re-runs.
///
/// `AppModel`'s only initializer reads `UserDefaults.standard` directly (no
/// injectable defaults), so these tests follow the same pattern already used
/// by `AppModelAgentInstructionSendTests`: touch real `UserDefaults.standard`,
/// but snapshot and restore every key touched.
@MainActor
final class PerRoleModelRecoveryAndConsentTests: XCTestCase {
    private let preferenceKeys = [
        AttachePreferenceKey.presentationLLMEnabled,
        AttachePreferenceKey.presentationLLMProvider,
        AttachePreferenceKey.presentationLLMBaseURL,
        AttachePreferenceKey.presentationLLMModel,
        AttachePreferenceKey.presentationReasoningEffort,
        AttachePreferenceKey.presentationServiceTier,
        AttachePreferenceKey.presentationLLMAPIKey,
        AttachePreferenceKey.presentationLLMAPIKeySecretRef,
        AttachePreferenceKey.configuredSecretAccounts,
        AttachePreferenceKey.cloudConsentPresentation,
        AttachePreferenceKey.cloudConsentPresentationProviders,
        AttachePreferenceKey.cloudConsentPresentationMigrationDone,
        AttachePreferenceKey.cloudConsentVoice,
        AttachePreferenceKey.cloudConsentVoiceScopes,
        AttachePreferenceKey.cloudConsentVoiceMigrationDone,
        AttachePreferenceKey.speechProvider,
        AttachePreferenceKey.xaiBaseURL,
        AttachePreferenceKey.ollamaBaseURL,
        AttachePreferenceKey.customBaseURL,
        AttachePreferenceKey.onboardingCompleted,
        AttachePreferenceKey.presentationLLMRoleKey(.conversation, .provider),
        AttachePreferenceKey.presentationLLMRoleKey(.conversation, .baseURL),
        AttachePreferenceKey.presentationLLMRoleKey(.conversation, .model),
        AttachePreferenceKey.presentationLLMRoleKey(.conversation, .reasoningEffort),
        AttachePreferenceKey.presentationLLMRoleKey(.conversation, .serviceTier),
        AttachePreferenceKey.presentationLLMRoleKey(.conversation, .apiKeySecretRef)
    ]

    func testConversationRecoverySwitchWritesConversationRoleKeysNotGlobalKeys() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        defaults.set(AttachePresentationProvider.ollama.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        defaults.set("original-global-model", forKey: AttachePreferenceKey.presentationLLMModel)

        let model = try AppModel(store: CardStore.inMemory())
        XCTAssertEqual(model.presentationProvider, .ollama)

        model.selectConversationRecoveryProvider(.groq)

        XCTAssertEqual(model.presentationProvider, .groq, "in-memory state should reflect the switch for the recovery menu and confirmation text")
        XCTAssertEqual(
            defaults.string(forKey: AttachePreferenceKey.presentationLLMRoleKey(.conversation, .provider)),
            AttachePresentationProvider.groq.rawValue,
            "the switch must persist to the conversation role's key"
        )
        XCTAssertEqual(
            defaults.string(forKey: AttachePreferenceKey.presentationLLMProvider),
            AttachePresentationProvider.ollama.rawValue,
            "the global provider key must be untouched by a conversation-only recovery switch"
        )
        XCTAssertEqual(
            defaults.string(forKey: AttachePreferenceKey.presentationLLMModel),
            "original-global-model",
            "the global model key must be untouched by a conversation-only recovery switch"
        )

        // presentation/recap/tagging must still resolve to the pre-switch
        // global config; only conversation should see the recovered provider.
        for role: ModelRole in [.presentation, .recap, .tagging] {
            let settings = AttachePresentationSettings.load(role: role, defaults: defaults, environment: [:], resolveSecrets: false)
            XCTAssertEqual(settings.provider, .ollama, "\(role) must not be affected by a conversation recovery switch")
        }
        let conversationSettings = AttachePresentationSettings.load(role: .conversation, defaults: defaults, environment: [:], resolveSecrets: false)
        XCTAssertEqual(conversationSettings.provider, .groq, "conversation should pick up the recovered provider on the next call")
    }

    func testConversationRecoveryModelSwitchAlsoWritesConversationRoleKey() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        defaults.set(AttachePresentationProvider.groq.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        defaults.set("original-global-model", forKey: AttachePreferenceKey.presentationLLMModel)

        let model = try AppModel(store: CardStore.inMemory())
        model.selectConversationRecoveryModel(AttachePresentationModelOption(id: "recovered-model", detail: "test", reasoningEfforts: []))

        XCTAssertEqual(
            defaults.string(forKey: AttachePreferenceKey.presentationLLMRoleKey(.conversation, .model)),
            "recovered-model"
        )
        XCTAssertEqual(
            defaults.string(forKey: AttachePreferenceKey.presentationLLMModel),
            "original-global-model",
            "the global model key must be untouched by a conversation-only recovery switch"
        )
    }

    func testCloudConsentMigrationCreditsTheCurrentProviderOnce() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        defaults.set(AttachePresentationProvider.xai.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        defaults.set(true, forKey: AttachePreferenceKey.cloudConsentPresentation)

        let model = try AppModel(store: CardStore.inMemory())

        XCTAssertTrue(
            model.cloudConsentAcknowledged(for: .xai),
            "the legacy true flag should migrate onto the provider configured at migration time"
        )
        XCTAssertFalse(
            model.cloudConsentAcknowledged(for: .groq),
            "migration must not blanket-consent every cloud provider"
        )
        XCTAssertTrue(defaults.bool(forKey: AttachePreferenceKey.cloudConsentPresentationMigrationDone))
    }

    func testCloudConsentMigrationDoesNotRunWhenLegacyFlagWasNeverSet() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        defaults.set(AttachePresentationProvider.xai.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)

        let model = try AppModel(store: CardStore.inMemory())

        XCTAssertFalse(model.cloudConsentAcknowledged(for: .xai))
        XCTAssertTrue(defaults.bool(forKey: AttachePreferenceKey.cloudConsentPresentationMigrationDone), "migration should still mark itself done so it never re-checks the legacy flag")
    }

    func testCloudConsentMigrationIsIdempotentAndNeverReRuns() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        defaults.set(AttachePresentationProvider.xai.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        defaults.set(true, forKey: AttachePreferenceKey.cloudConsentPresentation)

        let firstLaunch = try AppModel(store: CardStore.inMemory())
        let migrated = defaults.array(forKey: AttachePreferenceKey.cloudConsentPresentationProviders) as? [String]
        XCTAssertEqual(migrated?.count, 1)
        XCTAssertTrue(migrated?.first?.hasPrefix("v2|xai|") == true)
        XCTAssertTrue(firstLaunch.cloudConsentAcknowledged(for: .xai))

        // Revoke consent and switch the configured provider, then relaunch:
        // since migration already ran once, the stale legacy `true` flag
        // must not silently re-grant consent for the new provider.
        defaults.set([String](), forKey: AttachePreferenceKey.cloudConsentPresentationProviders)
        defaults.set(AttachePresentationProvider.groq.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)

        let secondLaunch = try AppModel(store: CardStore.inMemory())
        XCTAssertFalse(secondLaunch.cloudConsentAcknowledged(for: .groq), "migration must not re-run on a later launch")
        XCTAssertFalse(secondLaunch.cloudConsentAcknowledged(for: .xai), "the explicit revocation above must stick")
    }

    func testCustomEndpointChangeRequiresFreshConsent() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        defaults.set(AttachePresentationProvider.custom.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        defaults.set("https://first.example/v1", forKey: AttachePreferenceKey.customBaseURL)

        let model = try AppModel(store: CardStore.inMemory())
        model.acknowledgeCloudConsent(for: .custom)
        XCTAssertTrue(model.cloudConsentAcknowledged(for: .custom))

        model.customBaseURL = "https://second.example/v1"
        XCTAssertFalse(
            model.cloudConsentAcknowledged(for: .custom),
            "consent for one Custom destination must not authorize another"
        )
    }

    func testEquivalentCustomEndpointKeepsConsent() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        defaults.set(AttachePresentationProvider.custom.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        defaults.set("HTTPS://Example.COM:443/v1/", forKey: AttachePreferenceKey.customBaseURL)

        let model = try AppModel(store: CardStore.inMemory())
        model.acknowledgeCloudConsent(for: .custom)
        model.customBaseURL = "https://example.com/v1"

        XCTAssertTrue(
            model.cloudConsentAcknowledged(for: .custom),
            "cosmetic URL spelling changes must not cause repeated consent prompts"
        )
    }

    func testRemoteToLoopbackEndpointChangesConsentScopeAndEgress() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        defaults.set(AttachePresentationProvider.custom.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        defaults.set("https://remote.example/v1", forKey: AttachePreferenceKey.customBaseURL)

        let model = try AppModel(store: CardStore.inMemory())
        model.acknowledgeCloudConsent(for: .custom)
        XCTAssertTrue(model.presentationProviderSendsToCloud(.custom))

        model.customBaseURL = "http://127.0.0.1:11434/v1"
        XCTAssertFalse(model.presentationProviderSendsToCloud(.custom))
        XCTAssertFalse(
            model.cloudConsentAcknowledged(for: .custom),
            "the storage scope must reflect the current endpoint and egress class"
        )
    }

    func testLegacyVoiceConsentDoesNotBlessNonstandardImportedXAIEndpoint() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        defaults.set(AttacheSpeechProvider.xai.rawValue, forKey: AttachePreferenceKey.speechProvider)
        defaults.set("https://credential-exfil.example/v1", forKey: AttachePreferenceKey.xaiBaseURL)
        defaults.set(true, forKey: AttachePreferenceKey.cloudConsentVoice)

        let model = try AppModel(store: CardStore.inMemory())

        XCTAssertFalse(
            model.cloudVoiceConsentAcknowledged(
                for: .xai,
                xaiBaseURL: "https://credential-exfil.example/v1"
            )
        )
        XCTAssertTrue(defaults.bool(forKey: AttachePreferenceKey.cloudConsentVoiceMigrationDone))
    }
}

private final class DefaultsSnapshot {
    private let keys: [String]
    private let defaults: UserDefaults
    private let values: [String: Any]

    init(keys: [String], defaults: UserDefaults) {
        self.keys = keys
        self.defaults = defaults
        self.values = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        })
        keys.forEach { defaults.removeObject(forKey: $0) }
    }

    func restore() {
        keys.forEach { defaults.removeObject(forKey: $0) }
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
    }
}
