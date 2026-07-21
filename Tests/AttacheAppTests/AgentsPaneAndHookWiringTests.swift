import AppKit
import AttacheCore
import XCTest
@testable import AttacheApp

/// The settings reorganization (INF): the Agents pane owns the four local agent
/// sources, Integrations narrows to the credentialed providers, enabling a
/// source installs its immediacy hook (opinionated), an upgrade migration
/// rederives hook installation from source enablement, and the reset flow can
/// remove the installed hooks. Real hook file IO is suppressed under xctest
/// (`AppModel.suppressesRealHookIO`), so nothing here touches ~/.claude or
/// ~/.codex; the wiring is verified through the published mirror state.
@MainActor
final class AgentsPaneAndHookWiringTests: XCTestCase {

    // MARK: - Pane composition

    func testAgentsPaneListsExactlyTheFourSources() {
        XCTAssertEqual(AgentsPane.sources.map(\.id), ["codex", "claude", "grok", "opencode"])
        XCTAssertEqual(AgentsPane.sources.count, 4)
        // Only Claude Code and Codex carry an installed immediacy hook.
        let hooked = Set(AgentsPane.sources.filter(\.hooked).map(\.id))
        XCTAssertEqual(hooked, ["codex", "claude"])
    }

    func testIntegrationsPaneListsExactlyTheCredentialedProviders() {
        XCTAssertEqual(
            IntegrationsPane.providers.map(\.id),
            ["xai", "elevenlabs", "openai", "ollama", "custom"])
        // The non-credentialed rows (Claude Code subscription, on-device Apple
        // voice) and the retired agent-source rows are gone from Integrations.
        let ids = Set(IntegrationsPane.providers.map(\.id))
        XCTAssertFalse(ids.contains("claude"))
        XCTAssertFalse(ids.contains("ondevice"))
        // Every remaining provider has something to configure (a key and/or an
        // endpoint), which is what "credentialed service" means here.
        for provider in IntegrationsPane.providers {
            XCTAssertTrue(provider.hasKey || provider.hasEndpoint, "\(provider.id) must be credentialed")
        }
    }

    // MARK: - Enable installs, disable removes (derived hook state)

    private static let hookKeys = [
        AttachePreferenceKey.codexSourceEnabled,
        AttachePreferenceKey.claudeCodeSourceEnabled,
        AttachePreferenceKey.grokBuildSourceEnabled,
        AttachePreferenceKey.opencodeSourceEnabled,
        AttachePreferenceKey.installClaudeHooks,
        AttachePreferenceKey.installCodexNotify,
        AttachePreferenceKey.hooksSourceDerivedMigrated,
        AttachePreferenceKey.watchedSessions
    ]

