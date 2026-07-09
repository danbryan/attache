import AttacheCore
import Foundation

enum CLILanguageModelError: LocalizedError {
    case notInstalled(String)
    case failed(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .notInstalled(let tool): return "\(tool) isn't installed or couldn't be found. Install it and sign in, then try again."
        case .failed(let detail): return detail
        case .empty: return "The model returned an empty response."
        }
    }
}

/// Runs an already-logged-in coding CLI (Claude Code or Codex) as a one-shot
/// completion, so Attaché can use the user's subscription with no API key. This
/// mirrors the stateless HTTP path: one process per call, full prompt each time.
struct CLILanguageModel {
    enum Tool {
        case claude
        case codex
        var displayName: String { self == .claude ? "Claude Code" : "Codex" }
        var executableName: String { self == .claude ? "claude" : "codex" }
    }

    let tool: Tool
    let model: String
    var reasoningEffort: String? = nil   // Codex: model_reasoning_effort (low/medium/high/xhigh)
    var serviceTier: String? = nil       // Codex: service_tier (fast = 1.5x, flex = cheaper)

    func complete(messages: [CompanionChatMessage]) async throws -> String {
        guard let executable = Self.locate(tool.executableName) else {
            throw CLILanguageModelError.notInstalled(tool.displayName)
        }
        let prompt = Self.renderPrompt(messages: messages)
        switch tool {
        case .claude: return try await runClaude(executable: executable, prompt: prompt)
        case .codex: return try await runCodex(executable: executable, prompt: prompt)
        }
    }

    // MARK: - Claude

    /// Arguments for a one-shot sandboxed `claude -p` run. The prompt carries
    /// untrusted transcript text, so the invocation must not be able to act on it:
    /// all tools disabled, permission prompts auto-denied, and the user's setting
    /// sources, MCP servers, skills, and session persistence all off. An older CLI
    /// that lacks any of these flags exits with an unknown-option error instead of
    /// running unsandboxed, so an unsupported flag fails closed.
    static func claudeArguments(model: String, reasoningEffort: String?) -> [String] {
        var args = [
            "-p",
            "--output-format", "json",
            "--tools", "",
            "--permission-mode", "dontAsk",
            "--setting-sources", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--no-session-persistence"
        ]
        if usesExplicitModel(model) { args += ["--model", model] }
        if let effort = normalized(reasoningEffort) {
            args += ["--effort", effort]   // low/medium/high/xhigh/max
        }
        return args
    }

