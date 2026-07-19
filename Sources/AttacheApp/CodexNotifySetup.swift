import AttacheCore
import Foundation

/// Installs (and removes) the Codex `notify` program that gives the character
/// its exact Codex turn status, the Codex analog of `ClaudeHookSetup`. It writes
/// a small, self-contained notify script into Attaché's Application Support
/// directory and edits Codex's `config.toml` `notify` array, CHAINING any notify
/// program that was already configured rather than clobbering it. The pure TOML
/// merge lives in `CodexNotifyInstaller`; this is the file IO.
///
/// Codex invokes the notify program on turn events, appending its JSON payload
/// as the final argument. Attaché's script forwards a compact event to the local
/// event server over the same token-guarded transport the Claude hook uses, then
/// execs the recorded previous notify program (with the original payload) so
/// existing notify consumers keep working. Fail-safe: transcript tailing
/// (`SessionActivityWatcher`) is the fallback and is never disturbed by this.
enum CodexNotifySetup {
    static var hooksDirectory: URL { ClaudeHookSetup.hooksDirectory }

    static var scriptURL: URL { hooksDirectory.appendingPathComponent("attache-codex-notify.sh") }

    static var configURL: URL { CodexPaths.configTOMLURL() }

    /// Apply the user's preference. On enable, ensure the notify script exists
    /// and Attaché's chained entry is present in `config.toml`; on disable,
    /// restore the recorded previous notify (or delete the key). Best-effort:
    /// never throws into the caller, and it fails closed on a malformed config
    /// (leaves the file untouched) so transcript tailing simply continues.
    static func apply(enabled: Bool) {
        do {
            if enabled {
                try writeScript()
                try updateConfig { current in
                    let toml = current ?? ""
                    let result = try CodexNotifyInstaller.install(toml, managedProgramPath: scriptURL.path)
                    return result.changed ? result.toml : nil
                }
            } else {
                try updateConfig { current in
                    guard let current else { return nil }
                    let cleaned = try CodexNotifyInstaller.remove(current, managedProgramPath: scriptURL.path)
                    return cleaned == current ? nil : cleaned
                }
            }
        } catch {
            AttacheLog.watcher.error("codex notify setup (enabled=\(enabled, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Internals

    private static func writeScript() throws {
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        let data = Data(scriptBody.utf8)
        if (try? Data(contentsOf: scriptURL)) != data {
            try data.write(to: scriptURL, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// Read the current config.toml (nil if absent), let `transform` compute a
    /// replacement (nil means "no change needed"), then back up and write. A
    /// throwing transform (malformed config) leaves the file untouched.
    private static func updateConfig(_ transform: (String?) throws -> String?) throws {
        let current = (try? Data(contentsOf: configURL)).flatMap { String(data: $0, encoding: .utf8) }
        guard let next = try transform(current) else { return }
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let current {
            // Keep one step of recovery next to the file we are about to edit.
            try? Data(current.utf8).write(to: configURL.appendingPathExtension("attache.bak"), options: .atomic)
        }
        try Data(next.utf8).write(to: configURL, options: .atomic)
    }

    // The python is single-line (no indentation-sensitive blocks) so it inlines
    // straight into `python3 -c "..."`, and the whole script is assembled line
    // by line, so the `#!` shebang is guaranteed at column 0. Both one-liners
    // use only single quotes so they embed inside the bash double-quoted `-c`
    // argument without escaping.
    //
    // Codex's notify payload is a JSON object; the keys are verified against the
    // real Codex binary: `type` ("agent-turn-complete"), `thread-id` (the
    // session id, matching the rollout filename UUID Attaché keys sessions by),
    // `cwd`, and `last-assistant-message`. Only `agent-turn-complete` maps to a
    // status event ("turn_complete"); anything else prints nothing (no forward).
    // A non-empty text is required by the event server, but a `turn_complete`
    // event short-circuits before any card is created, so the message is only a
    // survival placeholder, never surfaced.
    static let bodyPython =
        "import json,sys; d=json.loads(sys.argv[1]); "
        + "et={'agent-turn-complete':'turn_complete'}.get(d.get('type',''),''); "
        + "sid=(d.get('thread-id') or '').lower(); "
        + "msg=(d.get('last-assistant-message') or '')[:2000] or 'Codex finished a turn.'; "
        + "print(json.dumps({'source':'codex','event_type':et,'external_session_id':sid,"
        + "'project_path':d.get('cwd') or '','title':'Codex','text':msg,"
        + "'metadata':{'adapter':'codex-notify'}})) if (et and sid) else None"

    // Chain to the previously configured notify program (decoded from the
    // --previous-notify JSON) with the original payload appended, so existing
    // notify consumers keep working exactly as before.
    static let chainPython =
        "import json,os,sys; a=json.loads(sys.argv[1]); "
        + "a=[str(x) for x in a]+[sys.argv[2]]; os.execvp(a[0],a) if a else None"

    /// Fire-and-forget forwarder + chainer. Codex calls this as either
    /// `<script> <payload>` (no previous) or
    /// `<script> --previous-notify <json> <payload>` (chained). The payload is
    /// always the last argument. All forwarding output is suppressed so it can
    /// never alter Codex behavior, and chaining always runs when a previous
    /// notify was recorded.
    static var scriptBody: String {
        [
            "#!/bin/bash",
            "# Attaché Codex notify program (managed by Attaché; safe to delete).",
            "# Forwards the session's exact turn status to the local Attaché app, then",
            "# chains to any previously configured notify program. Silent, non-blocking.",
            "PAYLOAD=\"${@: -1}\"",
            "PREV=\"\"",
            "if [ \"$1\" = \"--previous-notify\" ]; then PREV=\"$2\"; fi",
            "{",
            "  if [ -n \"$PAYLOAD\" ]; then",
            "    BODY=\"$(/usr/bin/python3 -c \"\(bodyPython)\" \"$PAYLOAD\" 2>/dev/null)\"",
            "    if [ -n \"$BODY\" ]; then",
            "      PORT=\"${ATTACHE_EVENT_PORT:-7531}\"",
            "      TF=\"$HOME/Library/Application Support/Attache/event-token\"",
            "      if [ -f \"$TF\" ]; then",
            "        TOKEN=\"$(cat \"$TF\")\"",
            "        /usr/bin/curl -sS -m 2 -X POST \"http://127.0.0.1:$PORT/events\""
                + " -H 'Content-Type: application/json' -H \"Authorization: Bearer $TOKEN\""
                + " --data-binary \"$BODY\" >/dev/null 2>&1",
            "      fi",
            "    fi",
            "  fi",
            "} >/dev/null 2>&1",
            "if [ -n \"$PREV\" ]; then",
            "  exec /usr/bin/python3 -c \"\(chainPython)\" \"$PREV\" \"$PAYLOAD\"",
            "fi",
            "exit 0",
            ""
        ].joined(separator: "\n")
    }
}
