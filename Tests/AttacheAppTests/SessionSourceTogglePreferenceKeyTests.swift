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

    /// INF-361: Grok Build's toggle is a third preference key added the same
    /// way, not a rename or reuse of an existing one.
    func testGrokBuildToggleKeyExists() {
        XCTAssertEqual(AttachePreferenceKey.grokBuildSourceEnabled, "attache.grokBuildSourceEnabled")
    }
}
