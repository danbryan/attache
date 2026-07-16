import AttacheCore
import Foundation

enum CLILanguageModelError: LocalizedError {
    case notInstalled(String)
    case unsafeToolIsolation(String)
    case failed(String)
    case empty
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let tool): return "\(tool) isn't installed or couldn't be found. Install it and sign in, then try again."
        case .unsafeToolIsolation(let tool):
            return "\(tool) personality inference is disabled because its CLI cannot yet guarantee that native file-reading tools are off. Choose Claude subscription, an API provider, or Ollama."
        case .failed(let detail): return detail
        case .empty: return "The model returned an empty response."
        case .timedOut(let tool): return "\(tool) did not answer within 90 seconds."
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

    func complete(messages: [AttacheChatMessage]) async throws -> String {
        try await complete(prompt: Self.renderPrompt(messages: messages))
    }

    /// Run the exact prompt bytes already measured by `ContextCompiler`.
    /// Production broker calls use this overload so transport cannot silently
    /// re-render a different request after the pre-egress budget gate.
    func complete(prompt: String) async throws -> String {
        guard Self.supportsSafeToolIsolation(tool) else {
            // This check intentionally runs before executable discovery or
            // process creation. A persisted legacy Codex personality therefore
            // fails closed without exposing any prompt bytes to a subprocess.
            throw CLILanguageModelError.unsafeToolIsolation(tool.displayName)
        }
        guard let executable = Self.locate(tool.executableName) else {
            throw CLILanguageModelError.notInstalled(tool.displayName)
        }
        switch tool {
        case .claude: return try await runClaude(executable: executable, prompt: prompt)
        case .codex:
            throw CLILanguageModelError.unsafeToolIsolation(tool.displayName)
        }
    }

    static func supportsSafeToolIsolation(_ tool: Tool) -> Bool {
        switch tool {
        case .claude: return true
        case .codex: return false
        }
    }

    // MARK: - Claude

    /// Arguments for a one-shot sandboxed `claude -p` run. The prompt carries
    /// untrusted transcript text, so the invocation must not be able to act on it:
    /// safe mode disables user/project CLAUDE.md files and every extension surface,
    /// all tools are disabled, permission prompts are auto-denied, and settings,
    /// MCP servers, slash commands, and session persistence are all off. An older
    /// CLI that lacks any of these flags exits with an unknown-option error instead
    /// of running unsandboxed, so an unsupported flag fails closed.
    static func claudeArguments(model: String, reasoningEffort: String?) -> [String] {
        var args = [
            "-p",
            "--output-format", "json",
            "--safe-mode",
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
    static func renderPrompt(messages: [AttacheChatMessage]) -> String {
        var system = ""
        var turns: [String] = []
        for message in messages {
            switch message.role {
            case "system":
                system += (system.isEmpty ? "" : "\n\n") + message.content
            case "assistant":
                if !message.content.isEmpty {
                    turns.append("Assistant: \(message.content)")
                }
                if !message.toolCalls.isEmpty {
                    turns.append("Assistant tool calls: \(canonicalToolCalls(message.toolCalls))")
                }
            case "tool":
                let callID = message.toolCallID ?? "unknown"
                turns.append("Tool result for \(callID): \(message.content)")
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

    private static func canonicalToolCalls(_ calls: [AttacheChatToolCall]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(calls) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
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

    static func run(executable: String, arguments: [String], stdin: String?, extraEnv: [String: String], workingDirectory: URL? = nil) async throws -> String {
        let cancellation = CLIProcessCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let workingDirectory {
                    process.currentDirectoryURL = workingDirectory
                }
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                process.environment = subprocessEnvironment(
                    processEnvironment: ProcessInfo.processInfo.environment,
                    home: home,
                    extraEnv: extraEnv
                )

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

                let completionGate = CLICompletionGate()
                @Sendable func finish(_ result: Result<String, Error>) {
                    guard completionGate.claim() else { return }
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(with: result)
                }

                // Register the exact Process instance before launching it. Cancellation
                // can race with Process.run(), so the controller handles all three
                // states: not launched yet, currently launching, and running.
                guard cancellation.register(process: process, handler: {
                    finish(.failure(CancellationError()))
                }) else {
                    return
                }

                let timeoutItem = DispatchWorkItem {
                    let name = URL(fileURLWithPath: executable).lastPathComponent == "claude"
                        ? "Claude Code"
                        : "Codex"
                    finish(.failure(CLILanguageModelError.timedOut(name)))
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + 90,
                    execute: timeoutItem
                )

                process.terminationHandler = { proc in
                    timeoutItem.cancel()
                    outCollector.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                    errCollector.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                    let stdout = String(decoding: outCollector.snapshot(), as: UTF8.self)
                    let stderr = String(decoding: errCollector.snapshot(), as: UTF8.self)
                    if proc.terminationStatus != 0 {
                        finish(.failure(
                            CLILanguageModelError.failed(
                                processFailureMessage(
                                    executable: executable,
                                    code: proc.terminationStatus,
                                    stdout: stdout,
                                    stderr: stderr
                                )
                            )
                        ))
                    } else {
                        finish(.success(stdout))
                    }
                    cancellation.clear(process: proc)
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
                    guard cancellation.processDidLaunch(process) else {
                        try? inputPipe?.fileHandleForWriting.close()
                        return
                    }
                    if let stdin, let inputPipe {
                        inputPipe.fileHandleForWriting.write(Data(stdin.utf8))
                        try? inputPipe.fileHandleForWriting.close()
                    }
                } catch {
                    timeoutItem.cancel()
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    if Task.isCancelled {
                        finish(.failure(CancellationError()))
                    } else {
                        finish(.failure(CLILanguageModelError.notInstalled(executable)))
                    }
                    cancellation.clear(process: process)
                    return
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Do not inherit API keys, cloud credentials, or unrelated application
    /// secrets into a subprocess that receives untrusted transcript text. The
    /// Claude subscription flow needs only its login home/config location plus
    /// ordinary locale and executable lookup state. Callers may add narrowly
    /// scoped values explicitly through `extraEnv`.
    static func subprocessEnvironment(
        processEnvironment: [String: String],
        home: String,
        extraEnv: [String: String]
    ) -> [String: String] {
        var environment: [String: String] = [
            "HOME": home,
            "PATH": mergedPATH(existing: processEnvironment["PATH"], home: home),
            "TMPDIR": processEnvironment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path
        ]
        for key in ["LANG", "LC_ALL", "LC_CTYPE", "CLAUDE_CONFIG_DIR"] {
            if let value = processEnvironment[key], !value.isEmpty {
                environment[key] = value
            }
        }
        extraEnv.forEach { environment[$0] = $1 }
        return environment
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

/// Process exit, timeout, and Swift task cancellation race on separate queues.
/// Only the winner may resume the checked continuation.
private final class CLICompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}

/// Coordinates Swift task cancellation with the one Foundation Process spawned
/// for that request. The lock closes the narrow race where cancellation arrives
/// after the launch check but before `Process.run()` has marked the process as
/// running. In that case `processDidLaunch` terminates the same instance as soon
/// as the launch completes.
private final class CLIProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationRequested = false
    private var process: Process?
    private var handler: (@Sendable () -> Void)?

    func register(process: Process, handler: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        guard !cancellationRequested else {
            lock.unlock()
            handler()
            return false
        }
        self.process = process
        self.handler = handler
        lock.unlock()
        return true
    }

    /// Returns false when cancellation won the launch race. The caller must not
    /// write stdin after that point because termination is already underway.
    func processDidLaunch(_ process: Process) -> Bool {
        lock.lock()
        let shouldTerminate = cancellationRequested && self.process === process
        lock.unlock()
        if shouldTerminate, process.isRunning {
            process.terminate()
        }
        return !shouldTerminate
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let process = process
        let handler = handler
        lock.unlock()

        // Claim the continuation as canceled before signaling the process. A
        // fast SIGTERM handler could otherwise report a successful exit first.
        handler?()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    func clear(process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
            handler = nil
        }
        lock.unlock()
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
