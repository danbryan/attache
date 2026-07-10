import XCTest
import AppKit
import AttacheCore
@testable import AttacheApp

/// INF-247 (D2): two behavior changes that only show up through `AppModel`,
/// not through `CompanionPresentationSettings.load(role:)` directly.
///
/// 1. The Switch-model recovery action after a conversation failure
///    (`selectConversationRecoveryProvider`/`selectConversationRecoveryModel`)
///    must persist to the `conversation` role's per-role keys, never the
///    global `presentationLLM*` keys presentation/recap/tagging fall back to.
/// 2. Cloud consent is tracked per provider, migrated once from the legacy
///    single `cloudConsentPresentation` flag onto whatever provider was
///    configured at migration time, and that migration never re-runs.
///
/// `AppModel`'s only initializer reads `UserDefaults.standard` directly (no
/// injectable defaults), so these tests follow the same pattern already used
/// by `AppModelAgentInstructionSendTests`: touch real `UserDefaults.standard`,
/// but snapshot and restore every key touched.
@MainActor
final class PerRoleModelRecoveryAndConsentTests: XCTestCase {
    private let preferenceKeys = [
        CompanionPreferenceKey.presentationLLMEnabled,
        CompanionPreferenceKey.presentationLLMProvider,
        CompanionPreferenceKey.presentationLLMBaseURL,
        CompanionPreferenceKey.presentationLLMModel,
        CompanionPreferenceKey.presentationReasoningEffort,
        CompanionPreferenceKey.presentationServiceTier,
        CompanionPreferenceKey.presentationLLMAPIKey,
        CompanionPreferenceKey.presentationLLMAPIKeySecretRef,
        CompanionPreferenceKey.configuredSecretAccounts,
        CompanionPreferenceKey.cloudConsentPresentation,
        CompanionPreferenceKey.cloudConsentPresentationProviders,
        CompanionPreferenceKey.cloudConsentPresentationMigrationDone,
        CompanionPreferenceKey.onboardingCompleted,
        CompanionPreferenceKey.presentationLLMRoleKey(.conversation, .provider),
        CompanionPreferenceKey.presentationLLMRoleKey(.conversation, .baseURL),
        CompanionPreferenceKey.presentationLLMRoleKey(.conversation, .model),
        CompanionPreferenceKey.presentationLLMRoleKey(.conversation, .reasoningEffort),
        CompanionPreferenceKey.presentationLLMRoleKey(.conversation, .serviceTier),
        CompanionPreferenceKey.presentationLLMRoleKey(.conversation, .apiKeySecretRef)
    ]

    func testConversationRecoverySwitchWritesConversationRoleKeysNotGlobalKeys() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        defaults.set(CompanionPresentationProvider.ollama.rawValue, forKey: CompanionPreferenceKey.presentationLLMProvider)
        defaults.set("original-global-model", forKey: CompanionPreferenceKey.presentationLLMModel)

        let model = try AppModel(store: CardStore.inMemory())
        XCTAssertEqual(model.presentationProvider, .ollama)

        model.selectConversationRecoveryProvider(.groq)

        XCTAssertEqual(model.presentationProvider, .groq, "in-memory state should reflect the switch for the recovery menu and confirmation text")
        XCTAssertEqual(
            defaults.string(forKey: CompanionPreferenceKey.presentationLLMRoleKey(.conversation, .provider)),
            CompanionPresentationProvider.groq.rawValue,
            "the switch must persist to the conversation role's key"
        )
        XCTAssertEqual(
            defaults.string(forKey: CompanionPreferenceKey.presentationLLMProvider),
            CompanionPresentationProvider.ollama.rawValue,
            "the global provider key must be untouched by a conversation-only recovery switch"
        )
        XCTAssertEqual(
            defaults.string(forKey: CompanionPreferenceKey.presentationLLMModel),
            "original-global-model",
            "the global model key must be untouched by a conversation-only recovery switch"
        )

