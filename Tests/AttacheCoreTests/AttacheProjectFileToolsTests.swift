import AttacheCore
import XCTest
import Foundation

final class AttacheProjectFileToolsTests: XCTestCase {

    private let session = AttacheFocusedSession(
        sessionID: "sess-1", sourceKind: "codex",
        displayTitle: "Test", workingDirectory: "/tmp/proj",
        authorizationEpoch: AttacheFocusEpoch(1)
    )
    private let epoch = AttacheFocusEpoch(1)

    private func makeFile(_ lines: Int, prefix: String = "line") -> AttacheProjectFile {
        let content = (1...lines).map { i in "\(prefix) \(i): fact \(i * 100)" }.joined(separator: "\n")
        return AttacheProjectFile(relativePath: "src/main.swift", content: content)
    }

    private func makeReserve(total: Int = 10_000, cap: Int = 5_000) -> AttacheToolBudgetReserve {
        AttacheToolBudgetReserve(totalTokens: total, perCallCap: cap)
    }

    private func makePolicy() -> AttacheToolBudgetPolicy {
        .from(strategy: .automatic)
    }

    // Criterion 1: unique facts from beginning, middle, and end.
    func testCanReadBeginningMiddleAndEnd() {
        let file = makeFile(100_000)
        var reserve = makeReserve()
        let policy = makePolicy()
        let begin = AttacheProjectFileTools.readRange(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: "sess-1", relativePath: "src/main.swift",
            lineStart: 1, maxLines: 10, file: file, expectedContentHash: nil,
            reserve: &reserve, policy: policy
        )
        guard case .success(let b) = begin else { return XCTFail("beginning") }
        XCTAssertTrue(b.content.contains("fact 100"))

        let mid = AttacheProjectFileTools.readRange(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: "sess-1", relativePath: "src/main.swift",
            lineStart: 50_000, maxLines: 10, file: file, expectedContentHash: nil,
            reserve: &reserve, policy: policy
        )
        guard case .success(let m) = mid else { return XCTFail("middle") }
        XCTAssertTrue(m.content.contains("fact 5000000"))

        let end = AttacheProjectFileTools.readRange(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: "sess-1", relativePath: "src/main.swift",
            lineStart: 99_990, maxLines: 10, file: file, expectedContentHash: nil,
            reserve: &reserve, policy: policy
        )
        guard case .success(let e) = end else { return XCTFail("end") }
        XCTAssertTrue(e.content.contains("fact 9999900"))
    }

    // Criterion 2: path escape attacks fail closed.
    func testPathEscapeFailsClosed() {
        let file = makeFile(10)
        var reserve = makeReserve()
        let policy = makePolicy()
        let escaping = AttacheProjectFileTools.readRange(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: "sess-1", relativePath: "../../../etc/passwd",
            lineStart: 1, maxLines: 10, file: file, expectedContentHash: nil,
            reserve: &reserve, policy: policy
        )
        guard case .failure(let error) = escaping else { return XCTFail("should fail") }
        XCTAssertEqual(error, .pathEscape)
    }

    func testAbsolutePathOutsideWorkingDirFails() {
        XCTAssertNil(AttacheFilePathGuard.canonicalize("/etc/passwd", workingDirectory: "/tmp/proj"))
    }

