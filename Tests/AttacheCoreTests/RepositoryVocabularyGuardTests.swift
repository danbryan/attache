import XCTest

/// Repo-wide vocabulary guard. Several retired terms are banned in every tracked
/// file; each rename shipped before any external users existed, so no
/// compatibility carve-out survives. Each check runs `git grep` at the repo root
/// and fails listing any offending file.
///
/// Every forbidden token is assembled by concatenation so this source file never
/// contains a literal banned word and can never flag itself.
final class RepositoryVocabularyGuardTests: XCTestCase {

    /// The retired pre-Attaché name for the app (any case, substring).
    func testRetiredAppNameIsAbsent() throws {
        try assertNoMatches(
            pattern: "com" + "panion",
            flags: ["-i"],
            label: "the retired pre-Attaché app name"
        )
    }

    /// The retired closet metaphor for the character set (any case, whole word,
    /// so identifiers that merely contain the fragment are not the target here;
    /// the rename removed those too).
    func testRetiredCharacterSetNounIsAbsent() throws {
        try assertNoMatches(
            pattern: "ward" + "robe",
            flags: ["-i", "-w"],
            label: "the retired character-set noun"
        )
    }

    /// The legacy pet-character personality/defaults key (exact, case-sensitive).
    func testRetiredPetCharacterKeyIsAbsent() throws {
        try assertNoMatches(
            pattern: "pet" + "Character",
            flags: [],
            label: "the legacy pet-character key"
        )
    }

    /// Runs `git grep <flags> -l -e <pattern>` at the repo root and fails if any
    /// tracked file matches. Skips cleanly when git or a worktree is unavailable.
    private func assertNoMatches(pattern: String, flags: [String], label: String) throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AttacheCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root

        let git = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.fileExists(atPath: git.path) else {
            throw XCTSkip("git is unavailable; skipping repository vocabulary guard")
        }
        guard FileManager.default.fileExists(
            atPath: repoRoot.appendingPathComponent(".git").path
        ) else {
            throw XCTSkip("no git worktree at repo root; skipping repository vocabulary guard")
        }

        let process = Process()
        process.executableURL = git
        process.currentDirectoryURL = repoRoot
        process.arguments = ["grep"] + flags + ["-l", "-e", pattern]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // git grep exits 1 with no matches (success for us), 0 when it finds any.
        let offenders = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }

        XCTAssertTrue(
            offenders.isEmpty,
            "\(label) must not appear in tracked files. Offending files:\n"
                + offenders.joined(separator: "\n")
        )
    }
}
