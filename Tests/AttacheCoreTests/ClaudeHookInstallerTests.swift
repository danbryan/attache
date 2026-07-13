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
}
