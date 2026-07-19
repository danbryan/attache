import XCTest
@testable import AttacheCore

/// The pure config-edit matrix for Codex notify chaining: fresh install,
/// chaining an existing entry, idempotent re-install, remove-restore, and
/// fail-closed on a malformed file. All fixtures are TOML strings; nothing here
/// touches the real `~/.codex/config.toml`.
final class CodexNotifyInstallerTests: XCTestCase {
    private let managed = "/Users/x/Library/Application Support/Attache/hooks/attache-codex-notify.sh"

    // MARK: Fresh install (no notify present)

    func testInstallFreshWhenNoNotify() throws {
        let toml = """
        model = "gpt-5"
        approval_policy = "on-request"

        [mcp_servers.linear]
        command = "linear-mcp"
        """
        let result = try CodexNotifyInstaller.install(toml, managedProgramPath: managed)
        XCTAssertTrue(result.changed)
        XCTAssertNil(result.previousNotify)

        let notify = try CodexNotifyInstaller.currentNotify(in: result.toml)
        XCTAssertEqual(notify, [managed])
        // No previous flag when there was nothing to chain.
        XCTAssertFalse(result.toml.contains(CodexNotifyInstaller.previousFlag))
        // The rest of the file survives, and notify lands at root scope (before
        // the first table header).
        XCTAssertTrue(result.toml.contains("model = \"gpt-5\""))
        XCTAssertTrue(result.toml.contains("[mcp_servers.linear]"))
        let notifyLine = result.toml.components(separatedBy: "\n").firstIndex { $0.hasPrefix("notify") }
        let headerLine = result.toml.components(separatedBy: "\n").firstIndex { $0.hasPrefix("[mcp_servers") }
        XCTAssertNotNil(notifyLine)
        XCTAssertNotNil(headerLine)
        XCTAssertLessThan(notifyLine!, headerLine!)
    }

    func testInstallFreshIntoEmptyFile() throws {
        let result = try CodexNotifyInstaller.install("", managedProgramPath: managed)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(try CodexNotifyInstaller.currentNotify(in: result.toml), [managed])
    }

    // MARK: Chaining an existing notify

    func testInstallChainsExistingNotify() throws {
        let previous = ["/opt/tool/Notifier", "turn-ended", "--previous-notify", "[\"/usr/bin/true\",\"turn-ended\"]"]
        let toml = "notify = [\"/opt/tool/Notifier\", \"turn-ended\", \"--previous-notify\", \"[\\\"/usr/bin/true\\\",\\\"turn-ended\\\"]\"]\nmodel = \"gpt-5\"\n"

        // Sanity: the fixture parses to the exact previous array.
        XCTAssertEqual(try CodexNotifyInstaller.currentNotify(in: toml), previous)

        let result = try CodexNotifyInstaller.install(toml, managedProgramPath: managed)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.previousNotify, previous)

