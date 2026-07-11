import Foundation
import AttacheCore

/// Delivers a confirmed instruction into a Claude Code or Codex session by the
/// vendor's own headless resume, per docs/two-way.md. One adapter per vendor
/// (CLI and Desktop share session storage), with queue-until-idle enforced by the
/// engine's idle gate.
///
/// IMPORTANT: unlike the summarizer in `CLILanguageModel` (INF-144), this
/// invocation is deliberately NOT sandboxed. It is meant to ACT: it inherits the
/// user's own agent permissions exactly as if the user had typed the instruction.
/// The two paths must stay clearly separated; never add the summarizer's
/// tool-denial flags here, and never route untrusted transcript text through here.

/// Outcome of a spawned resume subprocess: bounded stdout/stderr captures (the
/// caller enforces the ~1MB cap) plus whether the hard timeout fired.
struct ProcessRunResult: Equatable, Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
}

struct AgentResumeDeliveryAdapter: InstructionDeliveryAdapter {
    enum Vendor {
        case claude
        case codex

        var sourceKind: String { self == .claude ? SourceKind.claudeCode.rawValue : SourceKind.codex.rawValue }
        var executableName: String { self == .claude ? "claude" : "codex" }
        var displayName: String { self == .claude ? "Claude Code" : "Codex" }
    }

    /// Hard ceiling on a resume subprocess (INF-238). A resume that never exits
    /// (a hung CLI, a wedged desktop lock) must not wait forever; it is treated
    /// as a failed delivery so the instruction can be reviewed and resent.
    static let defaultProcessTimeout: TimeInterval = 5 * 60
    /// Cap on captured stdout/stderr so a runaway or looping process can't grow
    /// memory unbounded. Real resume output (a single JSON object for Claude, a
    /// handful of JSONL events for Codex) is far smaller than this.
    static let maxCapturedBytes = 1 * 1024 * 1024
    /// When a nonzero exit or missing evidence produces a failure message, trim
    /// the captured stderr to this many trailing bytes so the audit log and UI
    /// show the relevant tail rather than a wall of text.
    private static let errorMessageTailBytes = 4000

