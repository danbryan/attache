import AppKit
import AttacheCore
import XCTest
@testable import AttacheApp

/// INF-365: the global summon hotkey preference (AppModel.globalHotKeySpec)
/// defaults off and persists across relaunch the same way every other
/// AppModel preference does, via UserDefaults keyed by AttachePreferenceKey.
final class GlobalHotKeySettingsTests: XCTestCase {
    private let preferenceKeys = [
        AttachePreferenceKey.globalHotKeyCode,
        AttachePreferenceKey.globalHotKeyModifiers
    ]

    func testDefaultsToOff() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        let model = try AppModel(store: CardStore.inMemory())
        XCTAssertNil(model.globalHotKeySpec, "global summon hotkey must default off (unset)")
    }

    func testSettingPersistsAcrossRelaunch() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        let model = try AppModel(store: CardStore.inMemory())
        model.globalHotKeySpec = GlobalHotKeySpec(keyCode: 49, modifiers: [.command, .option])

        let relaunched = try AppModel(store: CardStore.inMemory())
        XCTAssertEqual(relaunched.globalHotKeySpec, GlobalHotKeySpec(keyCode: 49, modifiers: [.command, .option]))
    }

    func testClearingPersistsAsUnsetAcrossRelaunch() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        let model = try AppModel(store: CardStore.inMemory())
        model.globalHotKeySpec = GlobalHotKeySpec(keyCode: 49, modifiers: [.command, .option])
        model.globalHotKeySpec = nil

        let relaunched = try AppModel(store: CardStore.inMemory())
        XCTAssertNil(relaunched.globalHotKeySpec)
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
