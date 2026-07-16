import XCTest
@testable import AttacheApp

final class AttachePresentationModelServiceTests: XCTestCase {
    func testOllamaTagDigestBecomesModelFingerprint() throws {
        let data = Data(#"{"models":[{"name":"qwen:latest","digest":"sha256:abc123","details":{"parameter_size":"7B"}}]}"#.utf8)

        let option = try XCTUnwrap(
            AttachePresentationModelService.parseOllamaTags(data).first
        )

        XCTAssertEqual(option.id, "qwen:latest")
        XCTAssertEqual(option.fingerprint, "sha256:abc123")
    }

    func testModelDiscoveryRedirectPolicyRefusesUnclassifiedDestination() {
        var redirected = URLRequest(url: URL(string: "https://unclassified.example/v1/models")!)
        redirected.setValue("Bearer MODEL_DISCOVERY_SECRET", forHTTPHeaderField: "Authorization")

        XCTAssertNil(AttacheNoRedirectDelegate.redirectedRequest(redirected))
    }

    func testUnknownCodexModelKeepsReasoningChoices() {
        let efforts = AttachePresentationModelService.fallbackReasoningEfforts(
            provider: .codexCLI,
            modelID: "gpt-5.6-luna"
        )

        XCTAssertTrue(efforts.contains("low"))
        XCTAssertFalse(efforts.contains("none"))
    }

    func testGrok45FallbackUsesVerifiedReasoningChoices() {
        let efforts = AttachePresentationModelService.fallbackReasoningEfforts(
            provider: .xai,
            modelID: "grok-4.5"
        )

        XCTAssertEqual(efforts, ["low", "medium", "high"])
    }

    func testGrok43FallbackUsesVerifiedReasoningChoices() {
        let efforts = AttachePresentationModelService.fallbackReasoningEfforts(
            provider: .xai,
            modelID: "grok-4.3"
        )

        XCTAssertEqual(efforts, ["none", "low", "medium", "high"])
    }

    func testKnownXAIProfileRepairsAnOldUnknownCacheEntryWithoutRefresh() {
        let profile = AttachePresentationModelService.capabilityProfile(
            provider: .xai,
            baseURLText: "https://attache-test.invalid/v1",
            modelID: "grok-4.5"
        )

        XCTAssertEqual(profile.declaredInputCeiling, 500_000)
        XCTAssertEqual(profile.reasoningLevels, ["low", "medium", "high"])
        XCTAssertEqual(profile.provenance, .curatedFallback)
    }

    func testXAICatalogFieldsOverrideVerifiedCatalogPerModel() throws {
        let data = Data(#"{"models":[{"id":"grok-4.5","context_window":131072,"max_output_tokens":8192,"supported_reasoning_efforts":["low","high"]},{"id":"grok-4.3","supported_reasoning_efforts":["none","medium"]}]}"#.utf8)

        let options = try AttachePresentationModelService.parseXAILanguageModels(data)

        XCTAssertEqual(options.first { $0.id == "grok-4.5" }?.reasoningEfforts, ["low", "high"])
        XCTAssertEqual(options.first { $0.id == "grok-4.5" }?.capabilityProfile.declaredInputCeiling, 131_072)
        XCTAssertEqual(options.first { $0.id == "grok-4.5" }?.capabilityProfile.outputLimit, 8_192)
        XCTAssertEqual(options.first { $0.id == "grok-4.5" }?.capabilityProfile.provenance, .providerMetadata)
        XCTAssertEqual(options.first { $0.id == "grok-4.3" }?.reasoningEfforts, ["none", "medium"])
        XCTAssertEqual(options.first { $0.id == "grok-4.3" }?.capabilityProfile.declaredInputCeiling, 1_000_000)
        XCTAssertEqual(options.first { $0.id == "grok-4.3" }?.capabilityProfile.provenance, .curatedFallback)
    }

    func testXAIUsesVerifiedCatalogWhenLiveSchemaOmitsCapabilityFields() throws {
        let data = Data(#"{"models":[{"id":"grok-4.5"},{"id":"unknown-future-model"}]}"#.utf8)

        let options = try AttachePresentationModelService.parseXAILanguageModels(data)

        XCTAssertEqual(options.first { $0.id == "grok-4.5" }?.reasoningEfforts, ["low", "medium", "high"])
        XCTAssertEqual(options.first { $0.id == "grok-4.5" }?.capabilityProfile.declaredInputCeiling, 500_000)
        XCTAssertEqual(options.first { $0.id == "grok-4.5" }?.capabilityProfile.provenance, .curatedFallback)
        XCTAssertEqual(options.first { $0.id == "unknown-future-model" }?.reasoningEfforts, [])
        XCTAssertTrue(options.first { $0.id == "unknown-future-model" }?.capabilityProfile.isUnknown == true)
    }

    func testXAICatalogHidesResponsesOnlyMultiAgentModels() throws {
        let data = Data(#"{"models":[{"id":"grok-4.20-multi-agent"},{"id":"grok-4.5"}]}"#.utf8)

        let options = try AttachePresentationModelService.parseXAILanguageModels(data)

        XCTAssertEqual(options.map(\.id), ["grok-4.5"])
    }

    func testOllamaGPTOSSExposesDocumentedEffortLevels() throws {
        let data = Data(#"{"capabilities":["completion","thinking"],"details":{"family":"gptoss"}}"#.utf8)
        let efforts = try AttachePresentationModelService.parseOllamaShowReasoningEfforts(
            data,
            modelID: "gpt-oss:20b"
        )

        XCTAssertEqual(efforts, ["low", "medium", "high"])
    }

    func testOllamaThinkingModelExposesCompatibleReasoningLevels() throws {
        let data = Data(#"{"capabilities":["completion","thinking"],"details":{"family":"qwen3"}}"#.utf8)
        let efforts = try AttachePresentationModelService.parseOllamaShowReasoningEfforts(
            data,
            modelID: "qwen3:8b"
        )

        XCTAssertEqual(efforts, ["none", "low", "medium", "high"])
    }

    func testOllamaNonThinkingModelDisablesReasoning() throws {
        let data = Data(#"{"capabilities":["completion"],"details":{"family":"llama"}}"#.utf8)
        let efforts = try AttachePresentationModelService.parseOllamaShowReasoningEfforts(
            data,
            modelID: "llama3.2:3b"
        )

        XCTAssertEqual(efforts, [])
    }
}
