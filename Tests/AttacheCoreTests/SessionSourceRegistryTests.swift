import XCTest
@testable import AttacheCore

/// INF-360: the live watchers and indexer/toggle wiring used to hardcode a
/// binary claude-or-codex branch. `SessionSourceRegistry` replaces that with
/// data; these tests prove the registry itself is generic (any descriptor,
/// not just the two production ones) and that production stays exactly
/// Codex + Claude Code with byte-identical behavior.
final class SessionSourceRegistryTests: XCTestCase {
    func testProductionRegistryHasExactlyCodexClaudeCodeGrokBuildAndOpencodeInOrder() {
        let registry = SessionSourceRegistry.production()
        XCTAssertEqual(registry.descriptors.map(\.sourceKind), [.codex, .claudeCode, .grokBuild, .opencode])
        XCTAssertEqual(registry.transcriptFormat(for: .codex), .codex)
        XCTAssertEqual(registry.transcriptFormat(for: .claudeCode), .claude)
        XCTAssertEqual(registry.transcriptFormat(for: .grokBuild), .grokBuild)
        XCTAssertEqual(registry.adapterTag(for: .codex), "codex-session-file")
        XCTAssertEqual(registry.adapterTag(for: .claudeCode), "claude-session-file")
        XCTAssertEqual(registry.adapterTag(for: .grokBuild), "grok-build-session-file")
        XCTAssertEqual(registry.adapterTag(for: .opencode), "opencode-session-db")
    }

    /// INF-362 safety criterion: opencode's transcript format is nil (SQLite
    /// rows have no JSONL line shape), which is exactly the signal
    /// `TwoWayCoordinator.transcriptFormat(for:)` needs to fail Tell Agent
    /// closed for opencode without any special-casing at that call site.
    func testOpencodeHasNoTranscriptFormat() {
        let registry = SessionSourceRegistry.production()
        XCTAssertNil(registry.transcriptFormat(for: .opencode))
    }

    /// INF-362: opencode's watched directory is its data home
    /// (`OpencodePaths.dataHome()`, overridable for tests), and its
    /// `fileMatch` identifies `opencode.db` specifically rather than a
    /// `.jsonl` extension (the default every other production source uses).
    func testProductionClassifiesFilesUnderOpencodesDataDirectory() {
        let opencodeHome = URL(fileURLWithPath: "/tmp/registry-test-opencode", isDirectory: true)
        let registry = SessionSourceRegistry.production(opencodeDataDirectory: opencodeHome)

        let dbFile = opencodeHome.appendingPathComponent("opencode.db")
        XCTAssertEqual(registry.classify(fileURL: dbFile), .opencode)
        XCTAssertTrue(registry.allWatchedDirectories().map(\.path).contains(opencodeHome.path))

        let descriptor = registry.descriptor(for: .opencode)
        XCTAssertEqual(descriptor?.fileMatch(dbFile), true)
        XCTAssertEqual(descriptor?.fileMatch(opencodeHome.appendingPathComponent("opencode.db-wal")), false)
    }

    /// INF-361: Grok Build's own watched directory is registered from
    /// `GrokPaths.sessionsDirectory()` (overridable for tests), classifies
    /// files under it, and does not collide with Codex/Claude classification.
    func testProductionClassifiesFilesUnderGrokBuildsSessionsDirectory() {
        let grokSessions = URL(fileURLWithPath: "/tmp/registry-test-grok/sessions", isDirectory: true)
        let registry = SessionSourceRegistry.production(grokSessionsDirectory: grokSessions)

        let projectDir = grokSessions.appendingPathComponent("%2FUsers%2Ftester%2Fproject", isDirectory: true)
        let sessionFile = projectDir
            .appendingPathComponent("00000000-0000-0000-0000-000000000000", isDirectory: true)
            .appendingPathComponent("chat_history.jsonl")
        XCTAssertEqual(registry.classify(fileURL: sessionFile), .grokBuild)
        XCTAssertTrue(registry.allWatchedDirectories().map(\.path).contains(grokSessions.path))
    }

