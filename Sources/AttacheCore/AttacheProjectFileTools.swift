import Foundation
import CryptoKit

/// A stable provenance locator for file content (INF-323). Every returned
/// character maps to a path, line range, and content hash.
public struct AttacheFileLocator: Equatable, Sendable {
    public let sessionID: String
    public let sourceKind: String
    public let authorizationEpoch: AttacheFocusEpoch
    public let normalizedPath: String
    public let lineStart: Int
    public let lineEnd: Int
    public let charStart: Int
    public let charEnd: Int
    public let contentHash: String

    public init(
        sessionID: String,
        sourceKind: String = "",
        authorizationEpoch: AttacheFocusEpoch = AttacheFocusEpoch(0),
        normalizedPath: String,
        lineStart: Int,
        lineEnd: Int,
        charStart: Int = 0,
        charEnd: Int = 0,
        contentHash: String
    ) {
        self.sessionID = sessionID
        self.sourceKind = sourceKind
        self.authorizationEpoch = authorizationEpoch
        self.normalizedPath = normalizedPath
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.charStart = charStart
        self.charEnd = charEnd
        self.contentHash = contentHash
    }

    public var coveredRange: String { "lines \(lineStart)..\(lineEnd)" }
}

/// A typed project-file tool error (INF-323).
public enum AttacheFileToolError: Error, Equatable, Sendable {
    case noFocusedSession
    case authorizationExpired
    case sessionIdentityMismatch(expected: String, actual: String)
    case sourceKindMismatch(expected: String, actual: String)
    case pathEscape
    case binaryFile
    case credentialFile
    case fileTooLarge(size: Int, max: Int)
    case staleFile(expectedHash: String, actualHash: String)
    case budgetExhausted
    case fileNotFound
    case pathTooLong(maxLength: Int)
}

/// File metadata and a bounded structural outline (INF-323).
public struct AttacheFileInspection: Equatable, Sendable {
    public let normalizedPath: String
    public let fileSize: Int
    public let fileType: String
    public let encoding: String
    public let contentHash: String
    public let lineCount: Int
    public let outline: [String]

    public init(normalizedPath: String, fileSize: Int, fileType: String, encoding: String, contentHash: String, lineCount: Int, outline: [String]) {
        self.normalizedPath = normalizedPath
        self.fileSize = fileSize
        self.fileType = fileType
        self.encoding = encoding
        self.contentHash = contentHash
        self.lineCount = lineCount
        self.outline = outline
    }
}

/// One file search hit (INF-323).
public struct AttacheFileSearchHit: Equatable, Sendable {
    public let locator: AttacheFileLocator
    public let snippet: String
    public let rank: Double
    public let truncation: AttacheTranscriptTruncation

    public init(locator: AttacheFileLocator, snippet: String, rank: Double, truncation: AttacheTranscriptTruncation) {
        self.locator = locator
        self.snippet = snippet
        self.rank = rank
        self.truncation = truncation
    }
}

/// The result of reading a file range (INF-323). Bounded content with a
/// locator, truncation state, and continuation.
public struct AttacheFileRangeRead: Equatable, Sendable {
    public let locator: AttacheFileLocator
    public let content: String
    public let truncation: AttacheTranscriptTruncation
    public let continuationLocator: AttacheFileLocator?
    public let isQuotedEvidence: Bool

    public init(locator: AttacheFileLocator, content: String, truncation: AttacheTranscriptTruncation, continuationLocator: AttacheFileLocator?, isQuotedEvidence: Bool = true) {
        self.locator = locator
        self.content = content
        self.truncation = truncation
        self.continuationLocator = continuationLocator
        self.isQuotedEvidence = isQuotedEvidence
    }
}

/// One file in a synthetic repository (INF-323). The App provides real
/// filesystem data; the Core tools validate, budget, and provenance.
public struct AttacheProjectFile: Equatable, Sendable {
    public let relativePath: String
    public let content: String
    public let contentHash: String

