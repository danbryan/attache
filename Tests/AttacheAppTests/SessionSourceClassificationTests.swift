import XCTest
import AttacheCore
@testable import AttacheApp

/// A live gate (`scripts/claude-two-way-smoke.sh`, INF-257/E2) found that a
/// Claude Code session resolved under a `CLAUDE_CONFIG_DIR`-overridden
/// projects directory (a disposable test home, or any real user override)
/// was misclassified as Codex and parsed with the wrong transcript format, so
/// its completed turns were silently dropped instead of becoming cards. Two
/// distinct bugs produced that symptom (INF-261):
///
/// 1. Classification used to check `fileURL.path.contains("/.claude/")`, a
///    literal substring the overridden path never contains, instead of
///    checking against the actually-resolved `claudeProjectsDirectory` that
///    `locateSessionFile` already searched to find the file in the first
///    place.
/// 2. After fixing (1) to a `hasPrefix` check, the live gate *still* failed:
///    `claudeProjectsDirectory` is built directly from `CLAUDE_CONFIG_DIR`
///    (typically `/tmp/...` in a disposable test home), but `fileURL` comes
///    from `FileManager`'s directory enumerator, which returns the
///    canonicalized path (`/private/tmp/...` on macOS, since `/tmp` is a
///    symlink to `/private/tmp`). A plain string `hasPrefix` between an
///    unresolved and a resolved path silently fails even though both name
///    the same directory on disk, so both sides must go through
///    `resolvingSymlinksInPath()` before comparing.
final class SessionSourceClassificationTests: XCTestCase {
    /// A directory that is genuinely Claude's resolved projects directory for
    /// this watcher instance, but whose path does not contain the literal
    /// substring "/.claude/" - exactly the shape of a disposable
    /// `CLAUDE_CONFIG_DIR` override.
    private let overriddenClaudeProjectsDirectory = URL(
        fileURLWithPath: "/tmp/attache-fake-claude-home-test/projects", isDirectory: true
    )
    private let codexSessionsDirectory = URL(
        fileURLWithPath: "/tmp/attache-fake-codex-home-test/sessions", isDirectory: true
    )

    func testCodexSessionWatcherClassifiesAnOverriddenClaudeDirectoryAsClaudeCode() {
        let watcher = CodexSessionWatcher(
            sessionsDirectory: codexSessionsDirectory,
            claudeProjectsDirectory: overriddenClaudeProjectsDirectory
        )
        let fileURL = overriddenClaudeProjectsDirectory
            .appendingPathComponent("-tmp-work/00000000-0000-0000-0000-000000000000.jsonl")
        XCTAssertFalse(fileURL.path.contains("/.claude/"), "test fixture must not contain the old literal substring")
        XCTAssertEqual(watcher.sourceKind(for: fileURL), .claudeCode)
    }

    func testCodexSessionWatcherClassifiesACodexPathAsCodex() {
        let watcher = CodexSessionWatcher(
            sessionsDirectory: codexSessionsDirectory,
            claudeProjectsDirectory: overriddenClaudeProjectsDirectory
        )
        let fileURL = codexSessionsDirectory
            .appendingPathComponent("2026/07/10/rollout-20260710-000000-00000000-0000-0000-0000-000000000000.jsonl")
        XCTAssertEqual(watcher.sourceKind(for: fileURL), .codex)
    }

    func testSessionActivityWatcherClassifiesAnOverriddenClaudeDirectoryAsClaudeCode() {
        let watcher = SessionActivityWatcher(
            sessionsDirectory: codexSessionsDirectory,
            claudeProjectsDirectory: overriddenClaudeProjectsDirectory
        )
        let fileURL = overriddenClaudeProjectsDirectory
            .appendingPathComponent("-tmp-work/00000000-0000-0000-0000-000000000000.jsonl")
        XCTAssertFalse(fileURL.path.contains("/.claude/"), "test fixture must not contain the old literal substring")
        XCTAssertEqual(watcher.sourceKind(for: fileURL), .claudeCode)
    }

    func testSessionActivityWatcherClassifiesACodexPathAsCodex() {
        let watcher = SessionActivityWatcher(
            sessionsDirectory: codexSessionsDirectory,
            claudeProjectsDirectory: overriddenClaudeProjectsDirectory
        )
        let fileURL = codexSessionsDirectory
            .appendingPathComponent("2026/07/10/rollout-20260710-000000-00000000-0000-0000-0000-000000000000.jsonl")
        XCTAssertEqual(watcher.sourceKind(for: fileURL), .codex)
    }

    // MARK: - Symlink asymmetry (the second half of INF-261)

    /// Reproduces the exact shape of the real bug on real, on-disk
    /// directories (`resolvingSymlinksInPath()` needs paths that actually
    /// exist to behave like `realpath()`; a purely in-memory URL doesn't
    /// exercise it faithfully): `claudeProjectsDirectory` is built from an
    /// un-resolved `CLAUDE_CONFIG_DIR`-style path under `/tmp/...`, but the
    /// file URL is located via `FileManager`'s real directory enumerator
    /// (exactly what `locateSessionFile`/`findSessionFile` use), which hands
    /// back the canonicalized `/private/tmp/...` path since `/tmp` is a
    /// symlink to `/private/tmp` on macOS. Before `resolvingSymlinksInPath()`
    /// was added to both sides of the comparison, this classified as `.codex`
    /// even though the file plainly lives under the Claude projects directory.
    func testClassificationSurvivesTmpSymlinkAsymmetryBetweenDirectoryAndFile() throws {
        let unresolvedProjectsDirectory = URL(
            fileURLWithPath: "/tmp/attache-symlink-asymmetry-test-\(UUID().uuidString)/claude-home/projects",
            isDirectory: true
        )
        let sessionDirectory = unresolvedProjectsDirectory.appendingPathComponent("-tmp-work", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unresolvedProjectsDirectory) }

        let sessionFile = sessionDirectory.appendingPathComponent("00000000-0000-0000-0000-000000000000.jsonl")
        try "{}".write(to: sessionFile, atomically: true, encoding: .utf8)

        let enumerator = FileManager.default.enumerator(at: unresolvedProjectsDirectory, includingPropertiesForKeys: nil)
        let locatedFileURL = try XCTUnwrap(enumerator?.compactMap { $0 as? URL }.first { $0.pathExtension == "jsonl" })
        XCTAssertTrue(
            locatedFileURL.path.hasPrefix("/private/tmp/"),
            "expected FileManager's enumerator to hand back the canonicalized path; got \(locatedFileURL.path)"
        )

        let codexWatcher = CodexSessionWatcher(
            sessionsDirectory: codexSessionsDirectory,
            claudeProjectsDirectory: unresolvedProjectsDirectory
        )
        XCTAssertEqual(codexWatcher.sourceKind(for: locatedFileURL), .claudeCode)

        let activityWatcher = SessionActivityWatcher(
            sessionsDirectory: codexSessionsDirectory,
            claudeProjectsDirectory: unresolvedProjectsDirectory
        )
        XCTAssertEqual(activityWatcher.sourceKind(for: locatedFileURL), .claudeCode)
    }
}
