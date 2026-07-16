import AttacheCore
import XCTest

final class SessionIndexerTests: XCTestCase {
    private final class StubScanner: SessionScanner {
        let kind: SourceKind = .codex
        let file: ScannedFile
        let marker: String

        init(file: ScannedFile, marker: String) {
            self.file = file
            self.marker = marker
        }

        func beginScan() {}
        func enumerateFiles() -> [ScannedFile] { [file] }
        func makeRecord(for file: ScannedFile, priorTopicTag: String?, contentCap: Int) -> SessionRecord {
            SessionRecord(
                id: file.id,
                title: "Private session",
                project: "/tmp/private",
                threadName: nil,
                updatedAt: Date(timeIntervalSince1970: file.mtime),
                archived: false,
                filePath: file.url.path,
                fileMtime: file.mtime,
                content: marker,
                topicTag: priorTopicTag,
                sourceKind: .codex
            )
        }
        func refreshMetadata(_ record: SessionRecord, for file: ScannedFile) -> SessionRecord { record }
    }

    func testCodexHomeFallsBackToUserCodexDirectory() {
        let home = CodexPaths.home(environment: [:])
        XCTAssertEqual(home.lastPathComponent, ".codex")
        XCTAssertTrue(home.path.hasSuffix("/.codex"))
    }

    func testCodexHomeUsesNonEmptyEnvironmentOverride() {
        let override = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-codex-home-\(UUID().uuidString)", isDirectory: true)
        let resolved = CodexPaths.home(environment: ["CODEX_HOME": override.path])
        XCTAssertEqual(resolved.path, override.standardizedFileURL.path)
        XCTAssertEqual(CodexPaths.sessionsDirectory(environment: ["CODEX_HOME": override.path]).path,
                       override.appendingPathComponent("sessions", isDirectory: true).standardizedFileURL.path)
        XCTAssertEqual(CodexPaths.sessionIndexURL(environment: ["CODEX_HOME": override.path]).lastPathComponent,
                       "session_index.jsonl")
    }

    func testBlankCodexHomeEnvironmentFallsBack() {
        let home = CodexPaths.home(environment: ["CODEX_HOME": "  "])
        XCTAssertEqual(home.lastPathComponent, ".codex")
    }

    func testSessionIDExtractedFromRolloutFileName() {
        let name = "rollout-2026-06-03T15-35-20-019e8efb-b0e2-7061-b0e1-f7df4b9735e0.jsonl"
        XCTAssertEqual(CodexSessionScanner.sessionID(fromFileName: name), "019e8efb-b0e2-7061-b0e1-f7df4b9735e0")
    }

    func testSessionIDNilWhenNoUUID() {
        XCTAssertNil(CodexSessionScanner.sessionID(fromFileName: "notes.jsonl"))
    }

    func testFirstCWDReadFromSessionMeta() {
        let jsonl = """
        {"type":"turn_context","payload":{"foo":"bar"}}
        {"type":"session_meta","payload":{"id":"x","cwd":"/Users/example/code/penumbra"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"hi"}]}}
        """
        XCTAssertEqual(CodexSessionScanner.firstCWD(inJSONL: jsonl), "/Users/example/code/penumbra")
    }

    func testFirstCWDNilWhenAbsent() {
        XCTAssertNil(CodexSessionScanner.firstCWD(inJSONL: #"{"type":"response_item","payload":{}}"#))
    }

    func testClaudeCodeParsePullsCwdTitleAndContent() {
        // Claude Code: user content is a string, assistant content is a block list,
        // the title arrives on an ai-title line, and cwd is on every line.
        let jsonl = """
        {"type":"user","cwd":"/Users/example/code/penumbra","message":{"role":"user","content":"set up the validator notes"}}
        {"type":"ai-title","aiTitle":"Validator notes setup"}
        {"type":"assistant","cwd":"/Users/example/code/penumbra","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Done, notes added."}]}}
        """
        let parsed = ClaudeCodeSessionScanner.parse(jsonl: jsonl, contentCap: 8_000)
        XCTAssertEqual(parsed.project, "/Users/example/code/penumbra")
        XCTAssertEqual(parsed.title, "Validator notes setup")
        XCTAssertEqual(parsed.firstUserMessage, "set up the validator notes")
        XCTAssertTrue(parsed.content.contains("validator notes"))
        XCTAssertTrue(parsed.content.contains("done, notes added."))
        XCTAssertFalse(parsed.content.contains("hmm"), "thinking blocks are not part of the digest")
    }

    func testFreshCacheIsPrivateAndDoesNotDuplicateTranscriptContent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-session-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheURL = root.appendingPathComponent("SessionIndex.json")
        let transcriptURL = root.appendingPathComponent("session.jsonl")
        let marker = "SESSION_CACHE_PRIVATE_MARKER"
        let scanner = StubScanner(
            file: ScannedFile(id: "session-1", url: transcriptURL, mtime: 100, archived: false),
            marker: marker
        )

        let indexer = SessionIndexer(cacheURL: cacheURL, scanners: [scanner])
        XCTAssertEqual(indexer.refresh().first?.content, marker)

        let stored = try String(contentsOf: cacheURL, encoding: .utf8)
        XCTAssertFalse(stored.contains(marker))
        let attributes = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        XCTAssertEqual(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual(((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o700)
    }

    func testLegacyCacheIsHardenedAndTranscriptContentIsScrubbedOnLoad() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-session-cache-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cacheURL = root.appendingPathComponent("SessionIndex.json")
        let marker = "LEGACY_SESSION_CACHE_PRIVATE_MARKER"
        let record = SessionRecord(
            id: "legacy-1",
            title: "Legacy",
            project: "/tmp/legacy",
            threadName: nil,
            updatedAt: Date(timeIntervalSince1970: 100),
            archived: false,
            filePath: "/tmp/legacy.jsonl",
            fileMtime: 100,
            content: marker,
            sourceKind: .codex
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([record]).write(to: cacheURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cacheURL.path)

        let indexer = SessionIndexer(cacheURL: cacheURL, scanners: [])

        XCTAssertEqual(indexer.allRecords.first?.content, "")
        let stored = try String(contentsOf: cacheURL, encoding: .utf8)
        XCTAssertFalse(stored.contains(marker))
        let attributes = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        XCTAssertEqual(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o600)
    }
}
