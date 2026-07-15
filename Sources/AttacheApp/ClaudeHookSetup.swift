import AttacheCore
import Foundation

/// Installs (and removes) the Claude Code lifecycle hooks that give the character its
/// exact status. It writes a small, self-contained hook script into Attaché's
/// Application Support directory and merges two entries into Claude Code's
/// `settings.json` (a `Notification` hook for "waiting on you" and a `Stop`
/// hook for "turn done"), preserving everything else. The pure merge and the
/// idempotency check live in `ClaudeHookInstaller`; this is the file IO.
enum ClaudeHookSetup {
    static var hooksDirectory: URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Attache/hooks", isDirectory: true)
    }

    static var scriptURL: URL { hooksDirectory.appendingPathComponent("attache-hook.sh") }

    static var settingsURL: URL {
        ClaudePaths.home().appendingPathComponent("settings.json")
    }

    static var entries: [ClaudeHookInstaller.Entry] {
        let path = scriptURL.path
        func entry(_ event: String, _ type: String) -> ClaudeHookInstaller.Entry {
            .init(event: event, command: "'\(path)' \(type)")
        }
        return [
            entry("UserPromptSubmit", "turn_started"),   // instant "working"
            entry("Stop", "turn_complete"),               // done
            entry("StopFailure", "turn_failed"),          // errored
            entry("Notification", "needs_attention"),     // needs you
            entry("SessionStart", "session_start"),       // greet
            entry("SessionEnd", "session_end"),           // farewell
            entry("Setup", "session_setup"),              // configuring
            entry("PreCompact", "compact_start"),         // squish begins
            entry("PostCompact", "compact_end"),          // squish releases
            entry("PermissionRequest", "permission_ask"), // choose flags
            entry("PermissionDenied", "permission_denied")// red flag shake
        ]
    }

    /// Apply the user's preference. On enable, ensure the script and the
    /// settings entries exist; on disable, remove only Attaché's entries.
    /// Best-effort: never throws into the caller, and never blocks a real user
    /// prompt (the script is fire-and-forget and silent).
    static func apply(enabled: Bool) {
        do {
            if enabled {
                try writeScript()
                try updateSettings { current in
                    ClaudeHookInstaller.isUpToDate(current, entries: entries, managedScriptPath: scriptURL.path)
                        ? nil
                        : try ClaudeHookInstaller.settings(byInstalling: entries, into: current, managedScriptPath: scriptURL.path)
                }
            } else {
                try updateSettings { current in
                    guard current != nil else { return nil }
                    let cleaned = try ClaudeHookInstaller.settings(byRemovingManagedFrom: current, managedScriptPath: scriptURL.path)
                    return cleaned == current ? nil : cleaned
                }
            }
        } catch {
            AttacheLog.watcher.error("claude hook setup (enabled=\(enabled, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Internals

    private static func writeScript() throws {
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        let data = Data(scriptBody.utf8)
        // Rewrite only when the content changed, so we do not churn the file.
        if (try? Data(contentsOf: scriptURL)) != data {
            try data.write(to: scriptURL, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// Read the current settings.json (nil if absent), let `transform` compute a
    /// replacement (nil means "no change needed"), then back up and write.
    private static func updateSettings(_ transform: (Data?) throws -> Data?) throws {
        let current = try? Data(contentsOf: settingsURL)
        guard let next = try transform(current) else { return }
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let current {
            // Keep one step of recovery next to the file we are about to edit.
            try? current.write(to: settingsURL.appendingPathExtension("attache.bak"), options: .atomic)
        }
        try next.write(to: settingsURL, options: .atomic)
    }

    // The Python is single-line (no indentation-sensitive blocks) and the whole
    // script is assembled line by line, so nothing depends on how a string
    // literal strips whitespace and the `#!` shebang is guaranteed at column 0.
    static let sessionIDPython =
        "import json,sys,os; d=json.load(sys.stdin); t=d.get('transcript_path') or ''; "
        + "print((d.get('session_id') or '') or (os.path.splitext(os.path.basename(t))[0] if t else ''))"
    static let cwdPython = "import json,sys; print(json.load(sys.stdin).get('cwd',''))"
    static let bodyPython =
        "import json,sys; print(json.dumps({'source':'claude_code','event_type':sys.argv[1],"
        + "'external_session_id':sys.argv[2],'project_path':sys.argv[3],'title':'Claude Code',"
        + "'text':'','metadata':{'adapter':'claude-hook'}}))"

    /// Fire-and-forget: extract the session id (falling back to the transcript
    /// filename), read the per-launch token, POST the event, and get out of the
    /// way. All output is suppressed so it can never alter a Claude turn, and it
    /// always exits 0 so it can never block a prompt or a stop.
    static var scriptBody: String {
        [
            "#!/bin/bash",
            "# Attaché Claude Code hook (managed by Attaché; safe to delete).",
            "# Reports the session's exact status to the local Attaché app; silent, non-blocking.",
            "{",
            "  ET=\"$1\"",
            "  [ -z \"$ET\" ] && exit 0",
            "  PORT=\"${ATTACHE_EVENT_PORT:-7531}\"",
            "  IN=\"$(cat)\"",
            "  SID=\"$(printf '%s' \"$IN\" | /usr/bin/python3 -c \"\(sessionIDPython)\" 2>/dev/null)\"",
            "  [ -z \"$SID\" ] && exit 0",
            "  CWD=\"$(printf '%s' \"$IN\" | /usr/bin/python3 -c \"\(cwdPython)\" 2>/dev/null)\"",
            "  TF=\"$HOME/Library/Application Support/Attache/event-token\"",
            "  [ -f \"$TF\" ] || exit 0",
            "  TOKEN=\"$(cat \"$TF\")\"",
            "  BODY=\"$(/usr/bin/python3 -c \"\(bodyPython)\" \"$ET\" \"$SID\" \"$CWD\" 2>/dev/null)\"",
            "  [ -z \"$BODY\" ] && exit 0",
            "  /usr/bin/curl -sS -m 2 -X POST \"http://127.0.0.1:$PORT/events\""
                + " -H 'Content-Type: application/json' -H \"Authorization: Bearer $TOKEN\""
                + " --data-binary \"$BODY\" >/dev/null 2>&1",
            "} >/dev/null 2>&1",
            "exit 0",
            ""
        ].joined(separator: "\n")
    }
}