    let vendor: Vendor
    /// Resolves the session transcript so the readiness gate can inspect stable
    /// file state and completed turns. Injected for testability.
    let locateSessionFile: @Sendable (String) -> URL?
    /// Locates the vendor CLI (defaults to the shared `CLILanguageModel.locate`).
    let locateExecutable: @Sendable (String) -> String?
    /// Hard timeout for the resume subprocess. Overridable for tests.
    let processTimeout: TimeInterval
    /// Spawns the resume and returns its captured output. Injected so tests
    /// don't shell out. `workingDirectory`, when non-nil, is set as the
    /// subprocess's cwd (INF-260): `claude -p --resume` only finds a session
    /// from the same cwd it was created in, unlike Codex's
    /// `--skip-git-repo-check`, which is cwd-independent.
    let spawn: @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval, _ workingDirectory: String?) async -> ProcessRunResult

    var sourceKind: String { vendor.sourceKind }

    init(
        vendor: Vendor,
        locateSessionFile: @escaping @Sendable (String) -> URL?,
        locateExecutable: @escaping @Sendable (String) -> String? = { CLILanguageModel.locate($0) },
        processTimeout: TimeInterval = AgentResumeDeliveryAdapter.defaultProcessTimeout,
        spawn: (@Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval, _ workingDirectory: String?) async -> ProcessRunResult)? = nil
    ) {
        self.vendor = vendor
        self.locateSessionFile = locateSessionFile
        self.locateExecutable = locateExecutable
        self.processTimeout = processTimeout
        self.spawn = spawn ?? { await AgentResumeDeliveryAdapter.defaultSpawn($0, $1, timeout: $2, workingDirectory: $3) }
    }

    func capability(forSessionID sessionID: String) -> DeliveryCapability {
        guard locateExecutable(vendor.executableName) != nil else {
            return .unavailable("Two-way unavailable: the \(vendor.executableName) CLI was not found on PATH.")
        }
        guard locateSessionFile(sessionID) != nil else {
            return .unavailable("Two-way unavailable: no \(vendor.displayName) session file for this session yet.")
        }
        // Headless resume is a second writer; it must wait for the session to be quiet.
        return DeliveryCapability(canDeliver: true, requiresIdle: true)
    }

    func deliver(_ instruction: Instruction) async -> Result<DeliveryReceipt, InstructionDeliveryError> {
        guard let executable = locateExecutable(vendor.executableName) else {
            return .failure(.notDeliverable("\(vendor.executableName) CLI not found."))
        }
        guard let sessionFile = locateSessionFile(instruction.sessionID) else {
            return .failure(.sessionGone)
        }
        let checkpoint = Self.fileSize(sessionFile)
        let arguments = Self.resumeArguments(vendor: vendor, sessionID: instruction.sessionID, instruction: instruction.text)
        // Only Claude needs the session's original working directory set
        // (INF-260); Codex's --skip-git-repo-check is already cwd-independent
        // by design, so its spawn behavior is unchanged.
        let workingDirectory = vendor == .claude ? instruction.workingDirectory : nil
        let result = await spawn(executable, arguments, processTimeout, workingDirectory)

        if result.timedOut {
            return .failure(.deliveryFailed("\(vendor.displayName) did not respond within \(Int(processTimeout))s; delivery timed out."))
        }
        guard result.exitCode == 0 else {
            return .failure(.deliveryFailed(Self.failureMessage(exitCode: result.exitCode, stderr: result.stderr)))
        }
        guard let evidence = Self.evidence(forVendor: vendor, stdout: result.stdout) else {
            // Exit 0 alone is not proof of an accepted turn (a stale/wrong session
            // id or a rejected turn can no-op silently); require parsed evidence.
            return .failure(.deliveryFailed("exited 0 but no assistant turn in output"))
        }
        return .success(DeliveryReceipt(
            mechanism: "headless-resume",
            transcriptCheckpoint: checkpoint,
            replyText: evidence.replyText,
            replyTurnID: evidence.turnID
        ))
    }

    /// Argument vector for the (unsandboxed) resume. Pure and testable.
    static func resumeArguments(vendor: Vendor, sessionID: String, instruction: String) -> [String] {
        switch vendor {
        case .claude:
            // `claude -p --resume <id> --output-format json "<instruction>"`: print
            // mode (non-interactive), acting with the user's own Claude Code
            // permissions. `--output-format json` prints a single JSON result
            // object on success, which is the only reliable evidence that the
            // turn actually ran (INF-238); a silent no-op exits 0 with empty stdout.
            return ["-p", "--resume", sessionID, "--output-format", "json", instruction]
        case .codex:
            // `codex exec resume --skip-git-repo-check --json <id> "<instruction>"`:
            // non-interactive resume using the user's own Codex config/sandbox
            // settings. A session may have started in a non-Git directory, and
            // Finder gives the helper no useful working directory, so allow
            // resume-by-id in that case. `--json` prints JSONL thread events;
            // an `item.completed` agent_message is the evidence a turn completed.
            return ["exec", "resume", "--skip-git-repo-check", "--json", sessionID, instruction]
        }
    }

    /// Parsed evidence of a completed assistant turn, plus a turn/session
    /// identifier when the output carries one. `nil` means the output did not
    /// prove a turn completed, regardless of exit code.
    static func evidence(forVendor vendor: Vendor, stdout: String) -> (replyText: String, turnID: String?)? {
        switch vendor {
        case .claude: return claudeEvidence(fromStdout: stdout)
        case .codex: return codexEvidence(fromStdout: stdout)
        }
    }

    /// Claude contract (verified against `claude -p --resume <id> --output-format
    /// json "<text>"` on this machine): success is a single JSON object with
    /// `type == "result"`, `subtype == "success"`, `is_error == false`, and a
    /// non-empty `result` string. Anything else, including a well-formed JSON
    /// object missing one of those markers, is not evidence of a completed turn.
    private static func claudeEvidence(fromStdout stdout: String) -> (replyText: String, turnID: String?)? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard object["type"] as? String == "result",
              object["subtype"] as? String == "success",
              object["is_error"] as? Bool == false,
              let result = object["result"] as? String else { return nil }
        let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (text, object["session_id"] as? String)
    }

    /// Codex contract (verified against `codex exec resume --skip-git-repo-check
    /// --json <id> "<text>"` on this machine): `--json` prints JSONL thread
    /// events, e.g. `{"type":"thread.started","thread_id":"..."}` and
    /// `{"type":"item.completed","item":{"type":"agent_message","text":"..."}}`.
    /// The last completed `agent_message` item is the evidence of a finished
    /// turn; `thread_id` (when present) is the turn identifier.
    private static func codexEvidence(fromStdout stdout: String) -> (replyText: String, turnID: String?)? {
        var turnID: String?
        var replyText: String?
        for line in stdout.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            switch type {
            case "thread.started":
                if let id = object["thread_id"] as? String { turnID = id }
            case "item.completed":
                guard let item = object["item"] as? [String: Any],
                      item["type"] as? String == "agent_message",
                      let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                replyText = text
            default:
                break
            }
        }
        guard let text = replyText else { return nil }
        return (text, turnID)
    }

    private static func failureMessage(exitCode: Int32, stderr: String) -> String {
        let tail = tailBytes(stderr, max: errorMessageTailBytes).trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? "exit \(exitCode)" : tail
    }

    private static func tailBytes(_ text: String, max: Int) -> String {
        guard text.utf8.count > max else { return text }
        let tailData = Data(text.utf8).suffix(max)
        return String(decoding: tailData, as: UTF8.self)
    }

    /// Internal (not private) so tests can exercise the real subprocess timeout
    /// path directly, without routing test-only executables through
    /// `resumeArguments`. `workingDirectory`, when non-nil, becomes the
    /// subprocess's cwd (INF-260); a nonexistent or invalid path is skipped
    /// rather than failing the whole delivery, since Attaché's own process
    /// cwd (Process's default) is still a reasonable fallback.
    static func defaultSpawn(_ executable: String, _ arguments: [String], timeout: TimeInterval, workingDirectory: String? = nil) async -> ProcessRunResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let workingDirectory, FileManager.default.fileExists(atPath: workingDirectory) {
                process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            }
            var env = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            env["HOME"] = home
            env["PATH"] = CLILanguageModel.mergedPATH(existing: env["PATH"], home: home)
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let outBuffer = BoundedOutputBuffer(capacity: maxCapturedBytes)
            let errBuffer = BoundedOutputBuffer(capacity: maxCapturedBytes)
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                outBuffer.append(data)
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                errBuffer.append(data)
            }

            // Whether the hard timeout fired is tracked separately from "who won
            // the race to call finish()": terminate() causes the OS to invoke
            // `terminationHandler` on its own queue, which can run concurrently
            // with the rest of the timeout closure, so timedOut must be read from
            // this shared flag (set before terminate() is ever called) rather
            // than inferred from which closure happened to call finish first.
            let finishLock = NSLock()
            var finished = false
            var timedOutFlag = false
            func finish(exitCode: Int32) {
                finishLock.lock()
                defer { finishLock.unlock() }
                guard !finished else { return }
                finished = true
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: ProcessRunResult(
                    exitCode: exitCode,
                    stdout: outBuffer.string(),
                    stderr: errBuffer.string(),
                    timedOut: timedOutFlag
                ))
            }

            let timeoutItem = DispatchWorkItem {
                finishLock.lock()
                timedOutFlag = true
                finishLock.unlock()
                // Never read terminationStatus here: terminate() only sends
                // SIGTERM and returns immediately, and Foundation throws an
                // (uncatchable-from-Swift) NSException if terminationStatus is
                // read while the process is still running. That exact race
                // crashed the app when a long resume turn hit the timeout
                // (2026-07-11 crash report). Report a synthetic exit code;
                // deliver() only looks at timedOut for this branch, and the
                // terminationHandler that fires after the kill completes is a
                // no-op because finish() already ran.
                if process.isRunning { process.terminate() }
                finish(exitCode: -1)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            process.terminationHandler = { proc in
                timeoutItem.cancel()
                finish(exitCode: proc.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                timeoutItem.cancel()
                errBuffer.append(Data(error.localizedDescription.utf8))
                finish(exitCode: -1)
            }
        }
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }
}

