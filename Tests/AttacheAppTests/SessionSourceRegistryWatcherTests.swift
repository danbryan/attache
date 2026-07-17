import XCTest
import AttacheCore
@testable import AttacheApp

/// INF-360: `CodexSessionWatcher` and `SessionActivityWatcher` used to
/// hardcode a binary claude-or-codex classifier (`sourceKind == .claudeCode
/// ? .claudeCode : .codex`). Both now delegate to `SessionSourceRegistry`.
/// These tests prove that delegation is real by handing each watcher a
/// registry that holds ONLY a synthetic, non-production source and checking
/// that classification comes from the registry's data, not from any
/// remaining special-case in the watcher.
final class SessionSourceRegistryWatcherTests: XCTestCase {
    private let syntheticDirectory = URL(
        fileURLWithPath: "/tmp/attache-synthetic-source-watcher-test/sessions", isDirectory: true
    )

    private func syntheticRegistry() -> SessionSourceRegistry {
        let directory = syntheticDirectory
        let descriptor = SessionSourceDescriptor(
            sourceKind: .generic,
            transcriptFormat: .claude,
            watchedDirectories: { [directory] },
            adapterTag: "synthetic-session-file",
            makeScanner: { ClaudeCodeSessionScanner(claudeHome: directory) }
        )
        return SessionSourceRegistry(descriptors: [descriptor])
    }

    func testCodexSessionWatcherClassifiesFilesUnderASyntheticSourceRegistry() {
        let watcher = CodexSessionWatcher(sourceRegistry: syntheticRegistry())
        let fileURL = syntheticDirectory.appendingPathComponent("00000000-0000-0000-0000-000000000000.jsonl")
        XCTAssertEqual(watcher.sourceKind(for: fileURL), .generic)
    }

    func testCodexSessionWatcherFallsBackToCodexOutsideTheSyntheticRegistry() {
        let watcher = CodexSessionWatcher(sourceRegistry: syntheticRegistry())
        let fileURL = URL(fileURLWithPath: "/tmp/attache-unrelated-directory/x.jsonl")
        XCTAssertEqual(watcher.sourceKind(for: fileURL), .codex)
    }

    func testSessionActivityWatcherClassifiesFilesUnderASyntheticSourceRegistry() {
        let watcher = SessionActivityWatcher(sourceRegistry: syntheticRegistry())
        let fileURL = syntheticDirectory.appendingPathComponent("00000000-0000-0000-0000-000000000000.jsonl")
        XCTAssertEqual(watcher.sourceKind(for: fileURL), .generic)
    }

    func testSessionActivityWatcherFallsBackToCodexOutsideTheSyntheticRegistry() {
        let watcher = SessionActivityWatcher(sourceRegistry: syntheticRegistry())
        let fileURL = URL(fileURLWithPath: "/tmp/attache-unrelated-directory/y.jsonl")
        XCTAssertEqual(watcher.sourceKind(for: fileURL), .codex)
    }
}
