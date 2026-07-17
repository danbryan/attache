import AppKit
import AttacheCore
import Combine
import XCTest
@testable import AttacheApp

/// INF-351: `SettingsPaneState` is the narrow render surface Settings panes
/// observe instead of `AppModel` directly, so a pane does not re-render on
/// AppModel's high-frequency, unrelated publishes (narration, character
/// animation, call timers). These tests prove the publish-count contract:
/// exactly one publish for a presentation change that actually changes the
/// snapshot, and zero publishes for unrelated AppModel churn.
@MainActor
final class SettingsPaneStateTests: XCTestCase {
    private let touchedKeys = [
        AttachePreferenceKey.presentationLLMProvider,
        AttachePreferenceKey.presentationLLMBaseURL,
        AttachePreferenceKey.presentationLLMModel
    ]

    func testSettingsPaneStatePublishesExactlyOnceForOneModelChange() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: touchedKeys, defaults: defaults)
        defer { snapshot.restore() }
        let model = try AppModel(store: CardStore.inMemory())

        var publishCount = 0
        var cancellables = Set<AnyCancellable>()
        model.settingsPaneState.$snapshot
            .dropFirst() // the subscription itself replays the current value
            .sink { _ in publishCount += 1 }
            .store(in: &cancellables)

        model.presentationModel = "settings-pane-state-test-model-\(UUID().uuidString)"

        XCTAssertEqual(publishCount, 1)
    }

    func testUnrelatedAppModelPublishesDoNotRepublishSettingsPaneState() throws {
        _ = NSApplication.shared
        let model = try AppModel(store: CardStore.inMemory())

        var publishCount = 0
        var cancellables = Set<AnyCancellable>()
        model.settingsPaneState.$snapshot
            .dropFirst()
            .sink { _ in publishCount += 1 }
            .store(in: &cancellables)

        // Simulated activity ticks: character animation and presence churn
        // that AppModel publishes constantly during narration/playback, none
        // of which feeds the Settings-pane render surface.
        model.characterFocusAngle += 1
        model.characterFocusAngle += 1
        model.character = .cowboy
        model.character = .robot

        XCTAssertEqual(publishCount, 0)
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
