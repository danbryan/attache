import XCTest
@testable import AttacheCore

/// INF-360: the live watchers and indexer/toggle wiring used to hardcode a
/// binary claude-or-codex branch. `SessionSourceRegistry` replaces that with
/// data; these tests prove the registry itself is generic (any descriptor,
/// not just the two production ones) and that production stays exactly
/// Codex + Claude Code with byte-identical behavior.
final class SessionSourceRegistryTests: XCTestCase {
    func testProductionRegistryHasExactlyCodexAndClaudeCodeInOrder() {
        let registry = SessionSourceRegistry.production()
        XCTAssertEqual(registry.descriptors.map(\.sourceKind), [.codex, .claudeCode])
        XCTAssertEqual(registry.transcriptFormat(for: .codex), .codex)
        XCTAssertEqual(registry.transcriptFormat(for: .claudeCode), .claude)
        XCTAssertEqual(registry.adapterTag(for: .codex), "codex-session-file")
        XCTAssertEqual(registry.adapterTag(for: .claudeCode), "claude-session-file")
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
        let registry = SessionSourceRegistry.production(
            codexSessionsDirectory: codexSessions,
            codexArchivedSessionsDirectory: codexArchived,
            claudeProjectsDirectory: claudeProjects
        )

        XCTAssertEqual(registry.classify(fileURL: codexSessions.appendingPathComponent("a.jsonl")), .codex)
        XCTAssertEqual(registry.classify(fileURL: codexArchived.appendingPathComponent("b.jsonl")), .codex)
        XCTAssertEqual(registry.classify(fileURL: claudeProjects.appendingPathComponent("c.jsonl")), .claudeCode)
        XCTAssertNil(registry.classify(fileURL: URL(fileURLWithPath: "/tmp/somewhere-else/d.jsonl")))

        XCTAssertEqual(
            Set(registry.allWatchedDirectories().map(\.path)),
            Set([codexSessions.path, codexArchived.path, claudeProjects.path])
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