    func testEnablingClaudeCodeInstallsHookDisablingRemovesIt() throws {
        _ = NSApplication.shared
        let snapshot = DefaultsSnapshot(keys: Self.hookKeys, defaults: .standard)
        defer { snapshot.restore() }

        let model = try AppModel(store: CardStore.inMemory())
        XCTAssertFalse(model.installClaudeHooks, "a fresh model with no enabled source installs no hook")

        model.setClaudeCodeSourceEnabled(true)
        XCTAssertTrue(model.installClaudeHooks, "enabling Claude Code must install its hook")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: AttachePreferenceKey.installClaudeHooks))

        model.setClaudeCodeSourceEnabled(false)
        XCTAssertFalse(model.installClaudeHooks, "disabling Claude Code must remove its hook")
    }

    func testEnablingCodexInstallsNotifyDisablingRemovesIt() throws {
        _ = NSApplication.shared
        let snapshot = DefaultsSnapshot(keys: Self.hookKeys, defaults: .standard)
        defer { snapshot.restore() }

        let model = try AppModel(store: CardStore.inMemory())
        XCTAssertFalse(model.installCodexNotify)

        model.setCodexSourceEnabled(true)
        XCTAssertTrue(model.installCodexNotify, "enabling Codex must install its notify program")

        model.setCodexSourceEnabled(false)
        XCTAssertFalse(model.installCodexNotify, "disabling Codex must remove its notify program")
    }

    func testGrokAndOpencodeCarryNoHook() throws {
        _ = NSApplication.shared
        let snapshot = DefaultsSnapshot(keys: Self.hookKeys, defaults: .standard)
        defer { snapshot.restore() }

        let model = try AppModel(store: CardStore.inMemory())
        model.setGrokBuildSourceEnabled(true)
        model.setOpencodeSourceEnabled(true)
        // Non-hooked sources never flip the hook mirrors.
        XCTAssertFalse(model.installClaudeHooks)
        XCTAssertFalse(model.installCodexNotify)
    }

    // MARK: - Upgrade migration rule

    /// On the first launch after upgrade, hooks are installed for whichever
    /// sources are enabled, regardless of the retired Precise-status toggle's
    /// persisted value. Source on + old toggle off => installed (opinionated).
    func testMigrationRederivesHooksFromEnabledSourcesIgnoringOldToggle() throws {
        _ = NSApplication.shared
        let snapshot = DefaultsSnapshot(keys: Self.hookKeys, defaults: .standard)
        defer { snapshot.restore() }
        let defaults = UserDefaults.standard

        // Pre-upgrade state: Claude source ON but the old toggle was OFF; Codex
        // source OFF but the old toggle was ON. No migration marker yet.
        defaults.set(true, forKey: AttachePreferenceKey.claudeCodeSourceEnabled)
        defaults.set(false, forKey: AttachePreferenceKey.codexSourceEnabled)
        defaults.set(false, forKey: AttachePreferenceKey.installClaudeHooks)
        defaults.set(true, forKey: AttachePreferenceKey.installCodexNotify)

        let model = try AppModel(store: CardStore.inMemory())

        XCTAssertTrue(model.installClaudeHooks, "enabled Claude source must install despite old toggle off")
        XCTAssertFalse(model.installCodexNotify, "disabled Codex source must not install despite old toggle on")
        XCTAssertTrue(defaults.bool(forKey: AttachePreferenceKey.hooksSourceDerivedMigrated),
                      "migration must record its marker so it runs once")
    }

    func testMigrationRunsOnlyOnce() throws {
        _ = NSApplication.shared
        let snapshot = DefaultsSnapshot(keys: Self.hookKeys, defaults: .standard)
        defer { snapshot.restore() }
        let defaults = UserDefaults.standard

        // Already migrated: a persisted installClaudeHooks value must be honored,
        // not re-derived from the (disabled) source.
        defaults.set(true, forKey: AttachePreferenceKey.hooksSourceDerivedMigrated)
        defaults.set(false, forKey: AttachePreferenceKey.claudeCodeSourceEnabled)
        defaults.set(true, forKey: AttachePreferenceKey.installClaudeHooks)

        let model = try AppModel(store: CardStore.inMemory())
        XCTAssertTrue(model.installClaudeHooks, "post-migration launch must not re-derive over the persisted value")
    }

    // MARK: - Reset removal-choice plumbing

    func testHookRemovalOfferedOnlyWhenSomethingIsInstalled() {
        XCTAssertFalse(AppModel.offersHookRemovalOnReset(claudeInstalled: false, codexInstalled: false))
        XCTAssertTrue(AppModel.offersHookRemovalOnReset(claudeInstalled: true, codexInstalled: false))
        XCTAssertTrue(AppModel.offersHookRemovalOnReset(claudeInstalled: false, codexInstalled: true))
    }

    func testHookResetPlanClampsToWhatIsInstalledAndToTheChoice() {
        // Opt in, both installed: remove both.
        XCTAssertEqual(
            AppModel.hookResetPlan(userChoseRemove: true, claudeInstalled: true, codexInstalled: true),
            AppModel.HookResetPlan(removeClaudeHooks: true, removeCodexNotify: true))
        // Opt in, only Claude installed: never touch a Codex config Attaché
        // never wrote.
        XCTAssertEqual(
            AppModel.hookResetPlan(userChoseRemove: true, claudeInstalled: true, codexInstalled: false),
            AppModel.HookResetPlan(removeClaudeHooks: true, removeCodexNotify: false))
        // Opt out: remove nothing even when both are installed.
        XCTAssertEqual(
            AppModel.hookResetPlan(userChoseRemove: false, claudeInstalled: true, codexInstalled: true),
            AppModel.HookResetPlan(removeClaudeHooks: false, removeCodexNotify: false))
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