    public init(relativePath: String, content: String) {
        self.relativePath = relativePath
        self.content = content
        self.contentHash = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The path containment guard (INF-323). Canonicalizes paths, rejects
/// traversal, escape, absolute paths outside the working directory, case/
/// Unicode tricks, and path-length attacks. Existing file-read safety remains
/// at least as strict.
public enum AttacheFilePathGuard {

    public static let maxPathLength = 4_096

    /// Validate and canonicalize a file path against the working directory
    /// (INF-323). Returns the canonicalized path or nil if the path escapes.
    public static func canonicalize(
        _ path: String, workingDirectory: String
    ) -> String? {
        guard path.count <= maxPathLength else { return nil }
        guard !workingDirectory.isEmpty else { return nil }
        if path.contains("\0") { return nil }
        let nfc = path.precomposedStringWithCanonicalMapping
        let components = (nfc as NSString).pathComponents
        guard !components.contains("..") else { return nil }

        let lexicalRoot = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .standardizedFileURL
        let root = lexicalRoot.resolvingSymlinksInPath()

        let relative: String
        if nfc.hasPrefix("/") {
            let absolute = URL(fileURLWithPath: nfc).standardizedFileURL
            if contains(absolute, in: lexicalRoot) {
                relative = relativePath(from: absolute, root: lexicalRoot)
            } else if contains(absolute, in: root) {
                relative = relativePath(from: absolute, root: root)
            } else {
                return nil
            }
        } else {
            relative = nfc
        }

        // Resolve after every component. Foundation may leave an intermediate
        // symlink unresolved when the final child does not exist, so resolving
        // only the complete path can accidentally accept a symlink escape.
        var candidate = root
        for component in (relative as NSString).pathComponents
            where component != "." && component != "/" && !component.isEmpty {
            candidate = candidate
                .appendingPathComponent(component)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard contains(candidate, in: root) else { return nil }
        }
        return candidate.path
    }

    /// True when the path escapes the working directory via symlink resolution
    /// (INF-323). The caller provides the resolved path; this checks whether
    /// it still starts with the working directory.
    public static func resolvesOutsideWorkingDirectory(
        resolvedPath: String, workingDirectory: String
    ) -> Bool {
        canonicalize(resolvedPath, workingDirectory: workingDirectory) == nil
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        if root.path == "/" { return candidate.path.hasPrefix("/") }
        return candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    private static func relativePath(from candidate: URL, root: URL) -> String {
        guard candidate.path != root.path else { return "" }
        return String(candidate.path.dropFirst(root.path.count + (root.path == "/" ? 0 : 1)))
    }
}

/// The pure project-file tool family (INF-323). Read-only tools for bounded
/// tree inspection, text search, file metadata/outline, and exact line/byte
/// range reads. Every operation is scoped to the frozen focused working
/// directory. File contents are untrusted quoted evidence. HTTP and CLI paths
/// share identical Core logic.
public enum AttacheProjectFileTools {

    public static let maxSearchResults = 20
    public static let maxSearchSnippetChars = 200
    public static let outlineLineCount = 10
    public static let credentialPatterns = [
        "api_key", "apikey", "secret", "password", "private_key",
        "bearer ", "aws_secret", "sk-", "-----begin"
    ]

    /// Credential values that do not necessarily carry an obvious key name.
    /// These cover common provider token formats plus credential-bearing HTTP
    /// headers and URLs. The read tools fail closed on a match instead of trying
    /// to redact an arbitrary slice of a potentially multi-line secret.
    private static let credentialValuePattern =
        #"(?im)(?:\bgh[pousr]_[a-z0-9]{20,}\b|\bgithub_pat_[a-z0-9_]{20,}\b|\bxox[baprs]-[a-z0-9-]{10,}\b|\bnpm_[a-z0-9]{20,}\b|\beyj[a-z0-9_-]{8,}\.[a-z0-9_-]{8,}\.[a-z0-9_-]{8,}\b|\bakia[0-9a-z]{16}\b|\baiza[0-9a-z_-]{30,}\b|\b(?:sk|rk)_(?:live|test)_[0-9a-z]{16,}\b|\bsk-(?:proj-|svcacct-)?[a-z0-9_-]{12,}\b|^\s*(?:cookie|set-cookie|authorization)\s*:\s*\S+|https?://[^/\s:@]+:[^/\s@]+@)"#

    private static let credentialAssignmentLeadIns = [
        "token", "openai_key", "openai-key", "credential", "authorization",
        "cookie", "session", "passwd", "api-key", "private-key",
        "client_secret", "client-secret"
    ]
    private static let credentialValueLeadIns = [
        "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "xox",
        "npm_", "eyj", "akia", "aiza", "sk_", "rk_", "sk-", "cookie:",
        "set-cookie:", "authorization:", "http://", "https://"
    ]

    /// Configuration assignments whose values are credentials even when the
    /// value has no recognizable provider prefix. Requiring an assignment or
    /// JSON delimiter avoids treating ordinary prose about sessions or cookies
    /// as a credential by itself.
    private static let credentialAssignmentPattern =
        #"(?im)(?:^|[\s,{])[\"']?[a-z0-9_.-]*(?:api[_-]?key|openai[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|github[_-]?token|gitlab[_-]?token|slack[_-]?(?:bot[_-]?)?token|npm[_-]?token|client[_-]?secret|private[_-]?key|password|passwd|credential|authorization|cookie|session(?:[_-]?(?:id|key|token|secret))?)[\"']?\s*[:=]\s*[\"']?[^\s\"',}\]]{6,}"#

    /// Inspect a file (INF-323). Returns metadata and a bounded outline. No
    /// authorization bypass: validates the epoch and session.
    public static func inspect(
        focusedSession: AttacheFocusedSession?,
        expectedEpoch: AttacheFocusEpoch,
        currentEpoch: AttacheFocusEpoch,
        currentSessionID: String?,
        relativePath: String,
        file: AttacheProjectFile
    ) -> Result<AttacheFileInspection, AttacheFileToolError> {
        let validated = validateAccess(
            focusedSession: focusedSession, expectedEpoch: expectedEpoch,
            currentEpoch: currentEpoch, currentSessionID: currentSessionID,
            relativePath: relativePath, file: file
        )
        guard case .success((_, let canonical)) = validated else {
            if case .failure(let error) = validated { return .failure(error) }
            return .failure(.pathEscape)
        }
        let size = Data(file.content.utf8).count
        if size > AttacheFileContainmentGuard.maxFileBytes {
            return .failure(.fileTooLarge(size: size, max: AttacheFileContainmentGuard.maxFileBytes))
        }
        if isBinary(file.content) { return .failure(.binaryFile) }
        if containsCredentials(file.content, path: canonical) { return .failure(.credentialFile) }
        let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false)
        let outline = Array(lines.prefix(outlineLineCount)).enumerated().map { i, line in
            "L\(i + 1): \(String(line.prefix(80)))"
        }
        return .success(AttacheFileInspection(
            normalizedPath: canonical, fileSize: size,
            fileType: detectFileType(relativePath), encoding: "utf-8",
            contentHash: file.contentHash, lineCount: lines.count, outline: outline
        ))
    }

    /// Search file content for a query (INF-323). Bounded results with stable
    /// locators. Cannot cross into a different session.
    public static func search(
        focusedSession: AttacheFocusedSession?,
        expectedEpoch: AttacheFocusEpoch,
        currentEpoch: AttacheFocusEpoch,
        currentSessionID: String?,
        relativePath: String,
        query: String,
        file: AttacheProjectFile,
        reserve: inout AttacheToolBudgetReserve
    ) -> Result<[AttacheFileSearchHit], AttacheFileToolError> {
        let validated = validateAccess(
            focusedSession: focusedSession, expectedEpoch: expectedEpoch,
            currentEpoch: currentEpoch, currentSessionID: currentSessionID,
            relativePath: relativePath, file: file
        )
        guard case .success((let session, let canonical)) = validated else {
            if case .failure(let error) = validated { return .failure(error) }
            return .failure(.pathEscape)
        }
        let size = Data(file.content.utf8).count
        if size > AttacheFileContainmentGuard.maxFileBytes {
            return .failure(.fileTooLarge(size: size, max: AttacheFileContainmentGuard.maxFileBytes))
        }
        if isBinary(file.content) { return .failure(.binaryFile) }
        if containsCredentials(file.content, path: canonical) { return .failure(.credentialFile) }
        if reserve.isExhausted { return .failure(.budgetExhausted) }
        let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false)
        let queryLower = query.lowercased()
        var hits: [AttacheFileSearchHit] = []
        let callTokenAllowance = min(reserve.perCallCap, reserve.remainingTokens)
        var callTokensConsumed = 0
        for (index, line) in lines.enumerated() {
            if hits.count >= maxSearchResults { break }
            let availableTokens = callTokenAllowance - callTokensConsumed
            if reserve.isExhausted || availableTokens <= 0 { break }
            if line.lowercased().contains(queryLower) {
                let candidate = String(line.prefix(maxSearchSnippetChars))
                let snippet = boundedContent(candidate, tokenAllowance: availableTokens)
                guard !snippet.isEmpty else { break }
                let tokens = AttacheFallbackTokenEstimator().estimate(text: snippet)
                let consumed = reserve.consume(tokens)
                guard consumed == tokens else { break }
                callTokensConsumed += consumed
                let locator = AttacheFileLocator(
                    sessionID: session.sessionID, sourceKind: session.sourceKind,
                    authorizationEpoch: expectedEpoch, normalizedPath: canonical,
                    lineStart: index + 1, lineEnd: index + 1,
                    charStart: characterOffset(ofLine: index + 1, in: file.content),
                    charEnd: characterOffset(ofLine: index + 1, in: file.content) + snippet.count,
                    contentHash: file.contentHash
                )
                hits.append(AttacheFileSearchHit(
                    locator: locator, snippet: snippet, rank: 1.0,
                    truncation: line.count > snippet.count ? .excerpt : .full
                ))
            }
        }
        return .success(hits)
    }

    /// Read a line range from a file (INF-323). Bounded content with a
    /// locator and continuation. Unique facts from beginning, middle, and end
    /// are retrievable without a whole-file read.
    public static func readRange(
        focusedSession: AttacheFocusedSession?,
        expectedEpoch: AttacheFocusEpoch,
        currentEpoch: AttacheFocusEpoch,
        currentSessionID: String?,
        relativePath: String,
        lineStart: Int,
        maxLines: Int?,
        file: AttacheProjectFile,
        expectedContentHash: String?,
        reserve: inout AttacheToolBudgetReserve,
        policy: AttacheToolBudgetPolicy
    ) -> Result<AttacheFileRangeRead, AttacheFileToolError> {
        let validated = validateAccess(
            focusedSession: focusedSession, expectedEpoch: expectedEpoch,
            currentEpoch: currentEpoch, currentSessionID: currentSessionID,
            relativePath: relativePath, file: file
        )
        guard case .success((let session, let canonical)) = validated else {
            if case .failure(let error) = validated { return .failure(error) }
            return .failure(.pathEscape)
        }
        let size = Data(file.content.utf8).count
        if size > AttacheFileContainmentGuard.maxFileBytes {
            return .failure(.fileTooLarge(size: size, max: AttacheFileContainmentGuard.maxFileBytes))
        }
        if isBinary(file.content) { return .failure(.binaryFile) }
        if containsCredentials(file.content, path: canonical) { return .failure(.credentialFile) }
        if let expected = expectedContentHash, expected != file.contentHash {
            return .failure(.staleFile(expectedHash: expected, actualHash: file.contentHash))
        }
        if reserve.isExhausted { return .failure(.budgetExhausted) }
        let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false)
        let start = max(lineStart - 1, 0) // 1-indexed to 0-indexed
        guard start < lines.count else { return .failure(.fileNotFound) }
        let charLimit = AttacheToolBudgetEnforcer.clampMaxChars(
            maxLines.map { max($0, 1) * 80 }, reserve: reserve, policy: policy
        )
        let requestedLines = max(maxLines ?? max(charLimit / 80, 1), 1)
        let lineLimit = min(requestedLines, lines.count - start)
        let end = min(start + lineLimit, lines.count)
        let requested = lines[start..<end].joined(separator: "\n")
        let prefix = "[Evidence (untrusted file) \(canonical) lines \(start + 1).."
        let included = boundedEvidenceContent(
            String(requested.prefix(charLimit)), prefix: prefix, reserve: reserve
        )
        if included.isEmpty, !requested.isEmpty { return .failure(.budgetExhausted) }
        let absoluteCharStart = characterOffset(ofLine: start + 1, in: file.content)
        let absoluteCharEnd = absoluteCharStart + included.count
        let includedNewlines = included.filter { $0 == "\n" }.count
        let actualLineEnd = start + 1 + includedNewlines
        let endedMidRequestedRange = included.count < requested.count
        let nextLineStart = endedMidRequestedRange ? actualLineEnd : end + 1
        let truncation: AttacheTranscriptTruncation
        let continuation: AttacheFileLocator?
        if absoluteCharEnd >= file.content.count {
            truncation = .full
            continuation = nil
        } else {
            truncation = .excerpt
            continuation = AttacheFileLocator(
                sessionID: session.sessionID, sourceKind: session.sourceKind,
                authorizationEpoch: expectedEpoch, normalizedPath: canonical,
                lineStart: nextLineStart, lineEnd: nextLineStart,
                charStart: absoluteCharEnd, charEnd: absoluteCharEnd,
                contentHash: file.contentHash
            )
        }
        let locator = AttacheFileLocator(
            sessionID: session.sessionID, sourceKind: session.sourceKind,
            authorizationEpoch: expectedEpoch, normalizedPath: canonical,
            lineStart: start + 1, lineEnd: actualLineEnd,
            charStart: absoluteCharStart, charEnd: absoluteCharEnd,
            contentHash: file.contentHash
        )
        let quoted = "\(prefix)\(actualLineEnd): \(included)]"
        _ = reserve.consume(AttacheFallbackTokenEstimator().estimate(text: quoted))
        return .success(AttacheFileRangeRead(
            locator: locator, content: quoted, truncation: truncation,
            continuationLocator: continuation
        ))
    }

