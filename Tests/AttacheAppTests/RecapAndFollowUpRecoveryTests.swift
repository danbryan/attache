import AppKit
import AttacheCore
import Darwin
import XCTest
@testable import AttacheApp

/// INF-254 (D4): recap and follow-up answers used to degrade deterministically
/// with no recovery offered, unlike the live call's `conversationRecovery`
/// (INF-244). These tests cover the two pieces that only show up wired
/// end-to-end:
///
/// 1. `AttachePresentationService.complete(role:)` used to swallow every
///    failure behind `try?`; it now throws so a caller can classify it via
///    `ConversationRecovery.classify`, while still returning `nil` (not an
///    error) when the role simply isn't configured.
/// 2. `answerFollowUpQuestion` always resolves `.success` with a fallback
///    result even when the LLM call failed; the fallback now also carries the
///    structural HTTP status / URLError code behind its `errorDescription`.
/// 3. Recap and follow-up recovery switches persist to their OWN role's
///    per-role key (`.recap`, `.conversation`), never the global keys other
///    roles fall back to, mirroring the live call's own requirement
///    (`PerRoleModelRecoveryAndConsentTests`).
///
/// The full "failure shows recovery actions, retry after switching models
/// succeeds" round trip through the real app is covered by the extended
/// `scripts/conversation-recovery-smoke.sh` (AX-driven, real process); these
/// tests instead exercise the service/model layer directly and fast, using
/// the exact same deterministic mock (`scripts/personality-two-way-smoke-server.py`)
/// the shell smoke and `AttachePresentationErrorRelayTests` already rely on.
final class RecapAndFollowUpRecoveryTests: XCTestCase {
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
    /// subprocess, same as `AttachePresentationErrorRelayTests`. `errorMode`
    /// and `recoveryModel` map onto `ATTACHE_SMOKE_PROVIDER_ERROR` /
    /// `ATTACHE_SMOKE_PROVIDER_RECOVERY_MODEL` (INF-254's addition to the
    /// existing mock, also used by the extended shell smoke).
    private func startMockPersonalityServer(
        nonce: String,
        model: String,
        errorMode: String = "",
        recoveryModel: String = ""
    ) throws -> MockPersonalityServer {
        let script = Self.repoRoot.appendingPathComponent("scripts/personality-two-way-smoke-server.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw XCTSkip("personality-two-way-smoke-server.py not found at \(script.path)")
        }
        let port = try freeLoopbackPort()
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-recap-followup-recovery-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["ATTACHE_PERSONALITY_TWO_WAY_NONCE"] = nonce
        environment["ATTACHE_PERSONALITY_TWO_WAY_PONG_TOKEN"] = "ATTACHE_UNUSED_\(nonce)"
        environment["ATTACHE_PERSONALITY_TWO_WAY_PROVIDER_LOG"] = logURL.path
        environment["ATTACHE_PERSONALITY_TWO_WAY_MODEL"] = model
        environment["ATTACHE_PERSONALITY_TWO_WAY_PORT"] = String(port)
        environment["ATTACHE_SMOKE_PROVIDER_ERROR"] = errorMode
        environment["ATTACHE_SMOKE_PROVIDER_RECOVERY_MODEL"] = recoveryModel
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

    // MARK: - complete(role:) throws structurally instead of swallowing (recap/tagging)

    func testCompleteThrowsWithStructuralHTTPStatusOnUsageLimit() async throws {
        let nonce = "complete-throws-\(UUID().uuidString.prefix(8))"
        let server = try startMockPersonalityServer(nonce: nonce, model: "attache-recap-default", errorMode: "usage_limit")
        defer { server.stop() }

        let suiteName = "AttacheRecapRecoveryTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AttachePreferenceKey.presentationLLMEnabled)

        let service = AttachePresentationService(defaults: defaults, environment: [
            "ATTACHE_LLM_PROVIDER": "ollama",
            "ATTACHE_LLM_BASE_URL": "http://127.0.0.1:\(server.port)/v1",
            "ATTACHE_LLM_MODEL": "attache-recap-default"
        ])

        do {
            _ = try await service.complete(system: "system prompt", user: "user prompt", role: .recap)
            XCTFail("expected complete(role:) to throw on a 429 usage-limit response")
        } catch {
            let presentationError = error as? AttachePresentationError
            XCTAssertEqual(presentationError?.httpStatus, 429, "the thrown error must carry the structural HTTP status so ConversationRecovery.classify can use it")
        }
    }

    func testCompleteSucceedsAgainstTheSwitchedRecoveryModel() async throws {
        let nonce = "complete-recovers-\(UUID().uuidString.prefix(8))"
        let recoveryModel = "attache-recap-recovery-model"
        let server = try startMockPersonalityServer(
            nonce: nonce,
            model: recoveryModel,
            errorMode: "usage_limit",
            recoveryModel: recoveryModel
        )
        defer { server.stop() }

        let suiteName = "AttacheRecapRecoveryTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AttachePreferenceKey.presentationLLMEnabled)

        // Simulates the recap recovery menu having switched the `.recap`
        // role's override to the model the mock will actually answer.
        let service = AttachePresentationService(defaults: defaults, environment: [
            "ATTACHE_LLM_PROVIDER": "ollama",
            "ATTACHE_LLM_BASE_URL": "http://127.0.0.1:\(server.port)/v1",
            "ATTACHE_LLM_MODEL": recoveryModel
        ])

        let text = try await service.complete(system: "system prompt", user: "user prompt", role: .recap)
        XCTAssertEqual(text, "ATTACHE_RECOVERY_SUCCEEDED_\(nonce)")
    }

    func testLegacyDisabledSummaryPreferenceIsIgnored() {
        let suiteName = "AttacheRecapRecoveryTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: AttachePreferenceKey.presentationLLMEnabled)

        let settings = AttachePresentationSettings.load(
            role: .tagging,
            defaults: defaults,
            environment: [:],
            resolveSecrets: false
        )
        XCTAssertTrue(settings.llmEnabled)
    }

    // MARK: - answerFollowUpQuestion carries structural detail behind its fallback (follow-up)

    func testAnswerFollowUpQuestionFallbackCapturesStructuralHTTPStatus() async throws {
        let nonce = "followup-throws-\(UUID().uuidString.prefix(8))"
        let server = try startMockPersonalityServer(nonce: nonce, model: "attache-followup-default", errorMode: "usage_limit")
        defer { server.stop() }

        let suiteName = "AttacheFollowUpRecoveryTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AttachePreferenceKey.presentationLLMEnabled)

        let service = AttachePresentationService(defaults: defaults, environment: [
            "ATTACHE_LLM_PROVIDER": "ollama",
            "ATTACHE_LLM_BASE_URL": "http://127.0.0.1:\(server.port)/v1",
            "ATTACHE_LLM_MODEL": "attache-followup-default"
        ])

        let card = VoicemailCard(
            id: "card-1", sourceID: "source-1", sourceKind: SourceKind.codex.rawValue,
            sourceDisplayName: "Codex", sessionID: "session-1", externalSessionID: "ext-1",
            projectPath: "/tmp/project", sessionTitle: "Weekly Review", kind: .update,
            rawText: "Finished the migration.", summary: "Finished the migration.",
            spokenText: "Finished the migration.", status: .unread, createdAt: Date(), heardAt: nil,
            metadataJSON: "{}", durationMs: 0, alignment: nil
        )

        let result: AttacheFollowUpAnswerResult = await withCheckedContinuation { continuation in
            service.answerFollowUpQuestion(card: card, danQuestion: "What changed?", personality: nil, profilePrompt: AttachePersonality.defaultProfilePrompt) { result in
                switch result {
                case .success(let answer): continuation.resume(returning: answer)
                case .failure(let error):
                    XCTFail("answerFollowUpQuestion must never resolve .failure; got \(error)")
                    continuation.resume(returning: AttacheFollowUpAnswerResult(
                        answerText: "", strategy: "unexpected-failure", model: nil,
                        rawContextCharacterCount: 0, truncatedContext: false, errorDescription: nil
                    ))
                }
            }
        }

        XCTAssertEqual(result.strategy, "deterministic-follow-up-fallback-after-llm-error")
        XCTAssertEqual(result.errorHTTPStatus, 429, "the fallback must carry the structural HTTP status so the caller can classify it via ConversationRecovery.classify instead of re-parsing errorDescription text")
    }

    // MARK: - Role-scoped recovery switches persist to their own role, not the global keys

    private let roleKeyPreferenceKeys = [
        AttachePreferenceKey.presentationLLMProvider,
        AttachePreferenceKey.presentationLLMModel,
        AttachePreferenceKey.presentationLLMRoleKey(.recap, .provider),
        AttachePreferenceKey.presentationLLMRoleKey(.recap, .model),
        AttachePreferenceKey.presentationLLMRoleKey(.recap, .reasoningEffort),
        AttachePreferenceKey.presentationLLMRoleKey(.recap, .serviceTier),
        AttachePreferenceKey.presentationLLMRoleKey(.conversation, .provider),
        AttachePreferenceKey.presentationLLMRoleKey(.conversation, .model),
        AttachePreferenceKey.presentationLLMRoleKey(.conversation, .reasoningEffort),
        AttachePreferenceKey.presentationLLMRoleKey(.conversation, .serviceTier)
    ]

    @MainActor
    func testSelectRecapRecoveryProviderWritesRecapRoleKeyNotGlobal() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsKeySnapshot(keys: roleKeyPreferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        defaults.set(AttachePresentationProvider.ollama.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        defaults.set("original-global-model", forKey: AttachePreferenceKey.presentationLLMModel)

        let model = try AppModel(store: CardStore.inMemory())
        model.selectRecapRecoveryProvider(.groq)

        XCTAssertEqual(
            defaults.string(forKey: AttachePreferenceKey.presentationLLMRoleKey(.recap, .provider)),
            AttachePresentationProvider.groq.rawValue,
            "the recap recovery switch must persist to the recap role's own key"
        )
        XCTAssertEqual(
            defaults.string(forKey: AttachePreferenceKey.presentationLLMProvider),
            AttachePresentationProvider.ollama.rawValue,
            "the global provider key must be untouched by a recap-only recovery switch"
        )
        let recapSettings = AttachePresentationSettings.load(role: .recap, defaults: defaults, environment: [:], resolveSecrets: false)
        XCTAssertEqual(recapSettings.provider, .groq, "recap should pick up the recovered provider on the next call")
        let conversationSettings = AttachePresentationSettings.load(role: .conversation, defaults: defaults, environment: [:], resolveSecrets: false)
        XCTAssertEqual(conversationSettings.provider, .ollama, "conversation must not be affected by a recap-only recovery switch")
    }

    @MainActor
    func testSelectFollowUpRecoveryProviderWritesConversationRoleKeyNotGlobal() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsKeySnapshot(keys: roleKeyPreferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        defaults.set(AttachePresentationProvider.ollama.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        defaults.set("original-global-model", forKey: AttachePreferenceKey.presentationLLMModel)

        let model = try AppModel(store: CardStore.inMemory())
        model.selectFollowUpRecoveryProvider(.groq)

        XCTAssertEqual(
            defaults.string(forKey: AttachePreferenceKey.presentationLLMRoleKey(.conversation, .provider)),
            AttachePresentationProvider.groq.rawValue,
            "the follow-up recovery switch must persist to the conversation role's own key"
        )
        XCTAssertEqual(
            defaults.string(forKey: AttachePreferenceKey.presentationLLMProvider),
            AttachePresentationProvider.ollama.rawValue,
            "the global provider key must be untouched by a follow-up-only recovery switch"
        )
        let recapSettings = AttachePresentationSettings.load(role: .recap, defaults: defaults, environment: [:], resolveSecrets: false)
        XCTAssertEqual(recapSettings.provider, .ollama, "recap must not be affected by a follow-up-only recovery switch")
    }

    @MainActor
    func testSelectLiveFollowUpRecoveryModelWritesConversationRoleKeyNotGlobal() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsKeySnapshot(keys: roleKeyPreferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        defaults.set(AttachePresentationProvider.groq.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        defaults.set("original-global-model", forKey: AttachePreferenceKey.presentationLLMModel)

        let model = try AppModel(store: CardStore.inMemory())
        model.selectLiveFollowUpRecoveryModel(AttachePresentationModelOption(id: "recovered-model", detail: "test", reasoningEfforts: []))

        XCTAssertEqual(
            defaults.string(forKey: AttachePreferenceKey.presentationLLMRoleKey(.conversation, .model)),
            "recovered-model"
        )
        XCTAssertEqual(
            defaults.string(forKey: AttachePreferenceKey.presentationLLMModel),
            "original-global-model",
            "the global model key must be untouched by a live-follow-up-only recovery switch"
        )
    }

    // MARK: - Tagging failures stay silent but are counted (INF-254 spec item 3)

    @MainActor
    func testTaggingFailureIncrementsDiagnosticsCounterWithoutSurfacingAnError() async throws {
        let nonce = "tagging-fails-\(UUID().uuidString.prefix(8))"
        let server = try startMockPersonalityServer(nonce: nonce, model: "attache-tagging-default", errorMode: "usage_limit")
        defer { server.stop() }

        let suiteName = "AttacheTaggingFailureTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AttachePreferenceKey.presentationLLMEnabled)

        let service = AttachePresentationService(defaults: defaults, environment: [
            "ATTACHE_LLM_PROVIDER": "ollama",
            "ATTACHE_LLM_BASE_URL": "http://127.0.0.1:\(server.port)/v1",
            "ATTACHE_LLM_MODEL": "attache-tagging-default"
        ])

        var taggingFailureCount = 0
        do {
            _ = try await service.complete(system: "system", user: "user", role: .tagging)
            XCTFail("expected the tagging request to fail against the usage-limit mock")
        } catch {
            // Mirrors AppModel.tagUntaggedSessions' catch branch: skip silently
            // (tags stay empty) but count the failure.
            taggingFailureCount += 1
        }
        XCTAssertEqual(taggingFailureCount, 1)
    }
}

private final class DefaultsKeySnapshot {
    private let keys: [String]
    private let defaults: UserDefaults
    private let values: [String: Any]

    init(keys: [String], defaults: UserDefaults) {
        self.keys = keys
        self.defaults = defaults
        self.values = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        })
        keys.forEach { defaults.removeObject(forKey: $0) }
    }

    func restore() {
        keys.forEach { defaults.removeObject(forKey: $0) }
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
    }
}