    func testProductionRegistryHasNoDescriptorForOtherSourceKinds() {
        let registry = SessionSourceRegistry.production()
        XCTAssertNil(registry.descriptor(for: .mcp))
        XCTAssertNil(registry.descriptor(for: .generic))
        XCTAssertNil(registry.descriptor(for: .simulated))
        XCTAssertNil(registry.transcriptFormat(for: .generic))
    }

    func testProductionClassifiesFilesUnderEachSourcesDirectories() {
        let codexSessions = URL(fileURLWithPath: "/tmp/registry-test-codex/sessions", isDirectory: true)
        let codexArchived = URL(fileURLWithPath: "/tmp/registry-test-codex/archived_sessions", isDirectory: true)
        let claudeProjects = URL(fileURLWithPath: "/tmp/registry-test-claude/projects", isDirectory: true)
        let grokSessions = URL(fileURLWithPath: "/tmp/registry-test-grok/sessions", isDirectory: true)
        let opencodeHome = URL(fileURLWithPath: "/tmp/registry-test-opencode", isDirectory: true)
        let registry = SessionSourceRegistry.production(
            codexSessionsDirectory: codexSessions,
            codexArchivedSessionsDirectory: codexArchived,
            claudeProjectsDirectory: claudeProjects,
            grokSessionsDirectory: grokSessions,
            opencodeDataDirectory: opencodeHome
        )

        XCTAssertEqual(registry.classify(fileURL: codexSessions.appendingPathComponent("a.jsonl")), .codex)
        XCTAssertEqual(registry.classify(fileURL: codexArchived.appendingPathComponent("b.jsonl")), .codex)
        XCTAssertEqual(registry.classify(fileURL: claudeProjects.appendingPathComponent("c.jsonl")), .claudeCode)
        XCTAssertEqual(registry.classify(fileURL: grokSessions.appendingPathComponent("e/f/chat_history.jsonl")), .grokBuild)
        XCTAssertEqual(registry.classify(fileURL: opencodeHome.appendingPathComponent("opencode.db")), .opencode)
        XCTAssertNil(registry.classify(fileURL: URL(fileURLWithPath: "/tmp/somewhere-else/d.jsonl")))

        XCTAssertEqual(
            Set(registry.allWatchedDirectories().map(\.path)),
            Set([codexSessions.path, codexArchived.path, claudeProjects.path, grokSessions.path, opencodeHome.path])
        )
    }

    /// The proof of generalization: a registry holding only a synthetic,
    /// non-production source (kind `.generic`, format `.claude`, an
    /// arbitrary temp directory) still classifies files under that
    /// directory to it, resolves its format, and reports it as watched -
    /// purely from the descriptor's data, with no special-casing anywhere
    /// in the registry for the synthetic kind.
    func testSyntheticSourceIsClassifiedFormattedAndWatchedFromDataAlone() {
        let syntheticDirectory = URL(fileURLWithPath: "/tmp/registry-test-synthetic-source", isDirectory: true)
        let descriptor = SessionSourceDescriptor(
            sourceKind: .generic,
            transcriptFormat: .claude,
            watchedDirectories: { [syntheticDirectory] },
            adapterTag: "synthetic-session-file",
            makeScanner: { ClaudeCodeSessionScanner(claudeHome: syntheticDirectory) }
        )
        let registry = SessionSourceRegistry(descriptors: [descriptor])

        let fileURL = syntheticDirectory.appendingPathComponent("session.jsonl")
        XCTAssertEqual(registry.classify(fileURL: fileURL), .generic)
        XCTAssertEqual(registry.transcriptFormat(for: .generic), .claude)
        XCTAssertEqual(registry.adapterTag(for: .generic), "synthetic-session-file")
        XCTAssertEqual(registry.allWatchedDirectories().map(\.path), [syntheticDirectory.path])

        // Unregistered kinds (including the production ones) are absent from
        // a registry that never listed them.
        XCTAssertNil(registry.classify(fileURL: URL(fileURLWithPath: "/tmp/registry-test-codex/sessions/a.jsonl")))
        XCTAssertNil(registry.transcriptFormat(for: .codex))
    }
}