    /// Continue from a prior locator without degrading its character offset to
    /// a line-only request. The locator's session, source, epoch, path, and
    /// content hash are all revalidated.
    public static func readRange(
        focusedSession: AttacheFocusedSession?,
        currentEpoch: AttacheFocusEpoch,
        currentSessionID: String?,
        locator: AttacheFileLocator,
        maxChars: Int?,
        file: AttacheProjectFile,
        reserve: inout AttacheToolBudgetReserve,
        policy: AttacheToolBudgetPolicy
    ) -> Result<AttacheFileRangeRead, AttacheFileToolError> {
        guard locator.authorizationEpoch == currentEpoch else {
            return .failure(.authorizationExpired)
        }
        guard let session = focusedSession else { return .failure(.noFocusedSession) }
        guard locator.sessionID == session.sessionID else {
            return .failure(.sessionIdentityMismatch(expected: locator.sessionID, actual: session.sessionID))
        }
        guard locator.sourceKind == session.sourceKind else {
            return .failure(.sourceKindMismatch(expected: locator.sourceKind, actual: session.sourceKind))
        }
        let validated = validateAccess(
            focusedSession: session, expectedEpoch: locator.authorizationEpoch,
            currentEpoch: currentEpoch, currentSessionID: currentSessionID,
            relativePath: locator.normalizedPath, file: file
        )
        guard case .success((_, let canonical)) = validated else {
            if case .failure(let error) = validated { return .failure(error) }
            return .failure(.pathEscape)
        }
        guard canonical == locator.normalizedPath else { return .failure(.pathEscape) }
        guard locator.contentHash == file.contentHash else {
            return .failure(.staleFile(expectedHash: locator.contentHash, actualHash: file.contentHash))
        }
        let size = Data(file.content.utf8).count
        guard size <= AttacheFileContainmentGuard.maxFileBytes else {
            return .failure(.fileTooLarge(size: size, max: AttacheFileContainmentGuard.maxFileBytes))
        }
        if isBinary(file.content) { return .failure(.binaryFile) }
        if containsCredentials(file.content, path: canonical) { return .failure(.credentialFile) }
        guard !reserve.isExhausted else { return .failure(.budgetExhausted) }

        let start = min(max(locator.charStart, 0), file.content.count)
        guard start < file.content.count else { return .failure(.fileNotFound) }
        let limit = AttacheToolBudgetEnforcer.clampMaxChars(maxChars, reserve: reserve, policy: policy)
        let requested = String(file.content.dropFirst(start).prefix(limit))
        let prefix = "[Evidence (untrusted file) \(canonical) from char \(start).."
        let included = boundedEvidenceContent(requested, prefix: prefix, reserve: reserve)
        guard !included.isEmpty || requested.isEmpty else { return .failure(.budgetExhausted) }
        let end = start + included.count
        let startLine = lineNumber(atCharacterOffset: start, in: file.content)
        let endLine = lineNumber(atCharacterOffset: max(end - 1, start), in: file.content)
        let next = end < file.content.count ? AttacheFileLocator(
            sessionID: session.sessionID, sourceKind: session.sourceKind,
            authorizationEpoch: currentEpoch, normalizedPath: canonical,
            lineStart: endLine, lineEnd: endLine, charStart: end, charEnd: end,
            contentHash: file.contentHash
        ) : nil
        let resultLocator = AttacheFileLocator(
            sessionID: session.sessionID, sourceKind: session.sourceKind,
            authorizationEpoch: currentEpoch, normalizedPath: canonical,
            lineStart: startLine, lineEnd: endLine, charStart: start, charEnd: end,
            contentHash: file.contentHash
        )
        let quoted = "\(prefix)\(end): \(included)]"
        _ = reserve.consume(AttacheFallbackTokenEstimator().estimate(text: quoted))
        return .success(AttacheFileRangeRead(
            locator: resultLocator,
            content: quoted,
            truncation: next == nil ? .full : .excerpt,
            continuationLocator: next
        ))
    }

