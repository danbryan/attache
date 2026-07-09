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
struct AgentResumeDeliveryAdapter: InstructionDeliveryAdapter {
    enum Vendor {
        case claude
        case codex

        var sourceKind: String { self == .claude ? SourceKind.claudeCode.rawValue : SourceKind.codex.rawValue }
        var executableName: String { self == .claude ? "claude" : "codex" }
        var displayName: String { self == .claude ? "Claude Code" : "Codex" }
    }

    let vendor: Vendor
    /// Resolves the session transcript so the readiness gate can inspect stable
    /// file state and completed turns. Injected for testability.
    let locateSessionFile: @Sendable (String) -> URL?
    /// Locates the vendor CLI (defaults to the shared `CLILanguageModel.locate`).
    let locateExecutable: @Sendable (String) -> String?
    /// Spawns the resume and returns (exitCode, stderr). Injected so tests don't
    /// shell out.
    let spawn: @Sendable (_ executable: String, _ arguments: [String]) async -> (exitCode: Int32, stderr: String)

    var sourceKind: String { vendor.sourceKind }

    init(
        vendor: Vendor,
        locateSessionFile: @escaping @Sendable (String) -> URL?,
        locateExecutable: @escaping @Sendable (String) -> String? = { CLILanguageModel.locate($0) },
        spawn: (@Sendable (_ executable: String, _ arguments: [String]) async -> (exitCode: Int32, stderr: String))? = nil
    ) {
        self.vendor = vendor
        self.locateSessionFile = locateSessionFile
        self.locateExecutable = locateExecutable
        self.spawn = spawn ?? { await AgentResumeDeliveryAdapter.defaultSpawn($0, $1) }
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
        let result = await spawn(executable, arguments)
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.deliveryFailed(detail.isEmpty ? "exit \(result.exitCode)" : detail))
        }
        return .success(DeliveryReceipt(mechanism: "headless-resume", transcriptCheckpoint: checkpoint))
    }

    /// Argument vector for the (unsandboxed) resume. Pure and testable.
    static func resumeArguments(vendor: Vendor, sessionID: String, instruction: String) -> [String] {
        switch vendor {
        case .claude:
            // `claude -p --resume <id> "<instruction>"`: print mode (non-interactive),
            // acting with the user's own Claude Code permissions.
            return ["-p", "--resume", sessionID, instruction]
        case .codex:
            // `codex exec resume <id> "<instruction>"`: non-interactive resume using
            // the user's own Codex config/sandbox settings.
            return ["exec", "resume", sessionID, instruction]
        }
    }

    private static func defaultSpawn(_ executable: String, _ arguments: [String]) async -> (exitCode: Int32, stderr: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            env["HOME"] = home
            env["PATH"] = CLILanguageModel.mergedPATH(existing: env["PATH"], home: home)
            process.environment = env
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { proc in
                // stderr on a resume is small (errors only); read it once after exit.
                let data = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                let stderr = String(decoding: data, as: UTF8.self)
                continuation.resume(returning: (proc.terminationStatus, stderr))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
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

enum SessionReplyCorrelation {
    static func matches(
        instructionText: String,
        eventText: String,
        transcriptText: String,
        format: TranscriptFormat
    ) -> Bool {
        var sawInstruction = false
        let expectedInstruction = normalized(instructionText)
        let expectedReply = normalized(eventText)

        for line in transcriptText.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            switch format {
            case .codex:
                guard let payload = object["payload"] as? [String: Any],
                      payload["type"] as? String == "message" else { continue }
                if payload["role"] as? String == "user",
                   normalized(assistantText(fromCodexPayload: payload) ?? "") == expectedInstruction {
                    sawInstruction = true
                } else if sawInstruction,
                          payload["role"] as? String == "assistant",
                          payload["phase"] as? String == "final_answer",
                          normalized(assistantText(fromCodexPayload: payload) ?? "") == expectedReply {
                    return true
                }
            case .claude:
                guard object["isSidechain"] as? Bool != true,
                      let message = object["message"] as? [String: Any] else { continue }
                if object["type"] as? String == "user",
                   normalized(claudeMessageText(message) ?? "") == expectedInstruction {
                    sawInstruction = true
                } else if sawInstruction,
                          object["type"] as? String == "assistant",
                          normalized(claudeMessageText(message) ?? "") == expectedReply {
                    return true
                }
            }
        }
        return false
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
