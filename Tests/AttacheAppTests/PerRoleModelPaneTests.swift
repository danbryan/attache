import XCTest
import AppKit
import AttacheCore
@testable import AttacheApp

/// INF-253 (D3): the Advanced "per-task models" section in Settings > Model
/// adds UI-facing mutators (`selectRoleProvider`/`selectRoleModel`/
/// `selectRoleModelID`/`setRoleReasoningEffort`/`setRoleServiceTier`) on top of
/// D2's read-path plumbing, which `PerRoleModelSettingsTests` already covers
/// via `AttachePresentationSettings.load(role:)` directly. These tests cover
/// the write path: a role override persists to that role's keys only, is
/// picked back up on the next launch, and clearing it (back to "Use main
/// model") removes every one of that role's keys so `load(role:)` falls all
/// the way back to the global config, not to a stale-but-matching leftover
/// value.
///
/// `AppModel`'s only initializer reads `UserDefaults.standard` directly (no
/// injectable defaults), so these tests follow the same pattern already used
/// by `PerRoleModelRecoveryAndConsentTests`: touch real `UserDefaults.standard`,
/// but snapshot and restore every key touched.
@MainActor
final class PerRoleModelPaneTests: XCTestCase {
    private let preferenceKeys: [String] = [
        AttachePreferenceKey.presentationLLMProvider,
        AttachePreferenceKey.presentationLLMModel,
        AttachePreferenceKey.presentationReasoningEffort,
        AttachePreferenceKey.presentationServiceTier
    ] + ModelRole.allCases.flatMap { role in
        [
            AttachePreferenceKey.presentationLLMRoleKey(role, .provider),
            AttachePreferenceKey.presentationLLMRoleKey(role, .model),
            AttachePreferenceKey.presentationLLMRoleKey(role, .reasoningEffort),
            AttachePreferenceKey.presentationLLMRoleKey(role, .serviceTier)
        ]
    }

    func testSelectRoleProviderPersistsOnlyToThatRolesKeys() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        defaults.set(AttachePresentationProvider.ollama.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        defaults.set("global-model", forKey: AttachePreferenceKey.presentationLLMModel)

        let model = try AppModel(store: CardStore.inMemory())
        XCTAssertNil(model.roleModelProvider[.recap], "recap should start on \"Use main model\"")

        model.selectRoleProvider(.xai, for: .recap)

        XCTAssertEqual(model.roleModelProvider[.recap], .xai)
        XCTAssertEqual(model.roleModelID[.recap], AttachePresentationProvider.xai.defaultModel)
        XCTAssertEqual(
            defaults.string(forKey: AttachePreferenceKey.presentationLLMRoleKey(.recap, .provider)),
            AttachePresentationProvider.xai.rawValue
        )
        // Every other role, and the global keys, must be untouched.
        for role: ModelRole in [.conversation, .presentation, .tagging] {
            XCTAssertNil(model.roleModelProvider[role], "\(role) must not see recap's override")
        }
        XCTAssertEqual(defaults.string(forKey: AttachePreferenceKey.presentationLLMProvider), AttachePresentationProvider.ollama.rawValue)
        XCTAssertEqual(defaults.string(forKey: AttachePreferenceKey.presentationLLMModel), "global-model")

        let recapSettings = AttachePresentationSettings.load(role: .recap, defaults: defaults, environment: [:], resolveSecrets: false)
        XCTAssertEqual(recapSettings.provider, .xai)
    }

    func testRoleOverridePersistsAcrossRelaunch() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        let first = try AppModel(store: CardStore.inMemory())
        first.selectRoleProvider(.xai, for: .recap)
        first.selectRoleModelID("relaunch-model", for: .recap)

        let second = try AppModel(store: CardStore.inMemory())
        XCTAssertEqual(second.roleModelProvider[.recap], .xai, "the override must be loaded back on the next launch")
        XCTAssertEqual(second.roleModelID[.recap], "relaunch-model")
    }

    func testResettingToUseMainModelClearsEveryRoleKeyAndRestoresFallback() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        defaults.set(AttachePresentationProvider.ollama.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        defaults.set("global-model", forKey: AttachePreferenceKey.presentationLLMModel)

        let model = try AppModel(store: CardStore.inMemory())
        model.selectRoleProvider(.xai, for: .recap)
        model.selectRoleModelID("recap-only-model", for: .recap)
        XCTAssertEqual(model.roleModelProvider[.recap], .xai)

        // Change the global/main model *after* setting the override, so a
        // leftover per-role key would be immediately visible as a mismatch
        // below, not a coincidental match.
        defaults.set(AttachePresentationProvider.custom.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        defaults.set("new-global-model", forKey: AttachePreferenceKey.presentationLLMModel)

        model.selectRoleProvider(nil, for: .recap)

        XCTAssertNil(model.roleModelProvider[.recap])
        for field: AttachePreferenceKey.PresentationLLMField in [.provider, .model, .reasoningEffort, .serviceTier] {
            XCTAssertNil(
                defaults.object(forKey: AttachePreferenceKey.presentationLLMRoleKey(.recap, field)),
                "clearing the override must remove the \(field) key, not just leave a stale value"
            )
        }

        let recapSettings = AttachePresentationSettings.load(role: .recap, defaults: defaults, environment: [:], resolveSecrets: false)
        XCTAssertEqual(recapSettings.provider, .custom, "recap must fall back to the new main/global provider")
        XCTAssertEqual(recapSettings.model, "new-global-model", "recap must fall back to the new main/global model, proving it re-resolves rather than keeping a stale cached value")
    }

    func testClampsReasoningAndServiceTierWhenModelChanges() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        let model = try AppModel(store: CardStore.inMemory())
        model.selectRoleProvider(.custom, for: .tagging)
        model.selectRoleModelID("gpt-5-mini", for: .tagging)

        XCTAssertEqual(model.roleReasoningEffort[.tagging], "none")
        XCTAssertTrue(model.roleServiceTierOptions(for: .tagging).contains { $0.id == "flex" })
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