    private static func validateAccess(
        focusedSession: AttacheFocusedSession?,
        expectedEpoch: AttacheFocusEpoch,
        currentEpoch: AttacheFocusEpoch,
        currentSessionID: String?,
        relativePath: String,
        file: AttacheProjectFile
    ) -> Result<(AttacheFocusedSession, String), AttacheFileToolError> {
        guard let session = focusedSession else { return .failure(.noFocusedSession) }
        guard expectedEpoch == currentEpoch,
              session.authorizationEpoch == expectedEpoch else {
            return .failure(.authorizationExpired)
        }
        guard let currentID = currentSessionID else { return .failure(.noFocusedSession) }
        guard currentID == session.sessionID else {
            return .failure(.sessionIdentityMismatch(expected: session.sessionID, actual: currentID))
        }
        guard let workingDir = session.workingDirectory,
              let canonical = AttacheFilePathGuard.canonicalize(relativePath, workingDirectory: workingDir),
              let fileCanonical = AttacheFilePathGuard.canonicalize(file.relativePath, workingDirectory: workingDir),
              canonical == fileCanonical else {
            return .failure(.pathEscape)
        }
        return .success((session, canonical))
    }

    private static func characterOffset(ofLine line: Int, in content: String) -> Int {
        guard line > 1 else { return 0 }
        let components = content.split(separator: "\n", omittingEmptySubsequences: false)
        return components.prefix(line - 1).reduce(0) { $0 + $1.count + 1 }
    }

