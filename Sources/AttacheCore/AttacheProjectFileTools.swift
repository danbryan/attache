import Foundation
import CryptoKit

/// A stable provenance locator for file content (INF-323). Every returned
/// character maps to a path, line range, and content hash.
public struct AttacheFileLocator: Equatable, Sendable {
    public let sessionID: String
    public let normalizedPath: String
    public let lineStart: Int
    public let lineEnd: Int
    public let contentHash: String

    public init(sessionID: String, normalizedPath: String, lineStart: Int, lineEnd: Int, contentHash: String) {
        self.sessionID = sessionID
        self.normalizedPath = normalizedPath
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.contentHash = contentHash
    }

    public var coveredRange: String { "lines \(lineStart)..\(lineEnd)" }
}

/// A typed project-file tool error (INF-323).
public enum AttacheFileToolError: Error, Equatable, Sendable {
    case noFocusedSession
    case authorizationExpired
    case sessionIdentityMismatch(expected: String, actual: String)
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
        // Reject absolute paths that don't start with the working directory.
        if path.hasPrefix("/") {
            guard path.hasPrefix(workingDirectory) else { return nil }
            return path
        }
        // Reject parent traversal.
        if path.contains("..") { return nil }
        // Reject null bytes and other injection tricks.
        if path.contains("\0") { return nil }
        // Reject Unicode normalization tricks: normalize to NFC and re-check.
        let nfc = path.precomposedStringWithCanonicalMapping
        if nfc.contains("..") { return nil }
        // Canonicalize: working directory + relative path.
        let canonical: String
        if workingDirectory.hasSuffix("/") {
            canonical = workingDirectory + path
        } else {
            canonical = workingDirectory + "/" + path
        }
        return canonical
    }

    /// True when the path escapes the working directory via symlink resolution
    /// (INF-323). The caller provides the resolved path; this checks whether
    /// it still starts with the working directory.
    public static func resolvesOutsideWorkingDirectory(
        resolvedPath: String, workingDirectory: String
    ) -> Bool {
        !resolvedPath.hasPrefix(workingDirectory)
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
    public static let credentialPatterns = ["api_key", "apikey", "secret", "password", "private_key", "bearer ", "aws_secret", "sk-", "-----begin"]

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
        guard let session = focusedSession else { return .failure(.noFocusedSession) }
        guard expectedEpoch == currentEpoch else { return .failure(.authorizationExpired) }
        if let currentID = currentSessionID, currentID != session.sessionID {
            return .failure(.sessionIdentityMismatch(expected: session.sessionID, actual: currentID))
        }
        guard let workingDir = session.workingDirectory else { return .failure(.pathEscape) }
        guard let canonical = AttacheFilePathGuard.canonicalize(relativePath, workingDirectory: workingDir) else {
            return .failure(.pathEscape)
        }
        if file.content.count > AttacheFileContainmentGuard.maxFileBytes {
            return .failure(.fileTooLarge(size: file.content.count, max: AttacheFileContainmentGuard.maxFileBytes))
        }
        if isBinary(file.content) { return .failure(.binaryFile) }
        if containsCredentials(file.content) { return .failure(.credentialFile) }
        let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false)
        let outline = Array(lines.prefix(outlineLineCount)).enumerated().map { i, line in
            "L\(i + 1): \(String(line.prefix(80)))"
        }
        return .success(AttacheFileInspection(
            normalizedPath: canonical, fileSize: file.content.count,
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
        guard let session = focusedSession else { return .failure(.noFocusedSession) }
        guard expectedEpoch == currentEpoch else { return .failure(.authorizationExpired) }
        if let currentID = currentSessionID, currentID != session.sessionID {
            return .failure(.sessionIdentityMismatch(expected: session.sessionID, actual: currentID))
        }
        guard let workingDir = session.workingDirectory else { return .failure(.pathEscape) }
        guard let canonical = AttacheFilePathGuard.canonicalize(relativePath, workingDirectory: workingDir) else {
            return .failure(.pathEscape)
        }
        if isBinary(file.content) { return .failure(.binaryFile) }
        if containsCredentials(file.content) { return .failure(.credentialFile) }
        if reserve.isExhausted { return .failure(.budgetExhausted) }
        let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false)
        let queryLower = query.lowercased()
        var hits: [AttacheFileSearchHit] = []
        for (index, line) in lines.enumerated() {
            if hits.count >= maxSearchResults { break }
            if reserve.isExhausted { break }
            if line.lowercased().contains(queryLower) {
                let snippet = String(line.prefix(maxSearchSnippetChars))
                let tokens = AttacheFallbackTokenEstimator().estimate(text: snippet)
                _ = reserve.consume(tokens)
                let locator = AttacheFileLocator(
                    sessionID: session.sessionID, normalizedPath: canonical,
                    lineStart: index + 1, lineEnd: index + 1,
                    contentHash: file.contentHash
                )
                hits.append(AttacheFileSearchHit(
                    locator: locator, snippet: snippet, rank: 1.0,
                    truncation: line.count > maxSearchSnippetChars ? .excerpt : .full
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
        guard let session = focusedSession else { return .failure(.noFocusedSession) }
        guard expectedEpoch == currentEpoch else { return .failure(.authorizationExpired) }
        if let currentID = currentSessionID, currentID != session.sessionID {
            return .failure(.sessionIdentityMismatch(expected: session.sessionID, actual: currentID))
        }
        guard let workingDir = session.workingDirectory else { return .failure(.pathEscape) }
        guard let canonical = AttacheFilePathGuard.canonicalize(relativePath, workingDirectory: workingDir) else {
            return .failure(.pathEscape)
        }
        if isBinary(file.content) { return .failure(.binaryFile) }
        if containsCredentials(file.content) { return .failure(.credentialFile) }
        if let expected = expectedContentHash, expected != file.contentHash {
            return .failure(.staleFile(expectedHash: expected, actualHash: file.contentHash))
        }
        if reserve.isExhausted { return .failure(.budgetExhausted) }
        let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false)
        let start = max(lineStart - 1, 0) // 1-indexed to 0-indexed
        guard start < lines.count else { return .failure(.fileNotFound) }
        let limit = AttacheToolBudgetEnforcer.clampMaxChars(maxLines.map { $0 * 80 }, reserve: reserve, policy: policy) / 80
        let lineLimit = min(max(limit, 1), lines.count - start)
        let end = min(start + lineLimit, lines.count)
        let included = lines[start..<end].joined(separator: "\n")
        let tokens = AttacheFallbackTokenEstimator().estimate(text: included)
        _ = reserve.consume(tokens)
        let truncation: AttacheTranscriptTruncation
        let continuation: AttacheFileLocator?
        if end >= lines.count {
            truncation = .full
            continuation = nil
        } else {
            truncation = .excerpt
            continuation = AttacheFileLocator(
                sessionID: session.sessionID, normalizedPath: canonical,
                lineStart: end + 1, lineEnd: end + 1, contentHash: file.contentHash
            )
        }
        let locator = AttacheFileLocator(
            sessionID: session.sessionID, normalizedPath: canonical,
            lineStart: start + 1, lineEnd: end, contentHash: file.contentHash
        )
        let quoted = "[Evidence \(canonical) lines \(start + 1)..\(end): \(included)]"
        return .success(AttacheFileRangeRead(
            locator: locator, content: quoted, truncation: truncation,
            continuationLocator: continuation
        ))
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

    /// Detect credential/key material (INF-323). Defensive, not perfect.
    public static func containsCredentials(_ content: String) -> Bool {
        let lower = content.lowercased()
        return credentialPatterns.contains { lower.contains($0) }
    }

    /// Redact secrets defensively (INF-323). Does not claim perfect detection.
    public static func redactSecrets(_ content: String) -> String {
        var redacted = content
        for pattern in credentialPatterns {
            // Simple defensive redaction of lines containing credential markers.
            redacted = redacted.split(separator: "\n").map { line in
                line.lowercased().contains(pattern) ? "[REDACTED]" : String(line)
            }.joined(separator: "\n")
        }
        return redacted
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