/// Thread-safe tail buffer: keeps only the most recent `capacity` bytes so a
/// runaway or looping resume process can't grow captured output unbounded.
private final class BoundedOutputBuffer: @unchecked Sendable {
    private let capacity: Int
    private var data = Data()
    private let lock = NSLock()

    init(capacity: Int) { self.capacity = capacity }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > capacity {
            data.removeFirst(data.count - capacity)
        }
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

struct SessionFileObservation: Equatable {
    var size: Int64
    var modifiedAt: Date
    var observedAt: Date
    var tailLines: [String]

    func hasSameFileState(as other: SessionFileObservation) -> Bool {
        size == other.size && modifiedAt == other.modifiedAt
    }
}

/// A delivery-specific readiness check. Modification time alone is insufficient:
/// an agent can pause during a tool call without writing to its transcript.
enum SessionDeliveryReadinessClassifier {
    static func isReady(
        previous: SessionFileObservation?,
        current: SessionFileObservation,
        format: TranscriptFormat,
        now: Date,
        quietWindow: TimeInterval
    ) -> Bool {
        guard let previous, previous.hasSameFileState(as: current) else { return false }
        guard now.timeIntervalSince(previous.observedAt) >= quietWindow,
              now.timeIntervalSince(current.modifiedAt) >= quietWindow else { return false }
        return turnIsComplete(tailLines: current.tailLines, format: format)
    }