    private static func lineNumber(atCharacterOffset offset: Int, in content: String) -> Int {
        content.prefix(max(offset, 0)).reduce(1) { count, character in
            character == "\n" ? count + 1 : count
        }
    }

    private static func boundedEvidenceContent(
        _ content: String,
        prefix: String,
        reserve: AttacheToolBudgetReserve
    ) -> String {
        let estimator = AttacheFallbackTokenEstimator()
        let allowance = min(reserve.remainingTokens, reserve.perCallCap)
        guard allowance > estimator.estimate(text: prefix + "1000000000: ]") else { return "" }
        var low = 0
        var high = content.count
        var best = ""
        while low <= high {
            let count = (low + high) / 2
            let candidate = String(content.prefix(count))
            if estimator.estimate(text: prefix + "1000000000: " + candidate + "]") <= allowance {
                best = candidate
                low = count + 1
            } else {
                high = count - 1
            }
        }
        return best
    }

    private static func boundedContent(_ content: String, tokenAllowance: Int) -> String {
        guard tokenAllowance > 0 else { return "" }
        let estimator = AttacheFallbackTokenEstimator()
        var low = 0
        var high = content.count
        var best = ""
        while low <= high {
            let count = (low + high) / 2
            let candidate = String(content.prefix(count))
            if estimator.estimate(text: candidate) <= tokenAllowance {
                best = candidate
                low = count + 1
            } else {
                high = count - 1
            }
        }
        return best
    }