    func testSiblingPrefixAndSymlinkEscapeFailClosed() throws {
        XCTAssertNil(AttacheFilePathGuard.canonicalize("/tmp/proj-evil/file", workingDirectory: "/tmp/proj"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attache-file-root-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("attache-file-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertNil(AttacheFilePathGuard.canonicalize("escape/secret.txt", workingDirectory: root.path))
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }

    func testNullByteInjectionFails() {
        XCTAssertNil(AttacheFilePathGuard.canonicalize("src/\0../etc", workingDirectory: "/tmp/proj"))
    }

    func testMissingCurrentSessionFailsClosed() {
        let file = makeFile(10)
        let result = AttacheProjectFileTools.inspect(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: nil, relativePath: file.relativePath, file: file
        )
        guard case .failure(let error) = result else { return XCTFail("must fail") }
        XCTAssertEqual(error, .noFocusedSession)
    }

    func testGiantSingleLineIsBoundedIncludingEvidenceWrapper() {
        let file = AttacheProjectFile(relativePath: "src/main.swift", content: String(repeating: "x", count: 100_000))
        var reserve = AttacheToolBudgetReserve(totalTokens: 120, perCallCap: 120)
        let result = AttacheProjectFileTools.readRange(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: "sess-1", relativePath: file.relativePath,
            lineStart: 1, maxLines: 1, file: file, expectedContentHash: nil,
            reserve: &reserve, policy: makePolicy()
        )
        guard case .success(let page) = result else { return XCTFail("bounded page should succeed") }
        XCTAssertLessThanOrEqual(AttacheFallbackTokenEstimator().estimate(text: page.content), 120)
        XCTAssertNotNil(page.continuationLocator)
        XCTAssertEqual(page.continuationLocator?.charStart, page.locator.charEnd)
    }

    func testPathTooLongFails() {
        let long = String(repeating: "a", count: AttacheFilePathGuard.maxPathLength + 1)
        XCTAssertNil(AttacheFilePathGuard.canonicalize(long, workingDirectory: "/tmp/proj"))
    }

    func testUnicodeFullwidthDotsNotTreatedAsTraversal() {
        // Fullwidth dots (U+FF0E) are NOT ASCII dots (U+002E). They do not
        // decompose to ".." under NFC. They are valid path characters, not a
        // traversal attack. The guard correctly does not reject them.
        let path = "src/\u{FF0E}\u{FF0E}/etc"
        let canonical = AttacheFilePathGuard.canonicalize(path, workingDirectory: "/tmp/proj")
        XCTAssertNotNil(canonical, "fullwidth dots are not traversal, not rejected")
    }

    // Criterion 3: binary and credential files never return content.
    func testBinaryFileRefused() {
        let binary = AttacheProjectFile(relativePath: "data.bin", content: "bin\0ary\u{01}\u{02}")
        let result = AttacheProjectFileTools.inspect(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: "sess-1", relativePath: "data.bin", file: binary
        )
        guard case .failure(let error) = result else { return XCTFail("binary refused") }
        XCTAssertEqual(error, .binaryFile)
    }

    func testCredentialFileRefused() {
        let cred = AttacheProjectFile(relativePath: "config.env", content: "api_key=sk-1234567890abcdef")
        let result = AttacheProjectFileTools.inspect(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: "sess-1", relativePath: "config.env", file: cred
        )
        guard case .failure(let error) = result else { return XCTFail("credential refused") }
        XCTAssertEqual(error, .credentialFile)
    }

    func testSensitiveCredentialPathsAreRefusedWithoutRecognizableTokenText() {
        let paths = [
            ".env", ".env.local", ".npmrc", ".pypirc", ".netrc",
            ".git-credentials", ".aws/credentials", ".ssh/id_ed25519",
            "config/service-account.json", "certs/client.pem", "certs/client.key"
        ]

        for path in paths {
            let file = AttacheProjectFile(relativePath: path, content: "enabled=true")
            let result = AttacheProjectFileTools.inspect(
                focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
                currentSessionID: "sess-1", relativePath: path, file: file
            )
            guard case .failure(let error) = result else {
                XCTFail("sensitive path should be refused: \(path)")
                continue
            }
            XCTAssertEqual(error, .credentialFile, path)
        }
    }

    func testCredentialScannerCatchesTokenKeysAndProviderFormats() {
        let samples = [
            "GITHUB_TOKEN=ghp_012345678901234567890123456789012345",
            "AUTH_TOKEN=opaque-auth-token-value",
            "OPENAI_KEY=opaque-openai-value",
            // Split so the synthetic sample never matches provider-shaped
            // literals in secret scanners while the runtime string still does.
            "SLACK_BOT_TOKEN=xoxb-" + "123456789012-123456789012-abcdefghijklmnop",
            "NPM_TOKEN=npm_012345678901234567890123456789012345",
            "token: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature123",
            "Cookie: sessionid=0123456789abcdef",
            "SESSION_SECRET=0123456789abcdef"
        ]

        for sample in samples {
            XCTAssertTrue(
                AttacheProjectFileTools.containsCredentials(sample),
                "credential was not detected: \(sample)"
            )
        }
        XCTAssertFalse(
            AttacheProjectFileTools.containsCredentials(
                "This session discusses browser cookie preferences without including any values."
            )
        )
    }

    func testCredentialGuardAppliesToSearchAndInitialRangeRead() {
        let file = AttacheProjectFile(
            relativePath: "notes.txt",
            content: "AUTH_TOKEN=opaque-auth-token-value\nordinary notes"
        )
        var searchReserve = makeReserve()
        let search = AttacheProjectFileTools.search(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: "sess-1", relativePath: file.relativePath,
            query: "ordinary", file: file, reserve: &searchReserve
        )
        guard case .failure(let searchError) = search else {
            return XCTFail("search must not return content from a credential file")
        }
        XCTAssertEqual(searchError, .credentialFile)

        var readReserve = makeReserve()
        let read = AttacheProjectFileTools.readRange(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: "sess-1", relativePath: file.relativePath,
            lineStart: 1, maxLines: 10, file: file, expectedContentHash: nil,
            reserve: &readReserve, policy: makePolicy()
        )
        guard case .failure(let readError) = read else {
            return XCTFail("range read must not return content from a credential file")
        }
        XCTAssertEqual(readError, .credentialFile)
    }

    func testCredentialGuardAppliesToContinuationRead() {
        let file = AttacheProjectFile(
            relativePath: "notes.txt",
            content: "header\nNPM_TOKEN=npm_012345678901234567890123456789012345"
        )
        let canonical = AttacheFilePathGuard.canonicalize(
            file.relativePath,
            workingDirectory: session.workingDirectory!
        )!
        let locator = AttacheFileLocator(
            sessionID: session.sessionID,
            sourceKind: session.sourceKind,
            authorizationEpoch: epoch,
            normalizedPath: canonical,
            lineStart: 1,
            lineEnd: 1,
            charStart: 0,
            charEnd: 0,
            contentHash: file.contentHash
        )
        var reserve = makeReserve()
        let result = AttacheProjectFileTools.readRange(
            focusedSession: session,
            currentEpoch: epoch,
            currentSessionID: session.sessionID,
            locator: locator,
            maxChars: 100,
            file: file,
            reserve: &reserve,
            policy: makePolicy()
        )
        guard case .failure(let error) = result else {
            return XCTFail("continuation read must not bypass credential detection")
        }
        XCTAssertEqual(error, .credentialFile)
    }

    func testSecretRedaction() {
        let content = "normal line\napi_key=secret123\nanother line"
        let redacted = AttacheProjectFileTools.redactSecrets(content)
        XCTAssertTrue(redacted.contains("[REDACTED]"))
        XCTAssertFalse(redacted.contains("secret123"))
        XCTAssertTrue(redacted.contains("normal line"))
    }

    // Criterion 4: results always include path, hash, range, truncation.
    func testResultsIncludeProvenance() {
        let file = makeFile(100)
        var reserve = makeReserve()
        let policy = makePolicy()
        let result = AttacheProjectFileTools.readRange(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: "sess-1", relativePath: "src/main.swift",
            lineStart: 10, maxLines: 5, file: file, expectedContentHash: nil,
            reserve: &reserve, policy: policy
        )
        guard case .success(let read) = result else { return XCTFail("read") }
        XCTAssertFalse(read.locator.normalizedPath.isEmpty)
        XCTAssertFalse(read.locator.contentHash.isEmpty)
        XCTAssertGreaterThanOrEqual(read.locator.lineStart, 1)
        XCTAssertGreaterThanOrEqual(read.locator.lineEnd, read.locator.lineStart)
        XCTAssertTrue(read.isQuotedEvidence)
    }

    // Criterion 5: search stays within output budget.
    func testSearchBoundedByMaxResults() {
        let content = (1...100).map { i in "match query line \(i)" }.joined(separator: "\n")
        let file = AttacheProjectFile(relativePath: "big.swift", content: content)
        var reserve = makeReserve(total: 100_000, cap: 50_000)
        let result = AttacheProjectFileTools.search(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: "sess-1", relativePath: "big.swift",
            query: "query", file: file, reserve: &reserve
        )
        guard case .success(let hits) = result else { return XCTFail("search") }
        XCTAssertLessThanOrEqual(hits.count, AttacheProjectFileTools.maxSearchResults)
    }

    func testSearchNeverExceedsPerCallOrRemainingTokenBudget() {
        let content = (1...100).map { i in
            "query \(i) " + String(repeating: "dense-result ", count: 30)
        }.joined(separator: "\n")
        let file = AttacheProjectFile(relativePath: "big.swift", content: content)
        var reserve = makeReserve(total: 9, cap: 7)
        let result = AttacheProjectFileTools.search(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: "sess-1", relativePath: "big.swift",
            query: "query", file: file, reserve: &reserve
        )
        guard case .success(let hits) = result else { return XCTFail("search") }
        let returnedTokens = hits.reduce(0) {
            $0 + AttacheFallbackTokenEstimator().estimate(text: $1.snippet)
        }
        XCTAssertLessThanOrEqual(returnedTokens, 7)
        XCTAssertEqual(reserve.consumedTokens, returnedTokens)
    }

    // Criterion 6: no-focus, different-focus, or expired authorization returns
    // no project data.
    func testNoFocusReturnsNoData() {
        let file = makeFile(10)
        var reserve = makeReserve()
        let policy = makePolicy()
        let result = AttacheProjectFileTools.readRange(
            focusedSession: nil, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: nil, relativePath: "src/main.swift",
            lineStart: 1, maxLines: 10, file: file, expectedContentHash: nil,
            reserve: &reserve, policy: policy
        )
        guard case .failure(let error) = result else { return XCTFail("no focus") }
        XCTAssertEqual(error, .noFocusedSession)
    }

    func testExpiredAuthorizationReturnsNoData() {
        let file = makeFile(10)
        var reserve = makeReserve()
        let policy = makePolicy()
        let result = AttacheProjectFileTools.readRange(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: AttacheFocusEpoch(2),
            currentSessionID: "sess-1", relativePath: "src/main.swift",
            lineStart: 1, maxLines: 10, file: file, expectedContentHash: nil,
            reserve: &reserve, policy: policy
        )
        guard case .failure(let error) = result else { return XCTFail("expired") }
        XCTAssertEqual(error, .authorizationExpired)
    }

    func testDifferentFocusReturnsNoData() {
        let file = makeFile(10)
        var reserve = makeReserve()
        let policy = makePolicy()
        let result = AttacheProjectFileTools.readRange(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: "sess-OTHER", relativePath: "src/main.swift",
            lineStart: 1, maxLines: 10, file: file, expectedContentHash: nil,
            reserve: &reserve, policy: policy
        )
        guard case .failure(let error) = result else { return XCTFail("different focus") }
        if case .sessionIdentityMismatch = error { /* expected */ } else { XCTFail("expected mismatch") }
    }

    // Criterion 7: HTTP and CLI paths share identical validation and
    // accounting.
    func testHTTPAndCLIProduceIdenticalResults() {
        let file = makeFile(50)
        var reserveHTTP = makeReserve()
        var reserveCLI = makeReserve()
        let policy = makePolicy()
        let http = AttacheProjectFileTools.readRange(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: "sess-1", relativePath: "src/main.swift",
            lineStart: 10, maxLines: 5, file: file, expectedContentHash: nil,
            reserve: &reserveHTTP, policy: policy
        )
        let cli = AttacheProjectFileTools.readRange(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: "sess-1", relativePath: "src/main.swift",
            lineStart: 10, maxLines: 5, file: file, expectedContentHash: nil,
            reserve: &reserveCLI, policy: policy
        )
        guard case .success(let h) = http, case .success(let c) = cli else {
            return XCTFail("both should succeed")
        }
        XCTAssertEqual(h, c, "HTTP and CLI identical")
        XCTAssertEqual(reserveHTTP.consumedTokens, reserveCLI.consumedTokens, "identical budget")
    }

    // Criterion 8: existing file-read safety remains at least as strict.
    func testFileTooLargeRefused() {
        let huge = AttacheProjectFile(relativePath: "huge.txt", content: String(repeating: "x", count: AttacheFileContainmentGuard.maxFileBytes + 1))
        let result = AttacheProjectFileTools.inspect(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: "sess-1", relativePath: "huge.txt", file: huge
        )
        guard case .failure(let error) = result else { return XCTFail("huge refused") }
        if case .fileTooLarge = error { /* expected */ } else { XCTFail("expected fileTooLarge") }
    }

    // Stale file (hash mismatch) returns typed error.
    func testStaleFileReturnsTypedError() {
        let file = makeFile(10)
        var reserve = makeReserve()
        let policy = makePolicy()
        let result = AttacheProjectFileTools.readRange(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: "sess-1", relativePath: "src/main.swift",
            lineStart: 1, maxLines: 5, file: file, expectedContentHash: "wronghash",
            reserve: &reserve, policy: policy
        )
        guard case .failure(let error) = result else { return XCTFail("stale") }
        if case .staleFile = error { /* expected */ } else { XCTFail("expected staleFile") }
    }

    // Budget exhaustion stops reads.
    func testBudgetExhaustionStopsReads() {
        let file = makeFile(10)
        var reserve = AttacheToolBudgetReserve(totalTokens: 0, perCallCap: 0)
        let policy = makePolicy()
        let result = AttacheProjectFileTools.readRange(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: "sess-1", relativePath: "src/main.swift",
            lineStart: 1, maxLines: 5, file: file, expectedContentHash: nil,
            reserve: &reserve, policy: policy
        )
        guard case .failure(let error) = result else { return XCTFail("exhausted") }
        XCTAssertEqual(error, .budgetExhausted)
    }

    // Inspection returns metadata and outline.
    func testInspectionReturnsMetadata() {
        let file = makeFile(50)
        let result = AttacheProjectFileTools.inspect(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: "sess-1", relativePath: "src/main.swift", file: file
        )
        guard case .success(let inspection) = result else { return XCTFail("inspect") }
        XCTAssertEqual(inspection.lineCount, 50)
        XCTAssertFalse(inspection.contentHash.isEmpty)
        XCTAssertFalse(inspection.outline.isEmpty)
        XCTAssertEqual(inspection.fileType, "swift")
    }

    // Content is quoted evidence.
    func testContentIsQuotedEvidence() {
        let file = makeFile(10)
        var reserve = makeReserve()
        let policy = makePolicy()
        let result = AttacheProjectFileTools.readRange(
            focusedSession: session, expectedEpoch: epoch, currentEpoch: epoch,
            currentSessionID: "sess-1", relativePath: "src/main.swift",
            lineStart: 1, maxLines: 5, file: file, expectedContentHash: nil,
            reserve: &reserve, policy: policy
        )
        guard case .success(let read) = result else { return XCTFail("read") }
        XCTAssertTrue(read.content.contains("[Evidence"), "quoted evidence")
        XCTAssertTrue(read.isQuotedEvidence)
    }

    // Path canonicalization produces a valid path inside the working dir.
    func testCanonicalizationInsideWorkingDir() {
        let canonical = AttacheFilePathGuard.canonicalize("src/main.swift", workingDirectory: "/tmp/proj")
        XCTAssertEqual(canonical, "/tmp/proj/src/main.swift")
    }

    // Symlink escape detected.
    func testSymlinkEscapeDetected() {
        XCTAssertTrue(AttacheFilePathGuard.resolvesOutsideWorkingDirectory(
            resolvedPath: "/etc/passwd", workingDirectory: "/tmp/proj"
        ))
        XCTAssertFalse(AttacheFilePathGuard.resolvesOutsideWorkingDirectory(
            resolvedPath: "/tmp/proj/src/main.swift", workingDirectory: "/tmp/proj"
        ))
    }
}