    static func turnIsComplete(tailLines: [String], format: TranscriptFormat) -> Bool {
        var pendingTools: Set<String> = []
        var lastRealUser: Int?
        var lastCompletedAssistant: Int?
        var lastTurnActivity: Int?

        for (index, line) in tailLines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            switch format {
            case .codex:
                scanCodex(
                    object,
                    index: index,
                    pendingTools: &pendingTools,
                    lastRealUser: &lastRealUser,
                    lastCompletedAssistant: &lastCompletedAssistant,
                    lastTurnActivity: &lastTurnActivity
                )
            case .claude:
                scanClaude(
                    object,
                    index: index,
                    pendingTools: &pendingTools,
                    lastRealUser: &lastRealUser,
                    lastCompletedAssistant: &lastCompletedAssistant,
                    lastTurnActivity: &lastTurnActivity
                )
            }
        }

        guard pendingTools.isEmpty,
              let assistant = lastCompletedAssistant,
              assistant == lastTurnActivity else { return false }
        return assistant > (lastRealUser ?? -1)
    }

    private static func scanCodex(
        _ object: [String: Any],
        index: Int,
        pendingTools: inout Set<String>,
        lastRealUser: inout Int?,
        lastCompletedAssistant: inout Int?,
        lastTurnActivity: inout Int?
    ) {
        guard let payload = object["payload"] as? [String: Any],
              let type = payload["type"] as? String else { return }
        switch type {
        case "function_call", "custom_tool_call", "local_shell_call":
            if let id = (payload["call_id"] as? String) ?? (payload["id"] as? String) {
                pendingTools.insert(id)
            }
            lastTurnActivity = index
        case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
            if let id = (payload["call_id"] as? String) ?? (payload["id"] as? String) {
                pendingTools.remove(id)
            }
            lastTurnActivity = index
        case "message":
            switch payload["role"] as? String {
            case "user":
                lastRealUser = index
                lastTurnActivity = index
            case "assistant":
                lastTurnActivity = index
                if payload["phase"] as? String == "final_answer",
                   assistantText(fromCodexPayload: payload) != nil {
                    lastCompletedAssistant = index
                }
            default:
                break
            }
        default:
            break
        }
    }

    private static func scanClaude(
        _ object: [String: Any],
        index: Int,
        pendingTools: inout Set<String>,
        lastRealUser: inout Int?,
        lastCompletedAssistant: inout Int?,
        lastTurnActivity: inout Int?
    ) {
        guard object["isSidechain"] as? Bool != true else { return }
        switch object["type"] as? String {
        case "assistant":
            guard let message = object["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { return }
            var hasText = false
            for block in blocks {
                if block["type"] as? String == "tool_use", let id = block["id"] as? String {
                    pendingTools.insert(id)
                } else if block["type"] as? String == "text",
                          let text = block["text"] as? String,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hasText = true
                }
            }
            lastTurnActivity = index
            if hasText, pendingTools.isEmpty { lastCompletedAssistant = index }
        case "user":
            guard let message = object["message"] as? [String: Any] else { return }
            if let blocks = message["content"] as? [[String: Any]] {
                let results = blocks.filter { $0["type"] as? String == "tool_result" }
                if !results.isEmpty {
                    for result in results {
                        if let id = result["tool_use_id"] as? String { pendingTools.remove(id) }
                    }
                    lastTurnActivity = index
                } else {
                    lastRealUser = index
                    lastTurnActivity = index
                }
            } else if message["content"] is String {
                lastRealUser = index
                lastTurnActivity = index
            }
        case "system":
            if object["subtype"] as? String == "api_error" { lastTurnActivity = index }
        default:
            break
        }
    }
}

