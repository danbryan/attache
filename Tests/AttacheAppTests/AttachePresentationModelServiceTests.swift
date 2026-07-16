import XCTest
@testable import AttacheApp

final class AttachePresentationModelServiceTests: XCTestCase {
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

    func testGrok45NameAloneDoesNotInventReasoningChoices() {
        let efforts = AttachePresentationModelService.fallbackReasoningEfforts(
            provider: .xai,
            modelID: "grok-4.5"
        )

        XCTAssertEqual(efforts, [])
    }

    func testGrok43NameAloneDoesNotInventReasoningChoices() {
        let efforts = AttachePresentationModelService.fallbackReasoningEfforts(
            provider: .xai,
            modelID: "grok-4.3"
        )

        XCTAssertEqual(efforts, [])
    }

    func testXAICatalogReasoningLevelsAreAuthoritativePerModel() throws {
        let data = Data(#"{"models":[{"id":"grok-4.5","context_window":131072,"max_output_tokens":8192,"supported_reasoning_efforts":["low","high"]},{"id":"grok-4.3","supported_reasoning_efforts":["none","medium"]}]}"#.utf8)

        let options = try AttachePresentationModelService.parseXAILanguageModels(data)

        XCTAssertEqual(options.first { $0.id == "grok-4.5" }?.reasoningEfforts, ["low", "high"])
        XCTAssertEqual(options.first { $0.id == "grok-4.5" }?.capabilityProfile.declaredInputCeiling, 131_072)
        XCTAssertEqual(options.first { $0.id == "grok-4.5" }?.capabilityProfile.outputLimit, 8_192)
        XCTAssertEqual(options.first { $0.id == "grok-4.5" }?.capabilityProfile.provenance, .providerMetadata)
        XCTAssertEqual(options.first { $0.id == "grok-4.3" }?.reasoningEfforts, ["none", "medium"])
        XCTAssertTrue(options.first { $0.id == "grok-4.3" }?.capabilityProfile.isUnknown == true)
    }

    func testXAICatalogDisablesReasoningWhenSchemaDoesNotAdvertiseIt() throws {
        let data = Data(#"{"models":[{"id":"grok-4.5"},{"id":"unknown-future-model"}]}"#.utf8)

        let options = try AttachePresentationModelService.parseXAILanguageModels(data)

        XCTAssertEqual(options.first { $0.id == "grok-4.5" }?.reasoningEfforts, [])
        XCTAssertEqual(options.first { $0.id == "unknown-future-model" }?.reasoningEfforts, [])
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
