import AttacheCore
import XCTest

/// INF-398: the shared local-model classifier every session scanner routes
/// through. Provider-keyed cases (opencode) and model-id-only cases (Claude
/// Code) are both exercised here so the badge means the same thing everywhere.
final class LocalModelHintTests: XCTestCase {
    // MARK: - Provider-keyed (opencode)

    func testOllamaProviderWithoutCloudSuffixIsLocal() {
        XCTAssertEqual(LocalModelHint.classify(providerID: "ollama", modelID: "glm-5.2"), "glm-5.2")
        XCTAssertEqual(LocalModelHint.classify(providerID: "ollama", modelID: "qwen2.5-coder:32b"), "qwen2.5-coder:32b")
    }

    func testOllamaProviderWithCloudSuffixIsNotLocal() {
        XCTAssertNil(LocalModelHint.classify(providerID: "ollama", modelID: "glm-5.2:cloud"),
                     "a :cloud-suffixed ollama tag is proxied cloud inference, not local")
        XCTAssertNil(LocalModelHint.classify(providerID: "ollama", modelID: "GLM-5.2:CLOUD"),
                     "the :cloud suffix check is case-insensitive")
    }

    func testLmStudioAndLocalhostProvidersAreLocal() {
        XCTAssertEqual(LocalModelHint.classify(providerID: "lmstudio", modelID: "llama3.1"), "llama3.1")
        XCTAssertEqual(LocalModelHint.classify(providerID: "localhost", modelID: "mistral"), "mistral")
        XCTAssertEqual(LocalModelHint.classify(providerID: "my-localhost-proxy", modelID: "phi4"), "phi4",
                       "a host-shaped custom provider id counts as local")
    }

    func testNamedCloudProvidersAreNotLocal() {
        XCTAssertNil(LocalModelHint.classify(providerID: "anthropic", modelID: "claude-sonnet-5"))
        XCTAssertNil(LocalModelHint.classify(providerID: "openai", modelID: "gpt-5"))
        XCTAssertNil(LocalModelHint.classify(providerID: "xai", modelID: "grok-4"))
    }

    func testLocalProviderWithEmptyModelFallsBackToProviderName() {
        XCTAssertEqual(LocalModelHint.classify(providerID: "ollama", modelID: nil), "ollama")
        XCTAssertEqual(LocalModelHint.classify(providerID: "ollama", modelID: ""), "ollama")
    }

    func testUnknownProviderIsNotLocal() {
        XCTAssertNil(LocalModelHint.classify(providerID: "some-saas-provider", modelID: "x"))
    }

    // MARK: - Model-id-only (Claude Code) parity

    func testModelIDOnlyClaudePrefixIsNotLocal() {
        XCTAssertNil(LocalModelHint.classify(providerID: nil, modelID: "claude-sonnet-5"))
        XCTAssertNil(LocalModelHint.classify(providerID: "", modelID: "Claude-Opus-4"))
    }

    func testModelIDOnlyNonClaudeTagIsLocal() {
        XCTAssertEqual(LocalModelHint.classify(providerID: nil, modelID: "qwen2.5-coder:32b"), "qwen2.5-coder:32b")
        XCTAssertEqual(LocalModelHint.classify(providerID: nil, modelID: "glm-4"), "glm-4")
    }

    func testEmptyEvidenceYieldsNil() {
        XCTAssertNil(LocalModelHint.classify(providerID: nil, modelID: nil))
        XCTAssertNil(LocalModelHint.classify(providerID: "", modelID: ""))
        XCTAssertNil(LocalModelHint.classify(providerID: "   ", modelID: "   "))
    }
}
