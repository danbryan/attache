import AttacheCore
import Foundation
import XCTest
@testable import AttacheApp

final class AttacheProductionRequestBrokerTests: XCTestCase {
    func testStaleCapabilityUsesUnknownEnvelopeUntilRefreshed() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let stale = AttacheModelCapabilityProfile(
            architecturalMaximum: 1_000_000,
            freshness: now.addingTimeInterval(-8 * 86_400),
            confidence: .authoritative,
            provenance: .providerMetadata
        )
        XCTAssertEqual(
            AttacheProductionRequestBroker.compilationCapability(
                stale,
                modelIdentity: ModelIdentity(
                    provider: "xai",
                    normalizedEndpoint: "https://api.x.ai/v1",
                    requestedModel: "grok"
                ),
                strategy: .automatic,
                now: now
            ),
            .unknown
        )
        XCTAssertEqual(
            AttacheProductionRequestBroker.compilationCapability(
                stale,
                modelIdentity: ModelIdentity(
                    provider: "xai",
                    normalizedEndpoint: "https://api.x.ai/v1",
                    requestedModel: "grok"
                ),
                strategy: AttacheContextStrategy(
                    .custom,
                    custom: AttacheContextCustomPolicy()
                ),
                now: now
            ),
            stale,
            "An explicit Custom policy must not be silently replaced."
        )
    }

    func testStaleFingerprintedOllamaCapabilityKeepsItsExactKnownCeiling() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let stale = AttacheModelCapabilityProfile(
            architecturalMaximum: 131_072,
            freshness: now.addingTimeInterval(-30 * 86_400),
            confidence: .observed,
            provenance: .providerMetadata
        )
        let identity = ModelIdentity(
            provider: "ollama",
            normalizedEndpoint: "http://127.0.0.1:11434/v1",
            requestedModel: "qwen3.6:35b",
            fingerprint: "sha256:unchanged"
        )

        XCTAssertEqual(
            AttacheProductionRequestBroker.compilationCapability(
                stale,
                modelIdentity: identity,
                strategy: .maximumCoverage,
                now: now
            ),
            stale
        )
    }

    func testStaleUnfingerprintedOllamaCapabilityUsesUnknownEnvelope() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let stale = AttacheModelCapabilityProfile(
            architecturalMaximum: 131_072,
            freshness: now.addingTimeInterval(-30 * 86_400),
            confidence: .observed,
            provenance: .providerMetadata
        )
        let identity = ModelIdentity(
            provider: "ollama",
            normalizedEndpoint: "http://127.0.0.1:11434/v1",
            requestedModel: "mutable-alias"
        )

        XCTAssertEqual(
            AttacheProductionRequestBroker.compilationCapability(
                stale,
                modelIdentity: identity,
                strategy: .automatic,
                now: now
            ),
            .unknown
        )
    }

    func testCompilerProfilesCover8K64K1M10MAndUnknown() throws {
        let broker = AttacheProductionRequestBroker()
        for capacity in [8_000, 64_000, 1_000_000, 10_000_000, nil] as [Int?] {
            let snapshot = makeSnapshot()
            let attempt = try makeAttempt(capacity: capacity, tools: true)
            let compiled = try broker.compile(
                snapshot: snapshot,
                attempt: attempt,
                messages: structuredRoundMessages()
            )

            XCTAssertEqual(compiled.modelIdentity, attempt.modelIdentity)
            XCTAssertEqual(compiled.receipt.modelIdentityKey, attempt.modelIdentity.capabilityKey)
            XCTAssertEqual(compiled.receipt.strategyKind, AttacheContextStrategy.automatic.kind.rawValue)
            if let hard = compiled.budgetPlan.effectiveHardLimit {
                XCTAssertLessThanOrEqual(compiled.receipt.totalEstimatedTokens, hard)
            }
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: compiled.serializedOutboundRequest) as? [String: Any]
            )
            XCTAssertNotNil(payload["tools"], "tool schema must be inside the measured provider payload")
            let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
            let assistant = try XCTUnwrap(messages.first { $0["role"] as? String == "assistant" })
            let call = try XCTUnwrap((assistant["tool_calls"] as? [[String: Any]])?.first)
            XCTAssertEqual(call["id"] as? String, "call-338")
            let toolResult = try XCTUnwrap(messages.first { $0["role"] as? String == "tool" })
            XCTAssertEqual(toolResult["tool_call_id"] as? String, "call-338")
        }
    }

    func testHTTPTransportReturnsActualReceiptAndProviderUsage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrokerStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let broker = AttacheProductionRequestBroker(urlSession: session)
        BrokerStubURLProtocol.failure = nil
        BrokerStubURLProtocol.responseBody = Data(#"""
        {
          "choices":[{"message":{"content":"Done.","tool_calls":[]}}],
          "usage":{"prompt_tokens":123,"completion_tokens":17,"total_tokens":140,"prompt_tokens_details":{"cached_tokens":11}}
        }
        """#.utf8)

        let snapshot = makeSnapshot()
        let attempt = try makeAttempt(capacity: 64_000, tools: false)
        let messages = [
            AttacheChatMessage(role: "system", content: "Stay concise."),
            AttacheChatMessage(role: "user", content: "question")
        ]
        let response = try await broker.perform(
            snapshot: snapshot,
            attempt: attempt,
            messages: messages
        )

        XCTAssertEqual(response.content, "Done.")
        XCTAssertEqual(response.metadata.usage.inputTokens, 123)
        XCTAssertEqual(response.metadata.usage.outputTokens, 17)
        XCTAssertEqual(response.metadata.usage.cachedTokens, 11)
        XCTAssertEqual(response.metadata.usage.totalTokens, 140)
        XCTAssertEqual(response.metadata.contextReceipt?.modelIdentityKey, attempt.modelIdentity.capabilityKey)
        XCTAssertTrue(response.metadata.contextReceipt?.includedSources.contains("activePersonality") == true)
        XCTAssertTrue(response.metadata.contextReceipt?.includedSources.contains("currentUserTurn") == true)
        XCTAssertFalse(response.metadata.receiptView.noModelContext)
        XCTAssertEqual(response.compiledMessages.last?.content, "question")
        XCTAssertEqual(BrokerStubURLProtocol.lastBody, try broker.compile(
            snapshot: snapshot,
            attempt: attempt,
            messages: messages
        ).serializedOutboundRequest)
    }

    func testReflectedProviderErrorBodyNeverEntersPersistedOrConversationText() async throws {
        let marker = "REFLECTED_PRIVATE_PROMPT_\(UUID().uuidString)"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrokerStubURLProtocol.self]
        let broker = AttacheProductionRequestBroker(urlSession: URLSession(configuration: configuration))
        let suite = "AttacheProductionRequestBrokerTests.error-reflection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AttachePresentationService(defaults: defaults, environment: [:], requestBroker: broker)
        let settings = AttachePresentationSettings(
            llmEnabled: true,
            provider: .ollama,
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            apiKey: "",
            apiKeySecretRef: "",
            model: "test-model",
            reasoningEffort: nil,
            serviceTier: nil,
            profilePrompt: "Stay concise."
        )
        let snapshot = makeSnapshot(role: .presentation, modelSettings: settings)
        let event = NormalizedEvent(
            source: SourceKind.codex.rawValue,
            eventType: "assistant.completed",
            externalSessionID: "safe-error-session",
            projectPath: "/tmp/safe-error",
            title: "Safe error",
            text: "A harmless agent result."
        )
        BrokerStubURLProtocol.failure = nil
        BrokerStubURLProtocol.statusCode = 500
        BrokerStubURLProtocol.responseBody = Data(#"{"error":"\#(marker)"}"#.utf8)
        defer {
            BrokerStubURLProtocol.statusCode = 200
            BrokerStubURLProtocol.responseBody = Data()
        }

        let prepared: AttachePreparedEventResult = await withCheckedContinuation { continuation in
            service.prepare(event, snapshot: snapshot) { continuation.resume(returning: $0) }
        }

        let persistedError = try XCTUnwrap(prepared.event.metadata["attache_presentation_error"])
        XCTAssertEqual(persistedError, "LLM request failed with HTTP 500.")
        XCTAssertFalse(persistedError.contains(marker))
        XCTAssertFalse("I hit a problem: \(persistedError)".contains(marker))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-safe-error-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CardStore(databaseURL: root.appendingPathComponent("cards.sqlite"))
        let card = try store.insertEvent(prepared.event)
        XCTAssertFalse(card.metadataJSON.contains(marker))
        XCTAssertFalse(try store.fetchCard(id: card.id).metadataJSON.contains(marker))

        let structural = AttachePresentationError.httpStatus(500, marker)
        XCTAssertEqual(structural.responseBody, marker)
        XCTAssertFalse(structural.localizedDescription.contains(marker))
    }

    func testProviderUsagePersistsConservativeCalibrationAndCustomBypassesIt() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-broker-calibration-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
        }
        let store = AttacheCalibrationStore(databaseURL: databaseURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrokerStubURLProtocol.self]
        let broker = AttacheProductionRequestBroker(
            urlSession: URLSession(configuration: configuration),
            calibrationStore: store
        )
        BrokerStubURLProtocol.failure = nil
        BrokerStubURLProtocol.responseHandler = nil
        BrokerStubURLProtocol.responseBody = Data(#"{"choices":[{"message":{"content":"Done."}}],"usage":{"prompt_tokens":100000,"completion_tokens":10}}"#.utf8)

        let snapshot = makeSnapshot()
        let automaticAttempt = try makeAttempt(capacity: 64_000, tools: false)
        let messages = [
            AttacheChatMessage(role: "system", content: "Stay concise."),
            AttacheChatMessage(role: "user", content: "question")
        ]
        for _ in 0..<5 {
            _ = try await broker.perform(
                snapshot: snapshot,
                attempt: automaticAttempt,
                messages: messages
            )
        }

        let storageKey = AttacheCalibrationStore.storageKey(
            modelIdentityKey: automaticAttempt.modelIdentity.capabilityKey,
            estimatorVersion: AttacheTokenUsageCalibrator.estimatorVersion
        )
        let diagnostics = try XCTUnwrap(store.diagnostics(for: storageKey))
        XCTAssertEqual(diagnostics.sampleCount, 5)
        XCTAssertTrue(diagnostics.isActionable)
        XCTAssertEqual(diagnostics.correctionFactor, 1.5, accuracy: 0.001)

        let calibrated = try broker.compile(
            snapshot: snapshot,
            attempt: automaticAttempt,
            messages: messages
        )
        let uncalibrated = try AttacheProductionRequestBroker(
            calibrationStore: nil
        ).compile(
            snapshot: snapshot,
            attempt: automaticAttempt,
            messages: messages
        )
        XCTAssertGreaterThan(
            calibrated.receipt.totalEstimatedTokens,
            uncalibrated.receipt.totalEstimatedTokens
        )
        XCTAssertEqual(
            calibrated.budgetPlan.effectiveHardLimit,
            uncalibrated.budgetPlan.effectiveHardLimit,
            "calibration never changes the authoritative hard limit"
        )

        let customStrategy = AttacheContextStrategy(
            .custom,
            custom: AttacheContextCustomPolicy(
                hardInputLimit: 64_000,
                effectiveInputLimit: 60_000
            )
        )
        let customAttempt = try makeAttempt(
            capacity: 64_000,
            tools: false,
            strategy: customStrategy
        )
        let customWithStore = try broker.compile(
            snapshot: snapshot,
            attempt: customAttempt,
            messages: messages
        )
        let customWithoutStore = try AttacheProductionRequestBroker(
            calibrationStore: nil
        ).compile(
            snapshot: snapshot,
            attempt: customAttempt,
            messages: messages
        )
        XCTAssertEqual(
            customWithStore.receipt.totalEstimatedTokens,
            customWithoutStore.receipt.totalEstimatedTokens,
            "Custom policy bypasses learned calibration"
        )
        _ = try await broker.perform(
            snapshot: snapshot,
            attempt: customAttempt,
            messages: messages
        )
        XCTAssertEqual(store.diagnostics(for: storageKey)?.sampleCount, 5)
    }

    func testMeasuredOverestimationUsesBoundedReductionOnlyForKnownCapacity() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-broker-down-calibration-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
        }
        let store = AttacheCalibrationStore(databaseURL: databaseURL)
        let knownAttempt = try makeAttempt(capacity: 64_000, tools: false)
        let key = knownAttempt.modelIdentity.capabilityKey
        for index in 0..<20 {
            XCTAssertTrue(store.record(AttacheProviderUsageSample(
                modelIdentityKey: key,
                estimatorVersion: AttacheTokenUsageCalibrator.estimatorVersion,
                strategyKind: "automatic",
                role: "conversation",
                estimatedInputTokens: 10_000,
                actualInputTokens: 4_000,
                actualOutputTokens: 10,
                timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
                receiptID: "down-\(index)"
            )))
        }
        let storageKey = AttacheCalibrationStore.storageKey(
            modelIdentityKey: key,
            estimatorVersion: AttacheTokenUsageCalibrator.estimatorVersion
        )
        let diagnostics = try XCTUnwrap(store.diagnostics(for: storageKey))
        XCTAssertTrue(diagnostics.isActionable)
        XCTAssertEqual(diagnostics.observedMedianRatio, 0.5, accuracy: 0.001)
        XCTAssertEqual(diagnostics.correctionFactor, 0.75, accuracy: 0.001)

        let snapshot = makeSnapshot(userInput: String(repeating: "context ", count: 300))
        let messages = [
            AttacheChatMessage(role: "system", content: "Stay concise."),
            AttacheChatMessage(role: "user", content: snapshot.userInput)
        ]
        let calibratedBroker = AttacheProductionRequestBroker(calibrationStore: store)
        let baseBroker = AttacheProductionRequestBroker(calibrationStore: nil)
        let calibrated = try calibratedBroker.compile(
            snapshot: snapshot,
            attempt: knownAttempt,
            messages: messages
        )
        let base = try baseBroker.compile(
            snapshot: snapshot,
            attempt: knownAttempt,
            messages: messages
        )
        XCTAssertLessThan(
            calibrated.receipt.totalEstimatedTokens,
            base.receipt.totalEstimatedTokens
        )
        XCTAssertEqual(calibrated.budgetPlan.effectiveHardLimit, 64_000)

        let unknownAttempt = try makeAttempt(capacity: nil, tools: false)
        let unknownCalibrated = try calibratedBroker.compile(
            snapshot: snapshot,
            attempt: unknownAttempt,
            messages: messages
        )
        let unknownBase = try baseBroker.compile(
            snapshot: snapshot,
            attempt: unknownAttempt,
            messages: messages
        )
        XCTAssertEqual(
            unknownCalibrated.receipt.totalEstimatedTokens,
            unknownBase.receipt.totalEstimatedTokens,
            "Unknown-capacity plans never use downward calibration"
        )
    }

    func testRevokedRequestCannotReachTransportAfterCompilation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrokerStubURLProtocol.self]
        let broker = AttacheProductionRequestBroker(
            urlSession: URLSession(configuration: configuration)
        )
        BrokerStubURLProtocol.requestCount = 0
        BrokerStubURLProtocol.failure = nil
        BrokerStubURLProtocol.responseBody = Data(
            #"{"choices":[{"message":{"content":"should not arrive"}}]}"#.utf8
        )
        let snapshot = makeSnapshot()
        let attempt = try makeAttempt(
            capacity: 64_000,
            tools: false,
            provider: .custom,
            baseURL: URL(string: "https://revoked.example/v1")!
        )

        do {
            _ = try await broker.perform(
                snapshot: snapshot,
                attempt: attempt,
                messages: [
                    AttacheChatMessage(role: "system", content: "Safety and personality."),
                    AttacheChatMessage(role: "user", content: "question")
                ],
                requestIsActive: { false }
            )
            XCTFail("Expected the final transport-boundary check to fail closed.")
        } catch let failure as AttacheBrokerAttemptFailure {
            XCTAssertTrue(failure.underlying is CancellationError)
            XCTAssertFalse(failure.inference.receiptView.attempts.isEmpty)
        }
        XCTAssertEqual(BrokerStubURLProtocol.requestCount, 0)
    }

    func testHTTPRedirectPolicyAlwaysRefusesUnconsentedDestination() throws {
        var redirected = URLRequest(url: URL(string: "https://unconsented.example/v1/chat/completions")!)
        redirected.httpMethod = "POST"
        redirected.httpBody = Data("REDIRECT_BODY_SENTINEL".utf8)

        XCTAssertNil(AttacheNoRedirectDelegate.redirectedRequest(redirected))

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let brokerSource = try String(contentsOf: root.appendingPathComponent(
            "Sources/AttacheApp/AttacheProductionRequestBroker.swift"
        ))
        XCTAssertTrue(brokerSource.contains("delegate: AttacheNoRedirectDelegate()"))
    }

    func testCanceledConversationCannotSendToolResultInSecondModelRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrokerStubURLProtocol.self]
        let broker = AttacheProductionRequestBroker(urlSession: URLSession(configuration: configuration))
        let suite = "AttacheProductionRequestBrokerTests.cancel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AttachePresentationService(defaults: defaults, environment: [:], requestBroker: broker)
        let gate = BrokerToolGate()
        let toolStarted = expectation(description: "tool execution started")
        let completed = expectation(description: "conversation completed")
        BrokerStubURLProtocol.failure = nil
        BrokerStubURLProtocol.requestCount = 0
        BrokerStubURLProtocol.responseHandler = { _, count in
            if count == 1 {
                return Data(#"{"choices":[{"message":{"content":"","tool_calls":[{"id":"call-cancel","type":"function","function":{"name":"propose_memory","arguments":"{}"}}]}}]}"#.utf8)
            }
            return Data(#"{"choices":[{"message":{"content":"should never be requested"}}]}"#.utf8)
        }
        defer { BrokerStubURLProtocol.responseHandler = nil }

        let settings = AttachePresentationSettings(
            llmEnabled: true,
            provider: .ollama,
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            apiKey: "",
            apiKeySecretRef: "",
            model: "test-model",
            reasoningEffort: nil,
            serviceTier: nil,
            profilePrompt: ""
        )
        let snapshot = makeSnapshot(modelSettings: settings)
        let task = service.converse(
            snapshot: snapshot,
            messages: [
                AttacheChatMessage(role: "system", content: "Stay concise."),
                AttacheChatMessage(role: "user", content: "question")
            ],
            allowSessionContextTools: false,
            allowMemoryProposalTool: true,
            executeTool: { _, _ in
                toolStarted.fulfill()
                await gate.wait()
                return "tool result that must not leave after cancellation"
            },
            completion: { _ in completed.fulfill() }
        )

        await fulfillment(of: [toolStarted], timeout: 2)
        task.cancel()
        await gate.release()
        await task.value
        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(BrokerStubURLProtocol.requestCount, 1)
    }

    func testMultiRoundConversationReceiptDisclosesEveryProviderCall() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrokerStubURLProtocol.self]
        let broker = AttacheProductionRequestBroker(
            urlSession: URLSession(configuration: configuration)
        )
        let service = AttachePresentationService(
            environment: [:],
            requestBroker: broker
        )
        BrokerStubURLProtocol.failure = nil
        BrokerStubURLProtocol.requestCount = 0
        BrokerStubURLProtocol.responseHandler = { _, count in
            if count == 1 {
                return Data(#"{"choices":[{"message":{"content":"","tool_calls":[{"id":"call-round","type":"function","function":{"name":"propose_memory","arguments":"{}"}}]}}]}"#.utf8)
            }
            return Data(#"{"choices":[{"message":{"content":"Final answer.","tool_calls":[]}}],"usage":{"prompt_tokens":50,"completion_tokens":10,"total_tokens":60}}"#.utf8)
        }
        defer { BrokerStubURLProtocol.responseHandler = nil }
        let settings = AttachePresentationSettings(
            llmEnabled: true,
            provider: .ollama,
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            apiKey: "",
            apiKeySecretRef: "",
            model: "test-model",
            reasoningEffort: nil,
            serviceTier: nil,
            profilePrompt: ""
        )
        let snapshot = makeSnapshot(modelSettings: settings)
        let completed = expectation(description: "multi-round conversation completed")
        var captured: Result<AttacheConversationReply, Error>?
        let task = service.converse(
            snapshot: snapshot,
            messages: [
                AttacheChatMessage(role: "system", content: "Stay concise."),
                AttacheChatMessage(role: "user", content: "question")
            ],
            allowSessionContextTools: false,
            allowMemoryProposalTool: true,
            executeTool: { _, _ in "proposal stayed local" },
            completion: {
                captured = $0
                completed.fulfill()
            }
        )

        await task.value
        await fulfillment(of: [completed], timeout: 2)
        let reply = try XCTUnwrap(captured).get()
        XCTAssertEqual(reply.text, "Final answer.")
        XCTAssertEqual(BrokerStubURLProtocol.requestCount, 2)
        XCTAssertEqual(reply.inference.receiptView.attempts.count, 2)
        XCTAssertTrue(
            reply.inference.receiptView.attempts[1].sourceSummaries.contains {
                $0.source == AttacheContextItemSource.toolResults.rawValue
                    && $0.disposition == .included
            }
        )
    }

    func testTransportFailureCarriesAttemptedModelReceiptInsteadOfNoModelReceipt() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrokerStubURLProtocol.self]
        let broker = AttacheProductionRequestBroker(
            urlSession: URLSession(configuration: configuration)
        )
        BrokerStubURLProtocol.failure = URLError(.cannotConnectToHost)
        defer { BrokerStubURLProtocol.failure = nil }
        let compiledRecorder = BrokerInferenceRecorder()

        do {
            _ = try await broker.perform(
                snapshot: makeSnapshot(),
                attempt: try makeAttempt(capacity: 64_000, tools: false),
                messages: [
                    AttacheChatMessage(role: "system", content: "Stay concise."),
                    AttacheChatMessage(role: "user", content: "question")
                ],
                attemptDidCompile: { await compiledRecorder.record($0) }
            )
            XCTFail("expected transport failure")
        } catch let failure as AttacheBrokerAttemptFailure {
            XCTAssertFalse(failure.inference.receiptView.noModelContext)
            XCTAssertNotNil(failure.inference.contextReceipt)
            XCTAssertNotNil(failure.inference.modelIdentity)
            XCTAssertTrue(
                failure.inference.contextReceipt?.includedSources.contains("activePersonality") == true
            )
            XCTAssertTrue(
                failure.inference.contextReceipt?.includedSources.contains("currentUserTurn") == true
            )
        }
        let preTransportInference = await compiledRecorder.inference
        XCTAssertFalse(preTransportInference?.receiptView.noModelContext ?? true)
        XCTAssertNotNil(preTransportInference?.contextReceipt)
    }

    func testSnapshotWithoutFrozenModelNeverInheritsConfiguredGlobalModel() async throws {
        let suite = "AttacheProductionRequestBrokerTests.frozen-none.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AttachePresentationProvider.custom.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        defaults.set("https://global.example/v1", forKey: AttachePreferenceKey.presentationLLMBaseURL)
        defaults.set("global-key", forKey: AttachePreferenceKey.presentationLLMAPIKey)
        defaults.set("global-model", forKey: AttachePreferenceKey.presentationLLMModel)
        let scope = PresentationConsentScope(provider: .custom, endpoint: "https://global.example/v1")
        defaults.set([scope.storageKey], forKey: AttachePreferenceKey.cloudConsentPresentationProviders)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrokerStubURLProtocol.self]
        let service = AttachePresentationService(
            defaults: defaults,
            environment: [:],
            requestBroker: AttacheProductionRequestBroker(
                urlSession: URLSession(configuration: configuration)
            )
        )
        BrokerStubURLProtocol.requestCount = 0
        let result = try await service.complete(
            snapshot: makeSnapshot(modelSettings: nil),
            system: "Stay concise.",
            user: "question"
        )

        XCTAssertNil(result.text)
        XCTAssertTrue(result.inference.receiptView.noModelContext)
        XCTAssertEqual(BrokerStubURLProtocol.requestCount, 0)
    }

    func testFrozenModelSettingsSurviveLaterGlobalPreferenceChange() async throws {
        let suite = "AttacheProductionRequestBrokerTests.frozen-settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let frozen = AttachePresentationSettings(
            llmEnabled: true,
            provider: .custom,
            baseURL: URL(string: "https://frozen.example/v1")!,
            apiKey: "frozen-key",
            apiKeySecretRef: "",
            model: "frozen-model",
            reasoningEffort: nil,
            serviceTier: nil,
            profilePrompt: ""
        )
        let scope = PresentationConsentScope(provider: frozen.provider, endpoint: frozen.baseURL.absoluteString)
        defaults.set([scope.storageKey], forKey: AttachePreferenceKey.cloudConsentPresentationProviders)
        defaults.set("changed-model", forKey: AttachePreferenceKey.presentationLLMModel)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrokerStubURLProtocol.self]
        BrokerStubURLProtocol.failure = nil
        BrokerStubURLProtocol.responseBody = Data(
            #"{"choices":[{"message":{"content":"Frozen."}}]}"#.utf8
        )
        let service = AttachePresentationService(
            defaults: defaults,
            environment: [:],
            requestBroker: AttacheProductionRequestBroker(
                urlSession: URLSession(configuration: configuration)
            )
        )
        let result = try await service.complete(
            snapshot: makeSnapshot(modelSettings: frozen),
            system: "Stay concise.",
            user: "question"
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(BrokerStubURLProtocol.lastBody))
                as? [String: Any]
        )

        XCTAssertEqual(result.text, "Frozen.")
        XCTAssertEqual(payload["model"] as? String, "frozen-model")
        XCTAssertEqual(BrokerStubURLProtocol.lastURL?.host, "frozen.example")
    }

    func testRemoteFallbackRecompilesFrozenSnapshotWithoutLocalOnlyMemory() throws {
        let localOnly = AttacheContextItem(
            source: .durableMemory,
            content: "LOCAL_ONLY_SENTINEL",
            provenance: "memory:local",
            egress: .localOnly,
            priority: 500
        )
        let allowed = AttacheContextItem(
            source: .durableMemory,
            content: "REMOTE_ALLOWED_SENTINEL",
            provenance: "memory:remote",
            egress: .allowedRemote,
            priority: 400
        )
        let snapshot = makeSnapshot(
            contextItems: [localOnly, allowed],
            memorySelectionReceipt: [
                AttacheMemoryReceiptEntry(memoryID: "local", disposition: .included),
                AttacheMemoryReceiptEntry(memoryID: "remote", disposition: .included)
            ]
        )
        let broker = AttacheProductionRequestBroker()
        let messages = [
            AttacheChatMessage(role: "system", content: "Stay concise."),
            AttacheChatMessage(role: "user", content: "question")
        ]
        let local = try broker.compile(
            snapshot: snapshot,
            attempt: makeAttempt(capacity: 64_000, tools: false),
            messages: messages
        )
        let remote = try broker.compile(
            snapshot: snapshot,
            attempt: makeAttempt(
                capacity: 64_000,
                tools: false,
                provider: .custom,
                baseURL: URL(string: "https://remote.example/v1")!
            ),
            messages: messages
        )

        XCTAssertTrue(local.messages.contains { $0.content.contains("LOCAL_ONLY_SENTINEL") })
        XCTAssertTrue(remote.messages.contains { $0.content.contains("REMOTE_ALLOWED_SENTINEL") })
        XCTAssertFalse(remote.messages.contains { $0.content.contains("LOCAL_ONLY_SENTINEL") })
        XCTAssertTrue(remote.receipt.omittedSourceIdentifiers?.contains("memory:local") == true)
    }

    func testFallbackReceiptKeepsFailedPrimaryAndLabelsSuccessfulRetry() throws {
        let broker = AttacheProductionRequestBroker()
        let snapshot = makeSnapshot()
        let messages = [
            AttacheChatMessage(role: "system", content: "Stay concise."),
            AttacheChatMessage(role: "user", content: "question")
        ]
        let primaryAttempt = try makeAttempt(capacity: 64_000, tools: false)
        let fallbackAttempt = try makeAttempt(
            capacity: 32_000,
            tools: false,
            provider: .custom,
            baseURL: URL(string: "https://fallback.example/v1")!
        )
        let primaryCompiled = try broker.compile(
            snapshot: snapshot,
            attempt: primaryAttempt,
            messages: messages
        )
        let fallbackCompiled = try broker.compile(
            snapshot: snapshot,
            attempt: fallbackAttempt,
            messages: messages
        )
        let primaryUsage = AttacheParsedTokenUsage(
            inputTokens: 100,
            outputTokens: 10,
            cachedTokens: 25,
            totalTokens: 110
        )
        let fallbackUsage = AttacheParsedTokenUsage(
            inputTokens: 80,
            outputTokens: 20,
            cachedTokens: 5,
            totalTokens: 100
        )
        let primary = AttacheInferenceMetadata.model(
            snapshot: snapshot,
            compiled: primaryCompiled,
            usage: primaryUsage,
            attempt: primaryAttempt
        )
        let successfulFallback = AttacheInferenceMetadata.model(
            snapshot: snapshot,
            compiled: fallbackCompiled,
            usage: fallbackUsage,
            attempt: fallbackAttempt
        ).recordingFallback(after: primary)

        XCTAssertTrue(successfulFallback.receiptView.usedFallback)
        XCTAssertEqual(successfulFallback.receiptView.attempts.count, 2)
        XCTAssertEqual(successfulFallback.receiptView.primaryAttempt?.modelSummary.provider, primaryAttempt.provider.rawValue)
        XCTAssertEqual(successfulFallback.receiptView.fallbackAttempt?.modelSummary.provider, fallbackAttempt.provider.rawValue)
        XCTAssertEqual(successfulFallback.receiptView.fallbackAttempt?.attemptNumber, 2)
        XCTAssertTrue(successfulFallback.receiptView.fallbackAttempt?.recompiledForFallback == true)
        XCTAssertEqual(successfulFallback.usage.inputTokens, 180)
        XCTAssertEqual(successfulFallback.usage.outputTokens, 30)
        XCTAssertEqual(successfulFallback.usage.cachedTokens, 30)
        XCTAssertEqual(successfulFallback.usage.totalTokens, 210)
    }

    func testExplicitPrebuiltDescriptorsDiscloseSafetyUserToolAndAgentEvidence() throws {
        let broker = AttacheProductionRequestBroker()
        let call = AttacheChatToolCall(id: "call-source", name: "propose_memory", arguments: "{}")
        let conversationMessages = [
            AttacheChatMessage(role: "system", content: "Safety plus personality."),
            AttacheChatMessage(role: "user", content: "earlier turn"),
            AttacheChatMessage(role: "assistant", content: "", toolCalls: [call]),
            AttacheChatMessage(role: "tool", content: "local tool result", toolCallID: call.id),
            AttacheChatMessage(role: "user", content: "question")
        ]
        let conversation = try broker.compile(
            snapshot: makeSnapshot(),
            attempt: makeAttempt(capacity: 64_000, tools: true),
            messages: conversationMessages,
            messageSources: AttacheProductionRequestBroker.prebuiltMessageSources(
                snapshot: makeSnapshot(),
                messages: conversationMessages
            )
        )
        let conversationSources = conversation.receipt.includedSources
        for source: AttacheContextItemSource in [
            .safetyPolicy, .activePersonality, .currentUserTurn,
            .recentDirectChatTurns, .toolResults, .toolDefinitions
        ] {
            XCTAssertTrue(conversationSources.contains(source.rawValue), "missing \(source)")
        }

        let presentationSnapshot = makeSnapshot(role: .presentation)
        let presentationMessages = [
            AttacheChatMessage(role: "system", content: "Narration policy and personality."),
            AttacheChatMessage(role: "user", content: "raw agent card evidence")
        ]
        let presentation = try broker.compile(
            snapshot: presentationSnapshot,
            attempt: makeAttempt(capacity: 64_000, tools: false, role: .presentation),
            messages: presentationMessages,
            messageSources: AttacheProductionRequestBroker.prebuiltMessageSources(
                snapshot: presentationSnapshot,
                messages: presentationMessages
            )
        )
        XCTAssertTrue(presentation.receipt.includedSources.contains(AttacheContextItemSource.latestAgentReply.rawValue))
        XCTAssertFalse(presentation.receipt.includedSources.contains(AttacheContextItemSource.currentUserTurn.rawValue))
    }

    func testFinalCLINoToolsRoundRemovesOnlyTheToolAdvertisement() throws {
        let definitions = try AttacheProductionRequestBroker.conversationToolDefinitions(
            allowSessionContextTools: false,
            allowAgentInstructionTool: false,
            allowMemoryProposalTool: true
        )
        let bridge = try XCTUnwrap(
            AttacheProductionRequestBroker.cliToolBridgeMessage(toolDefinitionsJSON: definitions)
        )
        let call = AttacheChatToolCall(id: "call-final", name: "propose_memory", arguments: "{}")
        let messages = [
            bridge,
            AttacheChatMessage(role: "assistant", content: "", toolCalls: [call]),
            AttacheChatMessage(role: "tool", content: "queued", toolCallID: call.id)
        ]

        let final = AttacheProductionRequestBroker.removingCLIToolBridge(
            from: messages,
            toolDefinitionsJSON: definitions
        )

        XCTAssertFalse(final.contains(bridge))
        XCTAssertEqual(final.count, 2)
        XCTAssertEqual(final[0].toolCalls, [call])
        XCTAssertEqual(final[1].toolCallID, call.id)
    }

    func testRemoteEgressIsBlockedUntilExactEndpointConsentExists() async throws {
        let suite = "AttacheProductionRequestBrokerTests.consent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AttachePreferenceKey.presentationLLMEnabled)
        defaults.set(AttachePresentationProvider.custom.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        defaults.set("https://consent.example/v1", forKey: AttachePreferenceKey.presentationLLMBaseURL)
        defaults.set("test-key", forKey: AttachePreferenceKey.presentationLLMAPIKey)
        defaults.set("test-model", forKey: AttachePreferenceKey.presentationLLMModel)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrokerStubURLProtocol.self]
        let broker = AttacheProductionRequestBroker(urlSession: URLSession(configuration: configuration))
        let service = AttachePresentationService(
            defaults: defaults,
            environment: [:],
            requestBroker: broker
        )
        BrokerStubURLProtocol.responseBody = Data(
            #"{"choices":[{"message":{"content":"Allowed."}}]}"#.utf8
        )
        BrokerStubURLProtocol.failure = nil
        let frozenSettings = AttachePresentationSettings.load(
            role: .conversation,
            defaults: defaults,
            environment: [:]
        )
        BrokerStubURLProtocol.requestCount = 0
        BrokerStubURLProtocol.lastBody = nil

        let denied = try await service.complete(
            snapshot: makeSnapshot(modelSettings: frozenSettings),
            system: "Stay concise.",
            user: "question"
        )
        XCTAssertNil(denied.text)
        XCTAssertTrue(denied.inference.receiptView.noModelContext)
        XCTAssertEqual(BrokerStubURLProtocol.requestCount, 0)
        XCTAssertNil(BrokerStubURLProtocol.lastBody)

        let scope = PresentationConsentScope(
            provider: .custom,
            endpoint: "https://consent.example/v1"
        )
        defaults.set(
            [scope.storageKey],
            forKey: AttachePreferenceKey.cloudConsentPresentationProviders
        )
        let allowed = try await service.complete(
            snapshot: makeSnapshot(modelSettings: frozenSettings),
            system: "Stay concise.",
            user: "question"
        )
        XCTAssertEqual(allowed.text, "Allowed.")
        XCTAssertFalse(allowed.inference.receiptView.noModelContext)
        XCTAssertEqual(BrokerStubURLProtocol.requestCount, 1)
        XCTAssertNotNil(BrokerStubURLProtocol.lastBody)
    }

    func testEveryRoleAndFallbackOverrideUseTheSameConsentGate() async throws {
        let suite = "AttacheProductionRequestBrokerTests.role-consent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AttachePreferenceKey.presentationLLMEnabled)
        defaults.set(AttachePresentationProvider.custom.rawValue, forKey: AttachePreferenceKey.presentationLLMProvider)
        defaults.set("https://primary.example/v1", forKey: AttachePreferenceKey.presentationLLMBaseURL)
        defaults.set("test-key", forKey: AttachePreferenceKey.presentationLLMAPIKey)
        defaults.set("test-model", forKey: AttachePreferenceKey.presentationLLMModel)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrokerStubURLProtocol.self]
        let service = AttachePresentationService(
            defaults: defaults,
            environment: [:],
            requestBroker: AttacheProductionRequestBroker(
                urlSession: URLSession(configuration: configuration)
            )
        )
        let primarySettings = AttachePresentationSettings.load(
            role: .conversation,
            defaults: defaults,
            environment: [:]
        )
        BrokerStubURLProtocol.failure = nil
        BrokerStubURLProtocol.requestCount = 0
        for role in AttacheRequestRole.allCases {
            let result = try await service.complete(
                snapshot: makeSnapshot(role: role, modelSettings: primarySettings),
                system: "System",
                user: "question"
            )
            XCTAssertTrue(result.inference.receiptView.noModelContext, "\(role) must fail closed")
        }
        XCTAssertEqual(BrokerStubURLProtocol.requestCount, 0)

        let primaryScope = PresentationConsentScope(
            provider: .custom,
            endpoint: "https://primary.example/v1"
        )
        defaults.set(
            [primaryScope.storageKey],
            forKey: AttachePreferenceKey.cloudConsentPresentationProviders
        )
        let unconsentedFallback = AttachePresentationSettings(
            llmEnabled: true,
            provider: .custom,
            baseURL: URL(string: "https://fallback.example/v1")!,
            apiKey: "test-key",
            apiKeySecretRef: "",
            model: "fallback-model",
            reasoningEffort: nil,
            serviceTier: nil,
            profilePrompt: ""
        )
        let fallback = try await service.complete(
            snapshot: makeSnapshot(role: .conversation, modelSettings: primarySettings),
            system: "System",
            user: "question",
            settingsOverride: unconsentedFallback
        )
        XCTAssertTrue(fallback.inference.receiptView.noModelContext)
        XCTAssertEqual(BrokerStubURLProtocol.requestCount, 0)
    }

    func testNoModelMetadataIsTruthfulAndContentFree() {
        let metadata = AttacheInferenceMetadata.noModel(snapshot: makeSnapshot())
        XCTAssertNil(metadata.contextReceipt)
        XCTAssertNil(metadata.modelIdentity)
        XCTAssertFalse(metadata.usage.isPresent)
        XCTAssertTrue(metadata.receiptView.noModelContext)
        XCTAssertTrue(metadata.receiptView.attempts.isEmpty)
    }

    func testInferenceTaintsOutputOnlyWhenLocalOnlyEvidenceWasIncluded() throws {
        let localOnly = AttacheContextItem(
            source: .durableMemory,
            content: "Private local fact",
            provenance: "memory:private-1",
            egress: .localOnly,
            priority: 500,
            treatment: .headTailExcerpt
        )
        let snapshot = makeSnapshot(contextItems: [localOnly])
        let broker = AttacheProductionRequestBroker()
        let localAttempt = try makeAttempt(capacity: 32_000, tools: false)
        let messages = [
            AttacheChatMessage(role: "system", content: "Stay concise."),
            AttacheChatMessage(role: "user", content: "question")
        ]
        let localCompiled = try broker.compile(
            snapshot: snapshot,
            attempt: localAttempt,
            messages: messages
        )
        let localMetadata = AttacheInferenceMetadata.model(
            snapshot: snapshot,
            compiled: localCompiled,
            usage: AttacheParsedTokenUsage(
                inputTokens: nil,
                outputTokens: nil,
                cachedTokens: nil,
                totalTokens: nil
            ),
            attempt: localAttempt
        )
        XCTAssertTrue(localMetadata.containsLocalOnlyContext)

        let remoteAttempt = try makeAttempt(
            capacity: 32_000,
            tools: false,
            provider: .custom,
            baseURL: URL(string: "https://remote.example/v1")!
        )
        let remoteCompiled = try broker.compile(
            snapshot: snapshot,
            attempt: remoteAttempt,
            messages: messages
        )
        let remoteMetadata = AttacheInferenceMetadata.model(
            snapshot: snapshot,
            compiled: remoteCompiled,
            usage: localMetadata.usage,
            attempt: remoteAttempt
        )
        XCTAssertFalse(remoteMetadata.containsLocalOnlyContext)
    }

    func testExactLocalOnlyDirectTurnTaintsDerivedToolRoundAndRemoteFallbackOmitsIt() throws {
        let privateTurn = AttacheChatMessage(
            role: "assistant",
            content: "LOCAL_DIRECT_SECRET"
        )
        let privateSource = AttachePrebuiltMessageSource(
            message: privateTurn,
            source: .recentDirectChatTurns,
            egress: .localOnly
        )
        let snapshot = makeSnapshot(
            contextItems: [],
            directChatMessages: [privateTurn],
            directChatMessageSources: [privateSource]
        )
        XCTAssertTrue(snapshot.contextItems.isEmpty, "short-call fixture has no summary capsule")
        let baseMessages = [
            AttacheChatMessage(role: "system", content: "Stay concise."),
            privateTurn,
            AttacheChatMessage(role: "user", content: "continue")
        ]
        let broker = AttacheProductionRequestBroker()
        let localAttempt = try makeAttempt(capacity: 32_000, tools: false)
        let localCompiled = try broker.compile(
            snapshot: snapshot,
            attempt: localAttempt,
            messages: baseMessages
        )
        let localMetadata = AttacheInferenceMetadata.model(
            snapshot: snapshot,
            compiled: localCompiled,
            usage: AttacheParsedTokenUsage(
                inputTokens: nil,
                outputTokens: nil,
                cachedTokens: nil,
                totalTokens: nil
            ),
            attempt: localAttempt
        )
        XCTAssertTrue(localMetadata.containsLocalOnlyContext)

        let toolCall = AttacheChatMessage(
            role: "assistant",
            content: "LOCAL_TOOL_ARGUMENT_SECRET",
            toolCalls: [AttacheChatToolCall(
                id: "local-tool",
                name: "propose_memory",
                arguments: #"{"statement":"LOCAL_TOOL_ARGUMENT_SECRET"}"#
            )]
        )
        let toolResult = AttacheChatMessage(
            role: "tool",
            content: "LOCAL_TOOL_RESULT_SECRET",
            toolCallID: "local-tool"
        )
        var sources = AttacheProductionRequestBroker.prebuiltMessageSources(
            snapshot: snapshot,
            messages: baseMessages
        )
        sources.append(AttachePresentationService.causallyDerivedSource(
            message: toolCall,
            source: .recentDirectChatTurns,
            inference: localMetadata
        ))
        sources.append(AttachePresentationService.causallyDerivedSource(
            message: toolResult,
            source: .toolResults,
            inference: localMetadata
        ))
        XCTAssertEqual(sources.suffix(2).map(\.egress), [.localOnly, .localOnly])

        let remoteAttempt = try makeAttempt(
            capacity: 32_000,
            tools: false,
            provider: .custom,
            baseURL: URL(string: "https://remote.example/v1")!
        )
        let remoteCompiled = try broker.compile(
            snapshot: snapshot,
            attempt: remoteAttempt,
            messages: baseMessages + [toolCall, toolResult],
            messageSources: sources
        )
        let outbound = String(decoding: remoteCompiled.serializedOutboundRequest, as: UTF8.self)
        for marker in [
            "LOCAL_DIRECT_SECRET",
            "LOCAL_TOOL_ARGUMENT_SECRET",
            "LOCAL_TOOL_RESULT_SECRET"
        ] {
            XCTAssertFalse(outbound.contains(marker), "remote fallback leaked \(marker)")
        }
        let effects = ConversationTurnEffectLedger()
        XCTAssertTrue(effects.claim(.memoryProposal))
        XCTAssertFalse(effects.claim(.memoryProposal), "the same effect runs only once across fallback")
    }

    func testMemoryProposalSchemaRequiresBoundScopeValue() throws {
        let data = try AttacheProductionRequestBroker.conversationToolDefinitions(
            allowSessionContextTools: false,
            allowAgentInstructionTool: false,
            allowMemoryProposalTool: true
        )
        let tools = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let function = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "propose_memory")
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        let required = try XCTUnwrap(parameters["required"] as? [String])
        XCTAssertTrue(required.contains("scope_value"))
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        let scopeValue = try XCTUnwrap(properties["scope_value"] as? [String: Any])
        XCTAssertEqual(scopeValue["minLength"] as? Int, 1)
    }

    func testSessionReadSchemasExposeBoundedContinuationLocators() throws {
        let data = try AttacheProductionRequestBroker.conversationToolDefinitions(
            allowSessionContextTools: true,
            allowAgentInstructionTool: false,
            allowMemoryProposalTool: false
        )
        let tools = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        func properties(_ name: String) throws -> [String: Any] {
            let tool = try XCTUnwrap(tools.first {
                (($0["function"] as? [String: Any])?["name"] as? String) == name
            })
            let function = try XCTUnwrap(tool["function"] as? [String: Any])
            let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
            return try XCTUnwrap(parameters["properties"] as? [String: Any])
        }

        let transcriptRead = try properties("read_session_transcript")
        for key in ["start_turn", "start_char", "max_chars", "content_hash"] {
            XCTAssertNotNil(transcriptRead[key], "missing transcript continuation field \(key)")
        }
        let fileRead = try properties("read_file")
        for key in ["path", "line_start", "max_lines", "content_hash"] {
            XCTAssertNotNil(fileRead[key], "missing file continuation field \(key)")
        }
        XCTAssertNotNil(try properties("search_session_transcript")["max_results"])
        XCTAssertNotNil(try properties("list_working_directory")["max_results"])
    }

    func testStaticInventoryForbidsRawMessageEgressOutsideBroker() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let service = try String(contentsOf: root.appendingPathComponent(
            "Sources/AttacheApp/AttachePresentationService.swift"
        ))
        for forbidden in ["URLSession", "URLRequest", "CLILanguageModel", "requestChatCompletion", "func requestChat("] {
            XCTAssertFalse(service.contains(forbidden), "raw egress primitive escaped into service: \(forbidden)")
        }

        let broker = try String(contentsOf: root.appendingPathComponent(
            "Sources/AttacheApp/AttacheProductionRequestBroker.swift"
        ))
        XCTAssertTrue(broker.contains("private func transport(\n        compiled: CompiledModelRequest"))
        XCTAssertFalse(broker.contains("private func transport(\n        messages:"))
        XCTAssertTrue(broker.contains("request.httpBody = compiled.serializedOutboundRequest"))

        let cliTransport = try String(contentsOf: root.appendingPathComponent(
            "Sources/AttacheApp/CLILanguageModel.swift"
        ))
        XCTAssertFalse(
            cliTransport.contains("func complete(messages:"),
            "CLI transport must accept only the exact compiled prompt bytes"
        )
    }

    func testProductionCopyContainsNoEmDashOutsideSpokenSanitizer() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        )
        for case let file as URL in enumerator {
            guard ["swift", "strings"].contains(file.pathExtension) else { continue }
            var content = try String(contentsOf: file, encoding: .utf8)
            if file.lastPathComponent == "AttachePersonality.swift" {
                content = content.replacingOccurrences(
                    of: "for dash in [\"—\", \"–\", \"―\"] {",
                    with: "for dash in [\"–\", \"―\"] {"
                )
            }
            XCTAssertFalse(
                content.contains("—"),
                "production source contains an em dash: \(file.path)"
            )
        }
    }

    private func makeSnapshot(
        role: AttacheRequestRole = .conversation,
        modelSettings: AttachePresentationSettings? = nil,
        contextItems: [AttacheContextItem]? = nil,
        memorySelectionReceipt: [AttacheMemoryReceiptEntry] = [],
        userInput: String = "question",
        directChatMessages: [AttacheChatMessage] = [],
        directChatMessageSources: [AttachePrebuiltMessageSource] = []
    ) -> AttacheRequestSnapshot {
        AttacheRequestSnapshot(
            requestID: "request-338",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            role: role,
            personality: Personality(id: "test", name: "Test", prompt: "Stay concise."),
            profilePrompt: "Stay concise.",
            userInput: userInput,
            session: .contextFree,
            modelSettings: modelSettings,
            contextItems: contextItems ?? [AttacheContextItem(
                source: .durableMemory,
                content: "The user prefers concise answers.",
                provenance: "test-ledger",
                priority: 500,
                treatment: .headTailExcerpt
            )],
            contextStrategy: .automatic,
            memorySelectionReceipt: memorySelectionReceipt,
            directChatMessages: directChatMessages,
            directChatMessageSources: directChatMessageSources
        )
    }

    private func makeAttempt(
        capacity: Int?,
        tools: Bool,
        provider: AttachePresentationProvider = .ollama,
        baseURL: URL = URL(string: "http://127.0.0.1:11434/v1")!,
        role: AttacheRequestRole = .conversation,
        strategy: AttacheContextStrategy = .automatic
    ) throws -> AttacheFrozenModelAttempt {
        let definitions = tools ? try AttacheProductionRequestBroker.conversationToolDefinitions(
            allowSessionContextTools: false,
            allowAgentInstructionTool: false,
            allowMemoryProposalTool: true
        ) : Data()
        let profile: AttacheModelCapabilityProfile = capacity.map {
            AttacheModelCapabilityProfile(
                architecturalMaximum: $0,
                outputLimit: min(4_096, $0 / 4),
                confidence: .authoritative,
                provenance: .providerMetadata
            )
        } ?? .unknown
        return AttacheFrozenModelAttempt(
            role: role,
            settings: AttachePresentationSettings(
                llmEnabled: true,
                provider: provider,
                baseURL: baseURL,
                apiKey: provider.requiresAPIKey ? "test-key" : "",
                apiKeySecretRef: "",
                model: "test-model",
                reasoningEffort: "low",
                serviceTier: nil,
                profilePrompt: ""
            ),
            capability: profile,
            strategy: strategy,
            toolDefinitionsJSON: definitions
        )
    }

    private func structuredRoundMessages() -> [AttacheChatMessage] {
        let call = AttacheChatToolCall(
            id: "call-338",
            name: "propose_memory",
            arguments: #"{"statement":"concise","type":"preference","scope":"global","scope_value":"global","sensitivity":"ordinary","egress":"allowed","requires_confirmation":true}"#
        )
        return [
            AttacheChatMessage(role: "system", content: "Stay concise."),
            AttacheChatMessage(role: "assistant", content: "", toolCalls: [call]),
            AttacheChatMessage(role: "tool", content: "proposal queued", toolCallID: call.id),
            AttacheChatMessage(role: "user", content: "question")
        ]
    }
}

private final class BrokerStubURLProtocol: URLProtocol {
    static var responseBody = Data()
    static var statusCode = 200
    static var lastBody: Data?
    static var lastURL: URL?
    static var requestCount = 0
    static var failure: Error?
    static var responseHandler: ((URLRequest, Int) -> Data)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.lastURL = request.url
        Self.lastBody = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseHandler?(request, Self.requestCount) ?? Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private actor BrokerToolGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor BrokerInferenceRecorder {
    private(set) var inference: AttacheInferenceMetadata?

    func record(_ inference: AttacheInferenceMetadata) {
        self.inference = inference
    }
}
