import XCTest
@testable import AttacheCore

final class ClaudeHookInstallerTests: XCTestCase {
    private let script = "/Users/x/Library/Application Support/Attache/hooks/attache-hook.sh"
    private var entries: [ClaudeHookInstaller.Entry] {
        [
            .init(event: "Notification", command: "'\(script)' needs_attention"),
            .init(event: "Stop", command: "'\(script)' turn_complete")
        ]
    }

    private func parse(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func commands(_ settings: [String: Any], event: String) -> [String] {
        let hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        let list = (hooks[event] as? [[String: Any]]) ?? []
        return list.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
    }

    func testInstallIntoEmptyAddsBothEvents() throws {
        let out = try ClaudeHookInstaller.settings(byInstalling: entries, into: nil, managedScriptPath: script)
        let s = parse(out)
        XCTAssertEqual(commands(s, event: "Notification"), ["'\(script)' needs_attention"])
        XCTAssertEqual(commands(s, event: "Stop"), ["'\(script)' turn_complete"])
    }

    func testInstallPreservesOtherKeysAndHooks() throws {
        let existing = """
        {"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/local/bin/audit"}]}]}}
        """.data(using: .utf8)
        let out = try ClaudeHookInstaller.settings(byInstalling: entries, into: existing, managedScriptPath: script)
        let s = parse(out)
        XCTAssertEqual(s["model"] as? String, "opus", "unrelated top-level keys survive")
        XCTAssertEqual(commands(s, event: "PreToolUse"), ["/usr/local/bin/audit"], "the user's own hook survives")
        XCTAssertEqual(commands(s, event: "Stop"), ["'\(script)' turn_complete"])
    }

    func testInstallIsIdempotent() throws {
        let once = try ClaudeHookInstaller.settings(byInstalling: entries, into: nil, managedScriptPath: script)
        let twice = try ClaudeHookInstaller.settings(byInstalling: entries, into: once, managedScriptPath: script)
        XCTAssertEqual(commands(parse(twice), event: "Notification").count, 1, "no duplicate managed entry")
        XCTAssertEqual(commands(parse(twice), event: "Stop").count, 1)
    }

    func testInstallKeepsUsersOwnNotificationHook() throws {
        let existing = """
        {"hooks":{"Notification":[{"hooks":[{"type":"command","command":"/usr/local/bin/notify-me"}]}]}}
        """.data(using: .utf8)
        let out = try ClaudeHookInstaller.settings(byInstalling: entries, into: existing, managedScriptPath: script)
        let notif = commands(parse(out), event: "Notification")
        XCTAssertTrue(notif.contains("/usr/local/bin/notify-me"), "the user's Notification hook is kept")
        XCTAssertTrue(notif.contains("'\(script)' needs_attention"), "ours is added alongside")
        XCTAssertEqual(notif.count, 2)
    }

    func testUninstallRemovesOnlyManaged() throws {
        let installed = try ClaudeHookInstaller.settings(
            byInstalling: entries,
            into: """
            {"model":"opus","hooks":{"Notification":[{"hooks":[{"type":"command","command":"/usr/local/bin/notify-me"}]}]}}
            """.data(using: .utf8),
            managedScriptPath: script)
        let cleaned = try ClaudeHookInstaller.settings(byRemovingManagedFrom: installed, managedScriptPath: script)
        let s = parse(cleaned)
        XCTAssertEqual(s["model"] as? String, "opus")
        XCTAssertEqual(commands(s, event: "Notification"), ["/usr/local/bin/notify-me"], "only ours removed")
        XCTAssertNil((s["hooks"] as? [String: Any])?["Stop"], "the event we solely owned is dropped")
    }

    func testUninstallToEmptyDropsHooksKey() throws {
        let installed = try ClaudeHookInstaller.settings(byInstalling: entries, into: nil, managedScriptPath: script)
        let cleaned = try ClaudeHookInstaller.settings(byRemovingManagedFrom: installed, managedScriptPath: script)
        XCTAssertNil(parse(cleaned)["hooks"], "no empty hooks object left behind")
    }

    func testIsUpToDate() throws {
        XCTAssertFalse(ClaudeHookInstaller.isUpToDate(nil, entries: entries, managedScriptPath: script))
        let installed = try ClaudeHookInstaller.settings(byInstalling: entries, into: nil, managedScriptPath: script)
        XCTAssertTrue(ClaudeHookInstaller.isUpToDate(installed, entries: entries, managedScriptPath: script))
    }

    // MARK: - Guarded command migration (INF-369)

    /// Old, unguarded managed entries: bare `'<path>' <type>`, no missing-script guard.
    private func unguardedEntries(script: String) -> [ClaudeHookInstaller.Entry] {
        [
            .init(event: "Notification", command: "'\(script)' needs_attention"),
            .init(event: "Stop", command: "'\(script)' turn_complete")
        ]
    }

    /// New, guarded managed entries: silent no-op when the script is missing.
    private func guardedEntries(script: String) -> [ClaudeHookInstaller.Entry] {
        [
            .init(event: "Notification", command: "[ -x '\(script)' ] && '\(script)' needs_attention || true"),
            .init(event: "Stop", command: "[ -x '\(script)' ] && '\(script)' turn_complete || true")
        ]
    }

    func testIsManagedRecognizesOldUnguardedForm() {
        let matcher: [String: Any] = [
            "hooks": [["type": "command", "command": "'\(script)' turn_complete"]]
        ]
        XCTAssertTrue(ClaudeHookInstaller.isManaged(matcher, scriptPath: script))
    }

    func testIsManagedRecognizesNewGuardedForm() {
        let matcher: [String: Any] = [
            "hooks": [["type": "command", "command": "[ -x '\(script)' ] && '\(script)' turn_complete || true"]]
        ]
        XCTAssertTrue(ClaudeHookInstaller.isManaged(matcher, scriptPath: script))
    }

    func testInstallMigratesOldUnguardedEntriesToGuardedAndPreservesUserHooks() throws {
        // A settings.json that already has Attaché's OLD unguarded entries plus
        // the user's own tmux hooks (byte-sensitive: must survive untouched).
        let tmuxCommand = "/opt/homebrew/bin/tmux display-message 'claude done'"
        let existing = try ClaudeHookInstaller.settings(
            byInstalling: unguardedEntries(script: script),
            into: """
            {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\(tmuxCommand)"}]}]}}
            """.data(using: .utf8),
            managedScriptPath: script)

        let migrated = try ClaudeHookInstaller.settings(
            byInstalling: guardedEntries(script: script),
            into: existing,
            managedScriptPath: script)
        let s = parse(migrated)

        let stopCommands = commands(s, event: "Stop")
        XCTAssertTrue(stopCommands.contains(tmuxCommand), "the user's own tmux hook must survive byte-untouched")
        XCTAssertTrue(stopCommands.contains("[ -x '\(script)' ] && '\(script)' turn_complete || true"),
                      "the guarded form must be present")
        XCTAssertFalse(stopCommands.contains("'\(script)' turn_complete"),
                        "the old unguarded form must be removed, not left alongside the guarded one")

        let notifCommands = commands(s, event: "Notification")
        XCTAssertEqual(notifCommands, ["[ -x '\(script)' ] && '\(script)' needs_attention || true"])
        XCTAssertFalse(notifCommands.contains("'\(script)' needs_attention"))
    }
}
