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
        case grok

        var sourceKind: String {
            switch self {
            case .claude: return SourceKind.claudeCode.rawValue
            case .codex: return SourceKind.codex.rawValue
            case .grok: return SourceKind.grokBuild.rawValue
            }
        }
        var executableName: String {
            switch self {
            case .claude: return "claude"
            case .codex: return "codex"
            case .grok: return "grok"
            }
        }
        var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .grok: return "Grok Build"
            }
        }
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
        // Claude and Grok Build both resolve a resumed session relative to the
        // cwd it was created in (INF-260/INF-394): Claude by print-mode design,
        // Grok because its on-disk session path is keyed by the percent-encoded
        // project cwd. Codex's --skip-git-repo-check is already cwd-independent,
        // so only it spawns without a working directory.
        let workingDirectory = vendor == .codex ? nil : instruction.workingDirectory
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
        case .grok:
            // `grok --resume <id> --output-format json -p "<instruction>"`
            // (verified against grok 0.1.219 on this Mac, INF-394): `--resume`,
            // `-p/--single`, and `--output-format` are TOP-LEVEL grok flags, not
            // `grok agent` subflags (`grok agent --resume` is rejected as an
            // unexpected argument). Single-turn print mode acts with the user's
            // own Grok Build permissions; `--output-format json` prints a
            // headless result object, the only reliable evidence the turn ran
            // (a silent no-op or a stale/wrong id exits without one).
            return ["--resume", sessionID, "--output-format", "json", "-p", instruction]
        }
    }

    /// Parsed evidence of a completed assistant turn, plus a turn/session
    /// identifier when the output carries one. `nil` means the output did not
    /// prove a turn completed, regardless of exit code.
    static func evidence(forVendor vendor: Vendor, stdout: String) -> (replyText: String, turnID: String?)? {
        switch vendor {
        case .claude: return claudeEvidence(fromStdout: stdout)
        case .codex: return codexEvidence(fromStdout: stdout)
        case .grok: return grokEvidence(fromStdout: stdout)
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

    /// Grok Build contract (INF-394). Grok's `--output-format json` mirrors
    /// Claude Code's headless result object (the grok CLI's own help
    /// cross-references Claude Code flags throughout): the primary shape is a
    /// single JSON object carrying a non-empty `result` string, with
    /// `is_error` absent or false. A streaming/JSONL emission is tolerated as a
    /// fallback (the last non-empty assistant line, or a trailing result
    /// object), so a completed turn is still recognized. As with the other
    /// vendors, exit 0 alone is not evidence: only real assistant text is.
    private static func grokEvidence(fromStdout stdout: String) -> (replyText: String, turnID: String?)? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Primary: the whole output is one JSON result object.
        if let single = grokEvidence(fromObjectText: trimmed) { return single }

        // Fallback: streaming-json / JSONL. Take the last line that carries a
        // result object or a non-empty assistant message.
        var turnID: String?
        var replyText: String?
        for line in trimmed.split(whereSeparator: \.isNewline) {
            let lineText = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lineText.isEmpty,
                  let data = lineText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let id = (object["session_id"] as? String) ?? (object["id"] as? String) { turnID = id }
            if let found = grokAssistantText(fromObject: object) { replyText = found }
        }
        guard let text = replyText else { return nil }
        return (text, turnID)
    }

    /// Interpret one decoded Grok JSON object as a completed turn's text, or nil.
    private static func grokEvidence(fromObjectText text: String) -> (replyText: String, turnID: String?)? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["is_error"] as? Bool != true,
              let reply = grokAssistantText(fromObject: object) else { return nil }
        let turnID = (object["requestId"] as? String)
            ?? (object["sessionId"] as? String)
            ?? (object["session_id"] as? String)
            ?? (object["id"] as? String)
        return (reply, turnID)
    }

    /// Non-empty assistant text from a Grok result object. The REAL contract
    /// (verified live against grok 0.1.219 on this machine, INF-394 gate): a
    /// single pretty-printed object with a `text` string, `stopReason` (e.g.
    /// "EndTurn"), `sessionId`, and `requestId`. The Claude-style `result`
    /// field and assistant `content` shapes are kept as defensive fallbacks.
    private static func grokAssistantText(fromObject object: [String: Any]) -> String? {
        if let text = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        if let result = (object["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
            return result
        }
        if object["type"] as? String == "assistant",
           let content = (object["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
            return content
        }
        return nil
    }

    /// Not `private`: `OpencodeResumeDeliveryAdapter` reuses the same
    /// exit-code / stderr-tail failure formatting so the two-way audit log
    /// reads identically across every vendor.
    static func failureMessage(exitCode: Int32, stderr: String) -> String {
        let tail = tailBytes(stderr, max: errorMessageTailBytes).trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? "exit \(exitCode)" : tail
    }

    static func tailBytes(_ text: String, max: Int) -> String {
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
            // Null stdin explicitly: an inherited never-EOF descriptor makes
            // `opencode run` block reading it until the delivery watchdog fires
            // (proven empirically, INF-395: open stdin hangs, /dev/null returns
            // in seconds). Every adapter passes the instruction via argv, so no
            // vendor reads stdin on purpose.
            process.standardInput = FileHandle.nullDevice

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

/// A started `opencode run` subprocess whose completion the adapter watches.
/// opencode's event loop LINGERS after it has finished the turn and written the
/// reply to the database (sampled parked in `kevent64` with the turn already
/// logged "exiting loop", INF-395), so process exit is NOT the completion
/// signal. The adapter drives completion off the DB instead and terminates this
/// handle once the reply lands. Injected so tests substitute a fake that never
/// exits on its own.
protocol OpencodeRunningProcess: Sendable {
    /// Resolves when the process exits on its own (or is terminated). For a
    /// lingering `opencode run` this only returns after `terminate()`.
    func waitForExit() async -> ProcessRunResult
    /// SIGTERM the child, escalating to SIGKILL after a grace period.
    func terminate()
}

/// Delivers a confirmed instruction into an opencode session (INF-395). Unlike
/// Codex/Claude Code/Grok Build, opencode has no per-session JSONL transcript
/// file: every session is rows in one shared SQLite database. So this is a
/// sibling to `AgentResumeDeliveryAdapter` rather than another `Vendor` case -
/// the resume shape genuinely differs (a DB-backed session lookup, a
/// message-time delivery checkpoint instead of a file byte offset, cwd from the
/// session row), AND its completion semantics differ: `opencode run` finishes
/// the turn, writes the reply to the database, then LINGERS instead of exiting.
/// So delivery does NOT wait for process exit; it polls the database for the
/// first completed assistant turn after the pre-delivery checkpoint and, once
/// that reply lands, terminates the lingering child and returns success with
/// the DB turn as authoritative evidence (stdout evidence is best-effort, used
/// only if the process happens to exit on its own first). Like the file
/// adapter, this is NOT sandboxed: it inherits the user's own opencode
/// permissions.
///
/// Command: `opencode run --session <id> --format json "<instruction>"`
/// (verified flags, opencode 1.17.15). CRITICAL: never pass `-m/--model` (nor
/// opencode's `-p`, which is `--password`, not print mode); the session/config
/// decides the model.
struct OpencodeResumeDeliveryAdapter: InstructionDeliveryAdapter {
    static let executableName = "opencode"
    static let displayName = "opencode"

    /// Loads the session's DB snapshot (directory + ordered messages), or nil
    /// if the session row does not exist. Injected so tests supply fixtures.
    /// Also the completion source: polled after spawn for the reply turn.
    let loadSnapshot: @Sendable (String) -> OpencodeSessionSnapshot?
    let locateExecutable: @Sendable (String) -> String?
    /// Ceiling on the whole delivery: if neither the DB reply nor a process
    /// exit appears within this window, delivery fails as timed out.
    let processTimeout: TimeInterval
    /// How often the database is polled for the completed reply turn.
    let replyPollInterval: TimeInterval
    /// Starts (does not await) the `opencode run` subprocess and returns a
    /// terminable handle. Injected so tests supply a fake that never exits.
    let startProcess: @Sendable (_ executable: String, _ arguments: [String], _ workingDirectory: String?) -> OpencodeRunningProcess

    var sourceKind: String { SourceKind.opencode.rawValue }

    init(
        loadSnapshot: @escaping @Sendable (String) -> OpencodeSessionSnapshot?,
        locateExecutable: @escaping @Sendable (String) -> String? = { CLILanguageModel.locate($0) },
        processTimeout: TimeInterval = AgentResumeDeliveryAdapter.defaultProcessTimeout,
        replyPollInterval: TimeInterval = 2,
        startProcess: (@Sendable (_ executable: String, _ arguments: [String], _ workingDirectory: String?) -> OpencodeRunningProcess)? = nil
    ) {
        self.loadSnapshot = loadSnapshot
        self.locateExecutable = locateExecutable
        self.processTimeout = processTimeout
        self.replyPollInterval = replyPollInterval
        self.startProcess = startProcess ?? { executable, arguments, workingDirectory in
            OpencodeSpawnedProcess(executable: executable, arguments: arguments, workingDirectory: workingDirectory)
        }
    }

    func capability(forSessionID sessionID: String) -> DeliveryCapability {
        guard locateExecutable(Self.executableName) != nil else {
            return .unavailable("Two-way unavailable: the opencode CLI was not found on PATH.")
        }
        guard loadSnapshot(sessionID) != nil else {
            return .unavailable("Two-way unavailable: no opencode session for this session yet.")
        }
        // A headless `opencode run` is a second writer; wait for the session to be quiet.
        return DeliveryCapability(canDeliver: true, requiresIdle: true)
    }

    /// The race outcome between the lingering process's own exit and the
    /// database showing the completed reply.
    private enum DeliveryOutcome {
        case replyLanded(text: String)     // DB reply appeared (authoritative)
        case processExited(ProcessRunResult)
        case timedOut
    }

    func deliver(_ instruction: Instruction) async -> Result<DeliveryReceipt, InstructionDeliveryError> {
        guard let executable = locateExecutable(Self.executableName) else {
            return .failure(.notDeliverable("opencode CLI not found."))
        }
        guard let snapshot = loadSnapshot(instruction.sessionID) else {
            return .failure(.sessionGone)
        }
        // Message-time cursor captured BEFORE the resume (not a file byte
        // offset): the reply is the first completed assistant turn created
        // after this. Frozen `workingDirectory` (the session's project dir,
        // staged the same way Claude/Grok freeze it) is the cwd; the
        // session/config decide the model, never a flag.
        let checkpoint = OpencodeDeliveryReadiness.checkpoint(messages: snapshot.messages)
        let workingDirectory = instruction.workingDirectory ?? snapshot.directory
        let arguments = Self.resumeArguments(sessionID: instruction.sessionID, instruction: instruction.text)
        let process = startProcess(executable, arguments, workingDirectory)

        // opencode run writes the reply then lingers, so race the DB poll against
        // the process's own exit, bounded by processTimeout. Whichever resolves
        // first wins; a lingering child is always terminated so it never orphans.
        let sessionID = instruction.sessionID
        let checkpointCopy = checkpoint
        let loadSnapshot = self.loadSnapshot
        let pollInterval = replyPollInterval
        let deadline = Date().addingTimeInterval(processTimeout)

        let outcome: DeliveryOutcome = await withTaskGroup(of: DeliveryOutcome.self) { group in
            group.addTask { .processExited(await process.waitForExit()) }
            group.addTask {
                func reply() -> String? {
                    guard let messages = loadSnapshot(sessionID)?.messages else { return nil }
                    return OpencodeReplyCorrelation.firstCompletedAssistantTurn(
                        messages: messages, afterCheckpoint: checkpointCopy
                    )?.text
                }
                while !Task.isCancelled {
                    if let text = reply() { return .replyLanded(text: text) }
                    let remaining = deadline.timeIntervalSinceNow
                    guard remaining > 0 else { break }
                    let nap = min(pollInterval, remaining)
                    try? await Task.sleep(nanoseconds: UInt64(max(0, nap) * 1_000_000_000))
                }
                if let text = reply() { return .replyLanded(text: text) }
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            // Terminate the lingering child unless it already exited on its own;
            // this also unblocks the exit-wait task so the group can drain.
            if case .processExited = first {} else { process.terminate() }
            group.cancelAll()
            for await _ in group {}
            return first
        }

        switch outcome {
        case .replyLanded(let text):
            // The database is authoritative for opencode. Return its completed
            // turn as evidence regardless of what the (still-running) stdout held.
            return .success(DeliveryReceipt(
                mechanism: "opencode-run",
                transcriptCheckpoint: checkpoint,
                replyText: text,
                replyTurnID: nil
            ))
        case .timedOut:
            return .failure(.deliveryFailed("opencode did not respond within \(Int(processTimeout))s; delivery timed out."))
        case .processExited(let result):
            // The process exited on its own before the DB poll saw a reply:
            // fall back to today's stdout-evidence path, unchanged.
            if result.timedOut {
                return .failure(.deliveryFailed("opencode did not respond within \(Int(processTimeout))s; delivery timed out."))
            }
            guard result.exitCode == 0 else {
                return .failure(.deliveryFailed(AgentResumeDeliveryAdapter.failureMessage(exitCode: result.exitCode, stderr: result.stderr)))
            }
            guard let evidence = Self.evidence(fromStdout: result.stdout) else {
                // Exit 0 alone is not proof of an accepted turn (a stale/wrong id
                // or a rejected turn can no-op silently); require parsed evidence.
                return .failure(.deliveryFailed("exited 0 but no assistant turn in output"))
            }
            return .success(DeliveryReceipt(
                mechanism: "opencode-run",
                transcriptCheckpoint: checkpoint,
                replyText: evidence.replyText,
                replyTurnID: evidence.turnID
            ))
        }
    }

    /// Argument vector for `opencode run`. Pure and testable. Never carries
    /// `-m/--model` (the session/config choose the model) nor opencode's `-p`
    /// (which is `--password`).
    static func resumeArguments(sessionID: String, instruction: String) -> [String] {
        ["run", "--session", sessionID, "--format", "json", instruction]
    }

    /// Parse `opencode run --format json` output for evidence of a completed
    /// assistant turn.
    ///
    /// ASSUMPTION (INF-395, unverified until the f24 gate runs the real CLI):
    /// `--format json` emits opencode's raw event bus as JSONL, in which the
    /// assistant reply surfaces as text-type parts (`{"type":"text","text":...}`,
    /// possibly nested under a `part`/`properties` envelope) alongside an event
    /// whose object carries `role == "assistant"`. This parser is deliberately
    /// shape-agnostic and defensive (like `grokEvidence`): it deep-scans every
    /// JSON event for the longest text-type value and any session/message id,
    /// and only accepts the result as evidence when it ALSO saw an
    /// `assistant`-role marker somewhere in the stream (so a bare echo of the
    /// user turn can't masquerade as a completed reply). Fails closed (`nil`)
    /// when no such text is found. The authoritative reply text used for
    /// narration/correlation comes from the SQLite rows, not this string, so a
    /// partial or streamed capture here still can't corrupt the filed card.
    static func evidence(fromStdout stdout: String) -> (replyText: String, turnID: String?)? {
        var best = ""
        var turnID: String?
        var sawAssistant = false
        for rawLine in stdout.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            scanForEvidence(object, best: &best, turnID: &turnID, sawAssistant: &sawAssistant)
        }
        let trimmed = best.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sawAssistant, !trimmed.isEmpty else { return nil }
        return (trimmed, turnID)
    }

    /// Recursively walk one decoded JSON event, keeping the longest text-type
    /// value seen (the fully-streamed reply is the longest), the last
    /// session/message identifier, and whether any assistant-role marker
    /// appeared.
    private static func scanForEvidence(
        _ value: Any,
        best: inout String,
        turnID: inout String?,
        sawAssistant: inout Bool
    ) {
        if let object = value as? [String: Any] {
            if (object["role"] as? String) == "assistant" { sawAssistant = true }
            if object["type"] as? String == "text",
               let text = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               text.count > best.count {
                best = text
            }
            for key in ["sessionID", "session_id", "sessionId", "messageID", "message_id"] {
                if let id = object[key] as? String, !id.isEmpty { turnID = id }
            }
            for nested in object.values { scanForEvidence(nested, best: &best, turnID: &turnID, sawAssistant: &sawAssistant) }
        } else if let array = value as? [Any] {
            for element in array { scanForEvidence(element, best: &best, turnID: &turnID, sawAssistant: &sawAssistant) }
        }
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

/// The production `OpencodeRunningProcess` (INF-395). Starts `opencode run` with
/// the same hardened setup `AgentResumeDeliveryAdapter.defaultSpawn` uses (env
/// HOME/PATH, nulled stdin so it never blocks, bounded output capture, cwd), but
/// - critically - imposes NO internal timeout watchdog. opencode lingers after
/// finishing the turn, so the adapter, not this process, owns the deadline and
/// calls `terminate()`. `waitForExit()` only resolves when the process actually
/// exits (which, for a lingering child, means after `terminate()`); reading
/// `terminationStatus` is safe there because Foundation invokes
/// `terminationHandler` only after the process has exited.
private final class OpencodeSpawnedProcess: OpencodeRunningProcess, @unchecked Sendable {
    private let process = Process()
    private let outBuffer = BoundedOutputBuffer(capacity: AgentResumeDeliveryAdapter.maxCapturedBytes)
    private let errBuffer = BoundedOutputBuffer(capacity: AgentResumeDeliveryAdapter.maxCapturedBytes)
    private let lock = NSLock()
    private var result: ProcessRunResult?
    private var waiter: CheckedContinuation<ProcessRunResult, Never>?
    /// Grace before SIGTERM escalates to SIGKILL.
    private static let killGracePeriod: TimeInterval = 5

    init(executable: String, arguments: [String], workingDirectory: String?) {
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
        // Same rationale as defaultSpawn: an inherited never-EOF stdin makes
        // `opencode run` block; the instruction travels via argv.
        process.standardInput = FileHandle.nullDevice

        let outBuffer = self.outBuffer
        let errBuffer = self.errBuffer
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
        process.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            self?.finish(exitCode: proc.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            errBuffer.append(Data(error.localizedDescription.utf8))
            finish(exitCode: -1)
        }
    }

    private func finish(exitCode: Int32) {
        lock.lock()
        if result != nil { lock.unlock(); return }
        let resolved = ProcessRunResult(
            exitCode: exitCode,
            stdout: outBuffer.string(),
            stderr: errBuffer.string(),
            timedOut: false
        )
        result = resolved
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(returning: resolved)
    }

    func waitForExit() async -> ProcessRunResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let resolved = result {
                lock.unlock()
                continuation.resume(returning: resolved)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }

    func terminate() {
        lock.lock()
        let alreadyDone = result != nil
        lock.unlock()
        guard !alreadyDone, process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate() // SIGTERM
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.killGracePeriod) { [weak process] in
            guard let process, process.isRunning else { return }
            kill(pid, SIGKILL)
        }
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

/// opencode's analog of `SessionFileObservation` (INF-395): there is no file
/// size/mtime to compare, so session stability is judged by the latest
/// message's time and the message count. Two consecutive observations with the
/// same state, both older than the quiet window, mean the session is idle.
struct OpencodeObservation: Equatable {
    var latestTimeCreatedMillis: Int64
    var messageCount: Int
    var observedAt: Date

    init(messages: [OpencodeTranscriptAdapter.MessageRow], observedAt: Date) {
        self.latestTimeCreatedMillis = messages.last.map { Int64($0.timeCreated) } ?? 0
        self.messageCount = messages.count
        self.observedAt = observedAt
    }

    func hasSameState(as other: OpencodeObservation) -> Bool {
        latestTimeCreatedMillis == other.latestTimeCreatedMillis && messageCount == other.messageCount
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
            case .grokBuild:
                // Reached in production since INF-394: the grok_build source now
                // has a registered AgentResumeDeliveryAdapter, so its delivery
                // readiness (quiet session, no pending tool calls, a completed
                // assistant turn) is classified here exactly like Codex/Claude.
                scanGrokBuild(
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

    /// Grok Build's `chat_history.jsonl` shape (verified on real sessions,
    /// INF-361): `assistant.tool_calls` are pending until a `tool_result`
    /// names the matching `tool_call_id`; a completed assistant turn is
    /// non-empty prose with no pending calls.
    private static func scanGrokBuild(
        _ object: [String: Any],
        index: Int,
        pendingTools: inout Set<String>,
        lastRealUser: inout Int?,
        lastCompletedAssistant: inout Int?,
        lastTurnActivity: inout Int?
    ) {
        switch object["type"] as? String {
        case "assistant":
            let hasText = !((object["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
            if let toolCalls = object["tool_calls"] as? [[String: Any]] {
                for call in toolCalls {
                    if let id = call["id"] as? String { pendingTools.insert(id) }
                }
            }
            lastTurnActivity = index
            if hasText, pendingTools.isEmpty { lastCompletedAssistant = index }
        case "tool_result":
            if let id = object["tool_call_id"] as? String { pendingTools.remove(id) }
            lastTurnActivity = index
        case "user":
            guard let blocks = object["content"] as? [[String: Any]] else { return }
            let hasRealText = blocks.contains { block in
                guard block["type"] as? String == "text", let text = block["text"] as? String else { return false }
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if hasRealText {
                lastRealUser = index
                lastTurnActivity = index
            }
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
            case .grokBuild:
                // Reached in production since INF-394: grok_build has a
                // registered delivery adapter, so a delivered instruction's
                // reply is correlated positionally from the chat_history.jsonl
                // slice exactly like Codex/Claude.
                completed = grokBuildCompletedAssistantText(object, pendingTools: &pendingTools)
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

    private static func grokBuildCompletedAssistantText(
        _ object: [String: Any],
        pendingTools: inout Set<String>
    ) -> String? {
        switch object["type"] as? String {
        case "assistant":
            if let toolCalls = object["tool_calls"] as? [[String: Any]] {
                for call in toolCalls {
                    if let id = call["id"] as? String { pendingTools.insert(id) }
                }
            }
            guard pendingTools.isEmpty,
                  let text = (object["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return text
        case "tool_result":
            if let id = object["tool_call_id"] as? String { pendingTools.remove(id) }
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