    /// Detect binary content (INF-323). Rejects files with null bytes or a
    /// high proportion of non-text bytes.
    public static func isBinary(_ content: String) -> Bool {
        if content.contains("\0") { return true }
        let sample = content.prefix(1024)
        let nonText = sample.filter { c in
            !c.isLetter && !c.isNumber && !c.isPunctuation && !c.isWhitespace && !c.isSymbol
        }.count
        return Double(nonText) / Double(max(sample.count, 1)) > 0.3
    }

    /// Paths whose normal purpose is storing credentials. Refuse them even when
    /// a token's value is encrypted, templated, or uses a provider format the
    /// content scanner does not yet recognize.
    public static func isSensitiveCredentialPath(_ path: String) -> Bool {
        let normalized = path
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        let components = normalized
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let name = components.last else { return false }

        if name == ".env" || name.hasPrefix(".env.") { return true }
        if components.contains(".ssh") || components.contains(".aws")
            || components.contains(".gnupg") {
            return true
        }

        let exactNames: Set<String> = [
            ".npmrc", ".pypirc", ".netrc", ".authinfo", ".git-credentials",
            ".dockercfg", "auth.json", "credentials", "credentials.json",
            "secrets", "secrets.json", "secrets.yml", "secrets.yaml",
            "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"
        ]
        if exactNames.contains(name) { return true }
        if name.contains("service-account") || name.contains("service_account") {
            return true
        }
        return [".pem", ".key", ".p12", ".pfx", ".jks", ".keystore"]
            .contains { name.hasSuffix($0) }
    }