        // presentation/recap/tagging must still resolve to the pre-switch
        // global config; only conversation should see the recovered provider.
        for role: ModelRole in [.presentation, .recap, .tagging] {
            let settings = CompanionPresentationSettings.load(role: role, defaults: defaults, environment: [:], resolveSecrets: false)
            XCTAssertEqual(settings.provider, .ollama, "\(role) must not be affected by a conversation recovery switch")
        }
        let conversationSettings = CompanionPresentationSettings.load(role: .conversation, defaults: defaults, environment: [:], resolveSecrets: false)
        XCTAssertEqual(conversationSettings.provider, .groq, "conversation should pick up the recovered provider on the next call")
    }

    func testConversationRecoveryModelSwitchAlsoWritesConversationRoleKey() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        defaults.set(CompanionPresentationProvider.groq.rawValue, forKey: CompanionPreferenceKey.presentationLLMProvider)
        defaults.set("original-global-model", forKey: CompanionPreferenceKey.presentationLLMModel)

        let model = try AppModel(store: CardStore.inMemory())
        model.selectConversationRecoveryModel(CompanionPresentationModelOption(id: "recovered-model", detail: "test", reasoningEfforts: []))

        XCTAssertEqual(
            defaults.string(forKey: CompanionPreferenceKey.presentationLLMRoleKey(.conversation, .model)),
            "recovered-model"
        )
        XCTAssertEqual(
            defaults.string(forKey: CompanionPreferenceKey.presentationLLMModel),
            "original-global-model",
            "the global model key must be untouched by a conversation-only recovery switch"
        )
    }

    func testCloudConsentMigrationCreditsTheCurrentProviderOnce() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        defaults.set(CompanionPresentationProvider.xai.rawValue, forKey: CompanionPreferenceKey.presentationLLMProvider)
        defaults.set(true, forKey: CompanionPreferenceKey.cloudConsentPresentation)

        let model = try AppModel(store: CardStore.inMemory())

        XCTAssertTrue(
            model.cloudConsentAcknowledged(for: .xai),
            "the legacy true flag should migrate onto the provider configured at migration time"
        )
        XCTAssertFalse(
            model.cloudConsentAcknowledged(for: .groq),
            "migration must not blanket-consent every cloud provider"
        )
        XCTAssertTrue(defaults.bool(forKey: CompanionPreferenceKey.cloudConsentPresentationMigrationDone))
    }

    func testCloudConsentMigrationDoesNotRunWhenLegacyFlagWasNeverSet() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        defaults.set(CompanionPresentationProvider.xai.rawValue, forKey: CompanionPreferenceKey.presentationLLMProvider)

        let model = try AppModel(store: CardStore.inMemory())

        XCTAssertFalse(model.cloudConsentAcknowledged(for: .xai))
        XCTAssertTrue(defaults.bool(forKey: CompanionPreferenceKey.cloudConsentPresentationMigrationDone), "migration should still mark itself done so it never re-checks the legacy flag")
    }

    func testCloudConsentMigrationIsIdempotentAndNeverReRuns() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        defaults.set(CompanionPresentationProvider.xai.rawValue, forKey: CompanionPreferenceKey.presentationLLMProvider)
        defaults.set(true, forKey: CompanionPreferenceKey.cloudConsentPresentation)

        _ = try AppModel(store: CardStore.inMemory())
        XCTAssertEqual(
            defaults.array(forKey: CompanionPreferenceKey.cloudConsentPresentationProviders) as? [String],
            [CompanionPresentationProvider.xai.rawValue]
        )

        // Revoke consent and switch the configured provider, then relaunch:
        // since migration already ran once, the stale legacy `true` flag
        // must not silently re-grant consent for the new provider.
        defaults.set([String](), forKey: CompanionPreferenceKey.cloudConsentPresentationProviders)
        defaults.set(CompanionPresentationProvider.groq.rawValue, forKey: CompanionPreferenceKey.presentationLLMProvider)

        let secondLaunch = try AppModel(store: CardStore.inMemory())
        XCTAssertFalse(secondLaunch.cloudConsentAcknowledged(for: .groq), "migration must not re-run on a later launch")
        XCTAssertFalse(secondLaunch.cloudConsentAcknowledged(for: .xai), "the explicit revocation above must stick")
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
