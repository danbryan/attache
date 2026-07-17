import XCTest
import AppKit
import AttacheCore
@testable import AttacheApp

/// INF-362 acceptance criterion (mirrors INF-361's grok_build test exactly):
/// toggling opencode off stops indexing for opencode only; codex, claude, and
/// grok_build stay exactly as they were.
@MainActor
final class OpencodeSourceToggleTests: XCTestCase {
    private let preferenceKeys = [
        AttachePreferenceKey.codexSourceEnabled,
        AttachePreferenceKey.claudeCodeSourceEnabled,
        AttachePreferenceKey.grokBuildSourceEnabled,
        AttachePreferenceKey.opencodeSourceEnabled,
        AttachePreferenceKey.watchedSessions
    ]

    func testTogglingOpencodeOffLeavesOtherSourcesUnaffected() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        let model = try AppModel(store: CardStore.inMemory())
        model.setCodexSourceEnabled(true)
        model.setClaudeCodeSourceEnabled(true)
        model.setGrokBuildSourceEnabled(true)
        model.setOpencodeSourceEnabled(true)
        XCTAssertTrue(model.opencodeSourceEnabled)

        model.setOpencodeSourceEnabled(false)

        XCTAssertFalse(model.opencodeSourceEnabled)
        XCTAssertTrue(model.codexSourceEnabled, "disabling opencode must not disturb codex")
        XCTAssertTrue(model.claudeCodeSourceEnabled, "disabling opencode must not disturb claude")
        XCTAssertTrue(model.grokBuildSourceEnabled, "disabling opencode must not disturb grok_build")
    }

    func testTogglingCodexOffLeavesOpencodeUnaffected() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        let model = try AppModel(store: CardStore.inMemory())
        model.setCodexSourceEnabled(true)
        model.setOpencodeSourceEnabled(true)

        model.setCodexSourceEnabled(false)

        XCTAssertFalse(model.codexSourceEnabled)
        XCTAssertTrue(model.opencodeSourceEnabled, "disabling codex must not disturb opencode")
    }

    /// Disabling opencode drops any attached opencode target while leaving a
    /// simultaneously-attached Codex target watched.
    func testDisablingOpencodeDetachesOnlyOpencodeTargets() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        let model = try AppModel(store: CardStore.inMemory())
        model.setCodexSourceEnabled(true)
        model.setOpencodeSourceEnabled(true)

        let opencodeTarget = CodexSessionTarget(
            id: "opencode-1", title: "opencode session", updatedAt: Date(),
            category: .activeSession, status: nil, sourceKind: .opencode, filePath: nil
        )
        let codexTarget = CodexSessionTarget(
            id: "codex-1", title: "Codex session", updatedAt: Date(),
            category: .activeSession, status: nil, sourceKind: .codex, filePath: nil
        )
        model.attachCodexSession(opencodeTarget)
        model.attachCodexSession(codexTarget)
        XCTAssertTrue(model.attachedSessionList.contains { $0.id == "opencode-1" })
        XCTAssertTrue(model.attachedSessionList.contains { $0.id == "codex-1" })

        model.setOpencodeSourceEnabled(false)

        XCTAssertFalse(model.attachedSessionList.contains { $0.id == "opencode-1" }, "opencode target must be detached")
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
