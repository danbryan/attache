import XCTest
import AppKit
import AttacheCore
@testable import AttacheApp

/// INF-361 acceptance criterion: toggling grok_build off stops indexing and
/// watching for grok_build only; codex and claude stay exactly as they were.
@MainActor
final class GrokBuildSourceToggleTests: XCTestCase {
    private let preferenceKeys = [
        AttachePreferenceKey.codexSourceEnabled,
        AttachePreferenceKey.claudeCodeSourceEnabled,
        AttachePreferenceKey.grokBuildSourceEnabled,
        AttachePreferenceKey.watchedSessions
    ]

    func testTogglingGrokBuildOffLeavesCodexAndClaudeUnaffected() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        let model = try AppModel(store: CardStore.inMemory())
        model.setCodexSourceEnabled(true)
        model.setClaudeCodeSourceEnabled(true)
        model.setGrokBuildSourceEnabled(true)
        XCTAssertTrue(model.codexSourceEnabled)
        XCTAssertTrue(model.claudeCodeSourceEnabled)
        XCTAssertTrue(model.grokBuildSourceEnabled)

        model.setGrokBuildSourceEnabled(false)

        XCTAssertFalse(model.grokBuildSourceEnabled)
        XCTAssertTrue(model.codexSourceEnabled, "disabling grok_build must not disturb codex")
        XCTAssertTrue(model.claudeCodeSourceEnabled, "disabling grok_build must not disturb claude")
    }

    func testTogglingCodexOffLeavesGrokBuildUnaffected() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        let model = try AppModel(store: CardStore.inMemory())
        model.setCodexSourceEnabled(true)
        model.setGrokBuildSourceEnabled(true)

        model.setCodexSourceEnabled(false)

        XCTAssertFalse(model.codexSourceEnabled)
        XCTAssertTrue(model.grokBuildSourceEnabled, "disabling codex must not disturb grok_build")
    }

    /// Disabling grok_build drops any attached Grok target while leaving a
    /// simultaneously-attached Codex target watched.
    func testDisablingGrokBuildDetachesOnlyGrokTargets() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        let model = try AppModel(store: CardStore.inMemory())
        model.setCodexSourceEnabled(true)
        model.setGrokBuildSourceEnabled(true)

        let grokTarget = CodexSessionTarget(
            id: "grok-1", title: "Grok session", updatedAt: Date(),
            category: .activeSession, status: nil, sourceKind: .grokBuild, filePath: nil
        )
        let codexTarget = CodexSessionTarget(
            id: "codex-1", title: "Codex session", updatedAt: Date(),
            category: .activeSession, status: nil, sourceKind: .codex, filePath: nil
        )
        model.attachCodexSession(grokTarget)
        model.attachCodexSession(codexTarget)
        XCTAssertTrue(model.attachedSessionList.contains { $0.id == "grok-1" })
        XCTAssertTrue(model.attachedSessionList.contains { $0.id == "codex-1" })

        model.setGrokBuildSourceEnabled(false)

        XCTAssertFalse(model.attachedSessionList.contains { $0.id == "grok-1" }, "grok target must be detached")
        XCTAssertTrue(model.attachedSessionList.contains { $0.id == "codex-1" }, "codex target must stay attached")
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