    private func runClaude(executable: String, prompt: String) async throws -> String {
        let args = Self.claudeArguments(model: model, reasoningEffort: reasoningEffort)
        // Fresh empty working directory so the run can't see the app's cwd,
        // mirroring the Codex throwaway-dir approach.
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let output = try await Self.run(executable: executable, arguments: args, stdin: prompt, extraEnv: [:], workingDirectory: scratch)
        // claude --output-format json prints a single result object.
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Fall back to raw text if the JSON envelope is missing.
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw CLILanguageModelError.empty }
            return trimmed
        }
        if let isError = object["is_error"] as? Bool, isError {
            throw CLILanguageModelError.failed((object["result"] as? String) ?? "Claude returned an error.")
        }
        guard let result = (object["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else {
            throw CLILanguageModelError.empty
        }
        return result
    }

    // MARK: - Codex

    private func runCodex(executable: String, prompt: String) async throws -> String {
        // Read-only sandbox in a throwaway dir so a stray "do this" prompt can't touch
        // the user's files; we only want the model's text back.
        let scratch = FileManager.default.temporaryDirectory.path
        var args = [
            "exec",
            "--json",
            "--ephemeral",
            "--ignore-rules",
            "--ignore-user-config",
            "--sandbox", "read-only",
            "--skip-git-repo-check",
            "-C", scratch
        ]
        if Self.usesExplicitModel(model) { args += ["--model", model] }
        if let effort = Self.normalized(reasoningEffort) {
            args += ["-c", "model_reasoning_effort=\(effort)"]
        }
        if let tier = Self.normalized(serviceTier) {
            args += ["-c", "service_tier=\(tier)"]   // fast = 1.5x priority, flex = cheaper
        }
        args.append("-")
        let output = try await Self.run(executable: executable, arguments: args, stdin: prompt, extraEnv: [:])
        if let text = Self.lastCodexMessage(in: output) { return text }
        // Fall back to the last non-empty stdout line.
        let line = output.split(whereSeparator: \.isNewline).map(String.init).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        guard let line, !line.isEmpty else { throw CLILanguageModelError.empty }
        return line
    }

    /// Codex `exec --json` emits one JSON event per line; the assistant's reply is the
    /// last event carrying agent-message text.
    static func lastCodexMessage(in output: String) -> String? {
        var last: String?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let candidates: [Any?] = [
                object["text"],
                (object["item"] as? [String: Any])?["text"],
                (object["msg"] as? [String: Any])?["message"],
                (object["message"] as? [String: Any])?["content"]
            ]
            for case let text as String in candidates.compactMap({ $0 }) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { last = trimmed }
            }
        }
        return last
    }

    static func usesExplicitModel(_ model: String) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !trimmed.isEmpty && trimmed != "default"
    }

    /// A fresh empty directory for a subprocess to run in, so it can't inherit
    /// whatever directory the app happens to be running from.
    static func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A setting worth passing to the CLI, or nil to leave the tool's own config in
    /// place ("default"/"standard"/"none" all mean "don't override").
    static func normalized(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["", "default", "none", "standard"].contains(trimmed) ? nil : trimmed
    }

    // MARK: - Prompt rendering

    /// Flatten the chat messages into one prompt the CLI can take, since it has no
    /// separate system/role channels for a one-shot run.
    static func renderPrompt(messages: [CompanionChatMessage]) -> String {
        var system = ""
        var turns: [String] = []
        for message in messages {
            switch message.role {
            case "system":
                system += (system.isEmpty ? "" : "\n\n") + message.content
            case "assistant":
                turns.append("Assistant: \(message.content)")
            default:
                turns.append("User: \(message.content)")
            }
        }
        var prompt = system
        if !turns.isEmpty {
            if !prompt.isEmpty { prompt += "\n\n" }
            prompt += turns.joined(separator: "\n\n")
            prompt += "\n\nRespond as the assistant with your reply only."
        }
        return prompt
    }

    // MARK: - Process

    /// Cheap check of the common install locations (no subprocess), used to show a
    /// tool as "connected" without paying a login-shell lookup on every render.
    static func candidatePath(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.claude/local/\(name)",
            "/usr/bin/\(name)"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func isLikelyInstalled(_ tool: Tool) -> Bool {
        candidatePath(tool.executableName) != nil
    }

    /// A packaged GUI app doesn't inherit the shell PATH, so look in the common
    /// install locations and, as a last resort, ask a login shell.
    static func locate(_ name: String) -> String? {
        if let path = candidatePath(name) { return path }
        // Login-shell fallback (resolves nvm/asdf/custom PATHs).
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        try? shell.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        let resolved = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (!resolved.isEmpty && FileManager.default.isExecutableFile(atPath: resolved)) ? resolved : nil
    }

    private static func run(executable: String, arguments: [String], stdin: String?, extraEnv: [String: String], workingDirectory: URL? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let workingDirectory {
                process.currentDirectoryURL = workingDirectory
            }
            var env = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            env["HOME"] = home
            env["PATH"] = mergedPATH(existing: env["PATH"], home: home)
            extraEnv.forEach { env[$0] = $1 }
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let outCollector = OutputCollector()
            let errCollector = OutputCollector()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                outCollector.append(chunk)
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                errCollector.append(chunk)
            }

            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                outCollector.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                errCollector.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                let stdout = String(decoding: outCollector.snapshot(), as: UTF8.self)
                let stderr = String(decoding: errCollector.snapshot(), as: UTF8.self)
                if proc.terminationStatus != 0 {
                    continuation.resume(
                        throwing: CLILanguageModelError.failed(
                            processFailureMessage(
                                executable: executable,
                                code: proc.terminationStatus,
                                stdout: stdout,
                                stderr: stderr
                            )
                        )
                    )
                } else {
                    continuation.resume(returning: stdout)
                }
            }

            do {
                let inputPipe: Pipe?
                if stdin != nil {
                    let pipe = Pipe()
                    process.standardInput = pipe
                    inputPipe = pipe
                } else {
                    process.standardInput = FileHandle.nullDevice
                    inputPipe = nil
                }
                try process.run()
                if let stdin, let inputPipe {
                    inputPipe.fileHandleForWriting.write(Data(stdin.utf8))
                    try? inputPipe.fileHandleForWriting.close()
                }
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: CLILanguageModelError.notInstalled(executable))
                return
            }
        }
    }

    static func processFailureMessage(executable: String, code: Int32, stdout: String, stderr: String) -> String {
        let executableName = URL(fileURLWithPath: executable).lastPathComponent
        let structuredError = executableName == "codex" ? codexErrorMessage(in: stdout) : nil
        // Codex writes plugin and skill-loader warnings to stderr even when the
        // useful structured failure is on stdout. Prefer the real JSON error so
        // the HUD does not blame an unrelated warning.
        let candidates = executableName == "codex"
            ? [structuredError ?? "", stdout, stderr]
            : [stderr, stdout]
        let detail = candidates
            .map { trimmedProcessOutput($0) }
            .first(where: { !$0.isEmpty })
        if let detail {
            return "\(executableName) exited with code \(code): \(detail)"
        }
        return "\(executableName) exited with code \(code)."
    }

    private static func codexErrorMessage(in output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let type = (object["type"] as? String)?.lowercased() ?? ""
            guard type.contains("error") || object["error"] != nil else { continue }
            if let message = humanReadableError(from: object) { return message }
        }
        return nil
    }

    /// Codex sometimes wraps an API error object as JSON text inside the event's
    /// `message` field. Unwrap those layers so the HUD shows the actionable API
    /// message instead of escaped braces and transport metadata.
    private static func humanReadableError(from value: Any, depth: Int = 0) -> String? {
        guard depth < 6 else { return nil }

        if let object = value as? [String: Any] {
            if let error = object["error"],
               let message = humanReadableError(from: error, depth: depth + 1) {
                return message
            }
            if let message = object["message"],
               let readable = humanReadableError(from: message, depth: depth + 1) {
                return readable
            }
            if let item = object["item"],
               let message = humanReadableError(from: item, depth: depth + 1) {
                return message
            }
            return nil
        }

        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let nested = try? JSONSerialization.jsonObject(with: data),
           let message = humanReadableError(from: nested, depth: depth + 1) {
            return message
        }
        return trimmed
    }

    private static func trimmedProcessOutput(_ text: String) -> String {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(8)
        let joined = lines.joined(separator: " ")
        guard joined.count > 700 else { return joined }
        let index = joined.index(joined.startIndex, offsetBy: 700)
        return String(joined[..<index]) + "..."
    }

    static func mergedPATH(existing: String?, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        let defaults = [
            "\(home)/.local/bin",
            "\(home)/.claude/local",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        var seen = Set<String>()
        var parts: [String] = []
        for path in defaults + (existing ?? "").split(separator: ":").map(String.init) {
            guard !path.isEmpty, !seen.contains(path) else { continue }
            seen.insert(path)
            parts.append(path)
        }
        return parts.joined(separator: ":")
    }
}

/// Thread-safe accumulator for subprocess stdout read across the pipe's readability
/// and termination handlers.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); data.append(chunk); lock.unlock()
    }
    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}
