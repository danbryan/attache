import AttacheCore
import Darwin
import XCTest
@testable import AttacheApp

/// INF-252 (C3): `conversationSystemPrompt` now tells the personality how to
/// relay a blocked/failed/expired send (state what happened, give the one
/// next step, never claim success, never invent a recovery option that
/// wasn't reported). Whether a real LLM actually follows that instruction
/// can't be checked with a scripted mock; that judgment call is left to real
/// usage and the opt-in live routing canary pattern
/// (`ATTACHE_LIVE_CODEX_ROUTING_TEST`, see
/// `AttachePresentationCLIToolBridgeTests`).
///
/// What CAN be checked here, safely and without an app, AX automation, or a
/// real Codex/Claude CLI: the wire path from a genuine blocked-send status
/// (C2's `AgentInstructionMismatch`, the real production type) through
/// `converse()`'s tool-result loop to the personality's final spoken text.
/// This reuses `scripts/personality-two-way-smoke-server.py` directly (the
/// same deterministic mock the f8/f15/f16 UI smokes already drive) over a
/// loopback socket, so a failure here means the relay itself is broken, not
/// that a real model chose not to comply.
final class AttachePresentationErrorRelayTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func freeLoopbackPort() throws -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XCTSkip("could not create a probe socket to pick a free port") }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw XCTSkip("could not bind a probe socket to pick a free port") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        guard result == 0 else { throw XCTSkip("could not read back the bound probe port") }
        return UInt16(bigEndian: addr.sin_port)
    }

    private struct MockPersonalityServer {
        let process: Process
        let providerLogURL: URL
        let port: UInt16

        func stop() {
            process.terminate()
            process.waitUntilExit()
        }
    }

    /// Starts `scripts/personality-two-way-smoke-server.py` as a loopback-only
    /// subprocess, exactly as the shell-driven UI smokes do. No app is
    /// launched and no Mac state outside a temp log file and an ephemeral
    /// port is touched.
    private func startMockPersonalityServer(nonce: String, mismatchToken: String) throws -> MockPersonalityServer {
        let script = Self.repoRoot.appendingPathComponent("scripts/personality-two-way-smoke-server.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw XCTSkip("personality-two-way-smoke-server.py not found at \(script.path)")
        }
        let port = try freeLoopbackPort()
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-personality-error-relay-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["ATTACHE_PERSONALITY_TWO_WAY_NONCE"] = nonce
        environment["ATTACHE_PERSONALITY_TWO_WAY_PONG_TOKEN"] = "ATTACHE_UNUSED_\(nonce)"
        environment["ATTACHE_PERSONALITY_TWO_WAY_MISMATCH_TOKEN"] = mismatchToken
        environment["ATTACHE_PERSONALITY_TWO_WAY_PROVIDER_LOG"] = logURL.path
        environment["ATTACHE_PERSONALITY_TWO_WAY_MODEL"] = "attache-error-relay-smoke"
        environment["ATTACHE_PERSONALITY_TWO_WAY_PORT"] = String(port)
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let text = try? String(contentsOf: logURL, encoding: .utf8), text.contains("\"event\": \"ready\"") {
                return MockPersonalityServer(process: process, providerLogURL: logURL, port: port)
            }
            if !process.isRunning {
                throw XCTSkip("mock personality server exited before becoming ready")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.terminate()
        throw XCTSkip("mock personality server did not become ready in time")
    }

    /// The richest blocked-send status available today: the model named an
    /// agent (Claude Code) that IS being watched, but the frozen focused
    /// target is a different one (Codex). `AgentInstructionMismatch.evaluate`
    /// (C2, real production code, not a test double) produces a message with
    /// both a reason ("The focused session is Codex...") and a single next
    /// step ("Ask the user to focus a Claude Code session, or to confirm
    /// sending to Codex.") plus the stable "No staging occurred." marker.
    /// This is exactly the shape the new error-behavior block asks the
    /// personality to relay; the test proves that content survives the
    /// tool-result round trip unmangled.
    func testBlockedWrongAgentSendRelaysReasonAndNextStepThroughTheWireIntact() async throws {
        let nonce = "err-relay-\(UUID().uuidString.prefix(8))"
        let mismatchToken = "ATTACHE_MISMATCH_\(nonce)"
        let server = try startMockPersonalityServer(nonce: nonce, mismatchToken: mismatchToken)
        defer { server.stop() }

        let suiteName = "AttacheErrorRelayTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create isolated defaults for the error-relay smoke")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AttachePreferenceKey.presentationLLMEnabled)

        let service = AttachePresentationService(defaults: defaults, environment: [
            "ATTACHE_LLM_PROVIDER": "ollama",
            "ATTACHE_LLM_BASE_URL": "http://127.0.0.1:\(server.port)/v1",
            "ATTACHE_LLM_MODEL": "attache-error-relay-smoke"
        ])

        // The same conversationSystemPrompt AppModel builds for a live call,
        // including the new error-behavior block (unconditionally present;
        // see AttachePersonalityTests).
        let system = AttachePersonality.conversationSystemPrompt(
            memoryContext: nil,
            sessionTitle: "Weekly Codex Improvement Review",
            sessionSourceName: "Codex",
            workingDirectory: "/tmp/attache-error-relay-smoke",
            latestSummary: "Ready",
            canStageAgentInstruction: true
        )
        let user = "Tell Claude Code to reply exactly \(mismatchToken) and do not use tools."

        let result: Result<AttacheConversationReply, Error> = await withCheckedContinuation { continuation in
            service.converse(
                messages: [
                    AttacheChatMessage(role: "system", content: system),
                    AttacheChatMessage(role: "user", content: user)
                ],
                allowAgentInstructionTool: true,
                executeTool: { name, arguments in
                    guard name == "stage_agent_instruction",
                          let data = arguments.data(using: .utf8),
                          let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let intendedAgent = decoded["intended_agent"] as? String else {
                        return "unexpected tool call in error-relay smoke: \(name)"
                    }
                    // Real production comparison (C2): Claude Code IS watched,
                    // but Codex is the frozen focused target, so this must
                    // refuse, exactly like AppModel.applyStageAgentInstructionTool.
                    let mismatch = AgentInstructionMismatch.evaluate(
                        intendedAgent: intendedAgent,
                        focusedSource: .codex,
                        focusedTitle: "Weekly Codex Improvement Review",
                        watchedSources: [.codex, .claudeCode]
                    )
                    guard let mismatch else { return "no mismatch: staging would have proceeded" }
                    XCTAssertEqual(mismatch.status, .blockedWrongAgent)
                    return mismatch.message
                },
                completion: { continuation.resume(returning: $0) }
            )
        }

        let reply = try result.get().text
        XCTAssertTrue(reply.contains("Attaché said:"), "expected the mock's canned relay wrapper; got: \(reply)")
        XCTAssertTrue(reply.contains("No staging occurred."), "reply dropped the reason marker; got: \(reply)")
        XCTAssertTrue(
            reply.contains("The focused session is Codex (Weekly Codex Improvement Review)."),
            "reply dropped what happened; got: \(reply)"
        )
        XCTAssertTrue(
            reply.contains("Ask the user to focus a Claude Code session, or to confirm sending to Codex."),
            "reply dropped the single next step; got: \(reply)"
        )
        // Never implies the send succeeded.
        XCTAssertFalse(reply.localizedCaseInsensitiveContains("sent to claude"))
        XCTAssertFalse(reply.localizedCaseInsensitiveContains("delivered"))
    }
}
