import AppKit
import AttacheCore
import XCTest
@testable import AttacheApp

/// Caption on/off and karaoke-vs-plain preference defaults, persistence, and the
/// mirror down to the playback controller that gates forced alignment.
@MainActor
final class CaptionPreferenceTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private var savedEnabled: Any?
    private var savedStyle: Any?

    override func setUp() {
        super.setUp()
        // AppModel's appearance restore touches NSApp; initialize it as the other
        // AppModel-constructing tests do so a filtered run has a live app object.
        _ = NSApplication.shared
        savedEnabled = defaults.object(forKey: AttachePreferenceKey.captionsEnabled)
        savedStyle = defaults.object(forKey: AttachePreferenceKey.captionStyle)
        defaults.removeObject(forKey: AttachePreferenceKey.captionsEnabled)
        defaults.removeObject(forKey: AttachePreferenceKey.captionStyle)
    }

    override func tearDown() {
        if let savedEnabled { defaults.set(savedEnabled, forKey: AttachePreferenceKey.captionsEnabled) }
        else { defaults.removeObject(forKey: AttachePreferenceKey.captionsEnabled) }
        if let savedStyle { defaults.set(savedStyle, forKey: AttachePreferenceKey.captionStyle) }
        else { defaults.removeObject(forKey: AttachePreferenceKey.captionStyle) }
        super.tearDown()
    }

    func testDefaultsAreCaptionsOnAndKaraoke() throws {
        let model = try AppModel(store: CardStore.inMemory())
        XCTAssertTrue(model.captionsEnabled, "captions default ON")
        XCTAssertEqual(model.captionStyle, .karaoke, "style defaults to karaoke")
        XCTAssertTrue(model.playback.isCaptioningEnabled, "controller mirrors captions-on")
    }

    func testCaptionStylePersistsAcrossModels() throws {
        let model = try AppModel(store: CardStore.inMemory())
        model.captionStyle = .plain
        XCTAssertEqual(defaults.string(forKey: AttachePreferenceKey.captionStyle), "plain")

        let reloaded = try AppModel(store: CardStore.inMemory())
        XCTAssertEqual(reloaded.captionStyle, .plain)
    }

    func testTogglingCaptionsPersistsAndMirrorsToController() throws {
        let model = try AppModel(store: CardStore.inMemory())
        model.captionsEnabled = false
        XCTAssertFalse(defaults.bool(forKey: AttachePreferenceKey.captionsEnabled))
        XCTAssertFalse(model.playback.isCaptioningEnabled)

        let reloaded = try AppModel(store: CardStore.inMemory())
        XCTAssertFalse(reloaded.captionsEnabled)
        XCTAssertFalse(reloaded.playback.isCaptioningEnabled)
    }
}