        let notify = try CodexNotifyInstaller.currentNotify(in: result.toml)
        XCTAssertEqual(notify?.first, managed)
        XCTAssertEqual(notify?[safe: 1], CodexNotifyInstaller.previousFlag)
        // The chained value decodes back to exactly the previous command.
        XCTAssertEqual(CodexNotifyInstaller.embeddedPrevious(in: notify ?? []), previous)
        // Unrelated content preserved.
        XCTAssertTrue(result.toml.contains("model = \"gpt-5\""))
    }

    // MARK: Idempotent verify

    func testReinstallIsIdempotent() throws {
        let previous = ["/opt/tool/Notifier", "turn-ended"]
        let toml = "notify = [\"/opt/tool/Notifier\", \"turn-ended\"]\n"
        let once = try CodexNotifyInstaller.install(toml, managedProgramPath: managed)
        XCTAssertTrue(try CodexNotifyInstaller.isInstalled(once.toml, managedProgramPath: managed))

        let twice = try CodexNotifyInstaller.install(once.toml, managedProgramPath: managed)
        XCTAssertFalse(twice.changed, "re-install must not rewrite an already-managed file")
        XCTAssertEqual(twice.toml, once.toml, "content must be byte-stable on re-install")
        // The previous stays the originally-captured command, never Attaché's own.
        XCTAssertEqual(twice.previousNotify, previous)
    }

    // MARK: Remove restores the recorded previous

    func testRemoveRestoresChainedPrevious() throws {
        let previous = ["/opt/tool/Notifier", "turn-ended"]
        let toml = "notify = [\"/opt/tool/Notifier\", \"turn-ended\"]\nmodel = \"gpt-5\"\n"
        let installed = try CodexNotifyInstaller.install(toml, managedProgramPath: managed)

        let removed = try CodexNotifyInstaller.remove(installed.toml, managedProgramPath: managed)
        XCTAssertEqual(try CodexNotifyInstaller.currentNotify(in: removed), previous)
        XCTAssertFalse(try CodexNotifyInstaller.isInstalled(removed, managedProgramPath: managed))
        XCTAssertTrue(removed.contains("model = \"gpt-5\""))
    }

    func testRemoveDeletesKeyWhenNoPrevious() throws {
        let toml = "model = \"gpt-5\"\n"
        let installed = try CodexNotifyInstaller.install(toml, managedProgramPath: managed)
        XCTAssertTrue(try CodexNotifyInstaller.isInstalled(installed.toml, managedProgramPath: managed))

        let removed = try CodexNotifyInstaller.remove(installed.toml, managedProgramPath: managed)
        XCTAssertNil(try CodexNotifyInstaller.currentNotify(in: removed))
        XCTAssertFalse(removed.contains("notify"))
        XCTAssertTrue(removed.contains("model = \"gpt-5\""))
    }

    func testRemoveLeavesForeignNotifyUntouched() throws {
        let toml = "notify = [\"/opt/tool/Notifier\", \"turn-ended\"]\n"
        let removed = try CodexNotifyInstaller.remove(toml, managedProgramPath: managed)
        XCTAssertEqual(removed, toml, "a notify entry that is not Attaché's must never be edited")
    }

    // MARK: Malformed: fail closed, never write

    func testMalformedUnterminatedArrayThrows() {
        let toml = "notify = [\"/opt/tool/Notifier\", \"turn-ended\"\nmodel = \"gpt-5\"\n"
        XCTAssertThrowsError(try CodexNotifyInstaller.currentNotify(in: toml)) { error in
            XCTAssertEqual(error as? CodexNotifyInstaller.Failure, .malformed)
        }
        XCTAssertThrowsError(try CodexNotifyInstaller.install(toml, managedProgramPath: managed))
        XCTAssertThrowsError(try CodexNotifyInstaller.remove(toml, managedProgramPath: managed))
    }

    func testMalformedNonArrayNotifyThrows() {
        let toml = "notify = \"just-a-string\"\n"
        XCTAssertThrowsError(try CodexNotifyInstaller.install(toml, managedProgramPath: managed)) { error in
            XCTAssertEqual(error as? CodexNotifyInstaller.Failure, .malformed)
        }
    }

    // MARK: Root/table discrimination

    func testNotifyInsideTableIsNotRootNotify() throws {
        let toml = """
        model = "gpt-5"

        [some_table]
        notify = ["x"]
        """
        // The only `notify` here belongs to a table, not the root key.
        XCTAssertNil(try CodexNotifyInstaller.currentNotify(in: toml))
        let result = try CodexNotifyInstaller.install(toml, managedProgramPath: managed)
        // Fresh install adds a root notify above the table, leaving the table's own key intact.
        XCTAssertEqual(try CodexNotifyInstaller.currentNotify(in: result.toml), [managed])
        XCTAssertTrue(result.toml.contains("[some_table]"))
        XCTAssertTrue(result.toml.contains("notify = [\"x\"]"))
    }

    // MARK: Byte preservation of surrounding content

    func testInstallPreservesCommentsAndBlankLines() throws {
        let toml = "# top comment\n\nmodel = \"gpt-5\"  # inline\n\n[profile]\nname = \"dan\"\n"
        let result = try CodexNotifyInstaller.install(toml, managedProgramPath: managed)
        XCTAssertTrue(result.toml.contains("# top comment"))
        XCTAssertTrue(result.toml.contains("model = \"gpt-5\"  # inline"))
        XCTAssertTrue(result.toml.contains("[profile]"))
        XCTAssertTrue(result.toml.contains("name = \"dan\""))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