/// Correlates a delivered instruction's reply positionally (INF-245/B2): the
/// first completed assistant turn appearing after the instruction's delivery
/// checkpoint belongs to that instruction. The engine's single-flight FIFO
/// delivery (docs/two-way.md) guarantees the bytes between one instruction's
/// checkpoint and the next belong to it, so position alone is sufficient.
/// Exact text equality against the narrated (and possibly presentation-
/// paraphrased) card text is checked only as a secondary confidence signal and
/// must never gate the link - that requirement is what let any personality
/// paraphrase silently break correlation before this change.
enum SessionReplyCorrelation {
    /// Scans a transcript slice - already bounded to start immediately after a
    /// delivery checkpoint - for the first completed assistant turn, regardless
    /// of its text. Returns the raw reply text, or nil if the slice doesn't yet
    /// contain one (the transcript watcher may simply be lagging the delivery).
    static func firstCompletedAssistantTurn(transcriptText: String, format: TranscriptFormat) -> String? {
        var pendingTools: Set<String> = []
        for line in transcriptText.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let completed: String?
            switch format {
            case .codex:
                completed = codexCompletedAssistantText(object, pendingTools: &pendingTools)
            case .claude:
                completed = claudeCompletedAssistantText(object, pendingTools: &pendingTools)
            }
            if let completed { return completed }
        }
        return nil
    }

    /// Secondary confidence only: when the narrated card text also matches the
    /// raw reply verbatim, that's extra confidence, but a mismatch (e.g. a
    /// personality paraphrase) must never block a positional match already
    /// found by `firstCompletedAssistantTurn`.
    static func textConfirms(eventText: String, replyText: String) -> Bool {
        normalized(eventText) == normalized(replyText)
    }

    private static func codexCompletedAssistantText(
        _ object: [String: Any],
        pendingTools: inout Set<String>
    ) -> String? {
        guard let payload = object["payload"] as? [String: Any],
              let type = payload["type"] as? String else { return nil }
        switch type {
        case "function_call", "custom_tool_call", "local_shell_call":
            if let id = (payload["call_id"] as? String) ?? (payload["id"] as? String) { pendingTools.insert(id) }
        case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
            if let id = (payload["call_id"] as? String) ?? (payload["id"] as? String) { pendingTools.remove(id) }
        case "message":
            guard payload["role"] as? String == "assistant",
                  payload["phase"] as? String == "final_answer",
                  pendingTools.isEmpty else { return nil }
            return assistantText(fromCodexPayload: payload)
        default:
            break
        }
        return nil
    }

    private static func claudeCompletedAssistantText(
        _ object: [String: Any],
        pendingTools: inout Set<String>
    ) -> String? {
        guard object["isSidechain"] as? Bool != true else { return nil }
        switch object["type"] as? String {
        case "assistant":
            guard let message = object["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { return nil }
            var hasToolUse = false
            for block in blocks where block["type"] as? String == "tool_use" {
                hasToolUse = true
                if let id = block["id"] as? String { pendingTools.insert(id) }
            }
            guard !hasToolUse, pendingTools.isEmpty else { return nil }
            return claudeMessageText(message)
        case "user":
            guard let message = object["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { return nil }
            for block in blocks where block["type"] as? String == "tool_result" {
                if let id = block["tool_use_id"] as? String { pendingTools.remove(id) }
            }
        default:
            break
        }
        return nil
    }
}

private func assistantText(fromCodexPayload payload: [String: Any]) -> String? {
    guard let content = payload["content"] as? [[String: Any]] else { return nil }
    let parts = content.compactMap { ($0["text"] as? String) ?? ($0["output_text"] as? String) }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
}

private func claudeMessageText(_ message: [String: Any]) -> String? {
    if let text = message["content"] as? String { return text }
    guard let blocks = message["content"] as? [[String: Any]] else { return nil }
    let parts = blocks.compactMap { block -> String? in
        guard block["type"] as? String == "text" else { return nil }
        return block["text"] as? String
    }
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
}

private func normalized(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}
