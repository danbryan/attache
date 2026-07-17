import XCTest
@testable import AttacheApp

/// INF-360: `AppModel.rebuildSessionIndexer` now builds its scanner list by
/// filtering `SessionSourceRegistry.production()` instead of two hardcoded
/// `if codexSourceEnabled { ... }` / `if claudeCodeSourceEnabled { ... }`
/// appends, but the on-disk preference keys that gate those two sources are
/// settings compatibility surface for existing users and must stay
/// byte-identical.
final class SessionSourceTogglePreferenceKeyTests: XCTestCase {
    func testCodexAndClaudeCodeToggleKeysAreUnchanged() {
        XCTAssertEqual(AttachePreferenceKey.codexSourceEnabled, "attache.codexSourceEnabled")
        XCTAssertEqual(AttachePreferenceKey.claudeCodeSourceEnabled, "attache.claudeCodeSourceEnabled")
    }
}
