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
    /// Resolves the session's transcript file so we can confirm it exists and, for
    /// the idle gate, read its modification time. Injected for testability.
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
        guard locateSessionFile(instruction.sessionID) != nil else {
            return .failure(.sessionGone)
        }
        let arguments = Self.resumeArguments(vendor: vendor, sessionID: instruction.sessionID, instruction: instruction.text)
        let result = await spawn(executable, arguments)
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.deliveryFailed(detail.isEmpty ? "exit \(result.exitCode)" : detail))
        }
        return .success(DeliveryReceipt(mechanism: "headless-resume"))
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
}

/// Classifies a session as idle vs mid-turn from its transcript file's activity,
/// so the engine never double-writes into a session that's actively being written.
/// Pure and testable; AppModel builds the engine's `sessionIsIdle` closure from it.
enum SessionActivityClassifier {
    /// Idle when the file exists and hasn't been appended to for at least
    /// `quietWindow` seconds (matches docs/two-way.md's idle definition).
    static func isIdle(lastModified: Date?, now: Date, quietWindow: TimeInterval = 6) -> Bool {
        guard let lastModified else { return false }
        return now.timeIntervalSince(lastModified) >= quietWindow
    }
}