    /// Detect credential/key material (INF-323). Every file-returning tool calls
    /// this same guard, including continuation reads.
    public static func containsCredentials(_ content: String, path: String? = nil) -> Bool {
        if let path, isSensitiveCredentialPath(path) { return true }
        let lower = content.lowercased()
        if credentialPatterns.contains(where: { lower.contains($0) }) { return true }
        if credentialAssignmentLeadIns.contains(where: { lower.contains($0) }),
           content.range(of: credentialAssignmentPattern, options: .regularExpression) != nil {
            return true
        }
        return credentialValueLeadIns.contains(where: { lower.contains($0) })
            && content.range(of: credentialValuePattern, options: .regularExpression) != nil
    }

    /// Redact secrets defensively (INF-323). Does not claim perfect detection.
    public static func redactSecrets(_ content: String) -> String {
        content.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            containsCredentials(String(line)) ? "[REDACTED]" : String(line)
        }.joined(separator: "\n")
    }

    /// Detect file type from extension (INF-323).
    public static func detectFileType(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "py": return "python"
        case "js", "ts": return "javascript"
        case "json": return "json"
        case "md": return "markdown"
        case "sh": return "shell"
        case "yml", "yaml": return "yaml"
        case "txt": return "text"
        case "": return "unknown"
        default: return ext
        }
    }
}
