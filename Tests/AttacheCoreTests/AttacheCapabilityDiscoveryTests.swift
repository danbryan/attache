import AttacheCore
import XCTest

final class AttacheCapabilityDiscoveryTests: XCTestCase {

    // MARK: - Codex cache (acceptance: Codex fixture, missing fields)

    func testCodexCacheParsesContextReasoningAndOutput() {
        let json: [String: Any] = [
            "context_window": 200_000,
            "max_output_tokens": 64_000,
            "reasoning_levels": ["low", "medium", "high"],
            "fingerprint": "sha:abc",
            "fetched_at": 1_700_000_000
        ]
        let profile = AttacheCapabilityParser.parseCodexCache(json)
        XCTAssertEqual(profile?.architecturalMaximum, 200_000)
        XCTAssertEqual(profile?.outputLimit, 64_000)
        XCTAssertEqual(profile?.reasoningLevels, ["low", "medium", "high"])
        XCTAssertTrue(profile?.supportsReasoning ?? false)
        XCTAssertEqual(profile?.provenance, .localCache)
        XCTAssertNotNil(profile?.freshness)
    }

    func testCodexCacheMissingFieldsAreUnknown() {
        let profile = AttacheCapabilityParser.parseCodexCache([:])
        XCTAssertNil(profile?.architecturalMaximum)
        XCTAssertNil(profile?.outputLimit)
        XCTAssertEqual(profile?.confidence, .unknown)
    }

    // MARK: - Ollama show/ps (acceptance: arch vs configured vs loaded)

    func testOllamaDistinguishesArchitecturalFromConfigured() {
        let show: [String: Any] = [
            "name": "qwen3:7b",
            "parameters": "num_ctx 8192\nnum_batch 512",
            "model_info": ["llama.context_length": 131_072, "llama.attention.head_count": 32],
            "details": ["family": "qwen", "parameter_size": "7B"]
        ]
        let ps: [String: Any] = ["models": [["name": "qwen3:7b"]]]
        let profile = AttacheCapabilityParser.parseOllama(show: show, ps: ps)
        XCTAssertEqual(profile?.architecturalMaximum, 131_072, "architectural maximum from model_info")
        XCTAssertEqual(profile?.configuredRuntimeLimit, 8_192, "configured num_ctx from parameters")
        XCTAssertNotEqual(profile?.architecturalMaximum, profile?.configuredRuntimeLimit)
        XCTAssertEqual(profile?.declaredInputCeiling, 8_192, "effective is the conservative min")
        XCTAssertEqual(profile?.estimatorFamily, "ollama-qwen")
    }

    func testOllamaReasoningIsUnknownNotFabricated() {
        let show: [String: Any] = ["model_info": ["llama.context_length": 32768]]
        let profile = AttacheCapabilityParser.parseOllama(show: show)
        XCTAssertFalse(profile?.supportsReasoning ?? true, "Ollama reasoning must not be fabricated from a model name.")
        XCTAssertEqual(profile?.reasoningLevels, [])
    }

    func testOllamaLoadedDetectedFromPs() {
        let show: [String: Any] = ["name": "llama3:8b", "parameters": "num_ctx 4096", "model_info": ["llama.context_length": 8192]]
        let loaded = AttacheCapabilityParser.parseOllama(show: show, ps: ["models": [["name": "llama3:8b"]]])
        let notLoaded = AttacheCapabilityParser.parseOllama(show: show, ps: ["models": [["name": "other"]]])
        // Both produce a configured limit from show; ps only confirms loaded status.
        XCTAssertEqual(loaded?.configuredRuntimeLimit, 4_096)
        XCTAssertEqual(notLoaded?.configuredRuntimeLimit, 4_096)
    }

    // MARK: - Hosted model lists (acceptance: hosted, unknown when not published)

    func testHostedModelParsesContextAndReasoning() {
        let json: [String: Any] = [
            "id": "grok-4",
            "context_window": 256_000,
            "max_output_tokens": 32_000,
            "supported_reasoning_efforts": ["default", "low", "high"]
        ]
        let profile = AttacheCapabilityParser.parseHostedModel(json)
        XCTAssertEqual(profile?.architecturalMaximum, 256_000)
        XCTAssertEqual(profile?.reasoningLevels, ["default", "low", "high"])
        XCTAssertEqual(profile?.provenance, .providerMetadata)
    }

    func testHostedModelUnknownWhenLimitsNotPublished() {
        let profile = AttacheCapabilityParser.parseHostedModel(["id": "some-model"])
        XCTAssertNil(profile?.architecturalMaximum)
        XCTAssertFalse(profile?.supportsReasoning ?? true)
        XCTAssertEqual(profile?.confidence, .unknown)
    }

    // MARK: - Malformed values rejected (acceptance: reject malformed/zero/negative/implausible)

    func testZeroContextWindowRejected() {
        XCTAssertNil(AttacheCapabilityParser.sanitizeContextWindow(0))
    }

    func testNegativeContextWindowRejected() {
        XCTAssertNil(AttacheCapabilityParser.sanitizeContextWindow(-8192))
    }

    func testImplausibleContextWindowRejected() {
        XCTAssertNil(AttacheCapabilityParser.sanitizeContextWindow(1_000_000_000))
    }

    func testValidContextWindowAccepted() {
        XCTAssertEqual(AttacheCapabilityParser.sanitizeContextWindow(131_072), 131_072)
    }

    func testOllamaMalformedNumCtxDropped() {
        let show: [String: Any] = [
            "parameters": "num_ctx notanumber\nnum_batch 512",
            "model_info": ["llama.context_length": 32768]
        ]
        let profile = AttacheCapabilityParser.parseOllama(show: show)
        XCTAssertNil(profile?.configuredRuntimeLimit, "malformed num_ctx must not be trusted")
        XCTAssertEqual(profile?.architecturalMaximum, 32768)
    }

    func testHostedOutOfRangeFloatingPointLimitsAreDroppedWithoutTrapping() {
        let profile = AttacheCapabilityParser.parseHostedModel([
            "context_window": Double.greatestFiniteMagnitude,
            "max_output_tokens": Double.infinity
        ])

        XCTAssertNil(profile?.architecturalMaximum)
        XCTAssertNil(profile?.outputLimit)
    }

    func testOllamaOutOfRangeFloatingPointLimitsAreDroppedWithoutTrapping() {
        let profile = AttacheCapabilityParser.parseOllama(show: [
            "num_ctx": Double.greatestFiniteMagnitude,
            "model_info": ["llama.context_length": Double.greatestFiniteMagnitude]
        ])

        XCTAssertNil(profile?.architecturalMaximum)
        XCTAssertNil(profile?.configuredRuntimeLimit)
    }

    // MARK: - Cache isolation by endpoint and fingerprint (acceptance: no accidental sharing, alias changes)

    func testTwoEndpointsSameModelDoNotShareCache() {
        let cache = AttacheCapabilityCache()
        let upstream = ModelIdentity(provider: "openai", normalizedEndpoint: "https://api.openai.com", requestedModel: "gpt-4o")
        let mirror = ModelIdentity(provider: "openai", normalizedEndpoint: "https://mirror.example.com", requestedModel: "gpt-4o")
        cache.record(identity: upstream, profile: AttacheModelCapabilityProfile(architecturalMaximum: 128_000, provenance: .providerMetadata))
        cache.record(identity: mirror, profile: AttacheModelCapabilityProfile(architecturalMaximum: 8_000, provenance: .providerMetadata))
        XCTAssertEqual(cache.profile(for: upstream)?.architecturalMaximum, 128_000)
        XCTAssertEqual(cache.profile(for: mirror)?.architecturalMaximum, 8_000)
    }

    func testFingerprintChangeDoesNotRetainStaleCapability() {
        let cache = AttacheCapabilityCache()
        let v1 = ModelIdentity(provider: "ollama", normalizedEndpoint: "http://localhost:11434", requestedModel: "qwen", resolvedModel: "qwen2.5", fingerprint: "sha:aaa")
        let v2 = ModelIdentity(provider: "ollama", normalizedEndpoint: "http://localhost:11434", requestedModel: "qwen", resolvedModel: "qwen2.5", fingerprint: "sha:bbb")
        cache.record(identity: v1, profile: AttacheModelCapabilityProfile(architecturalMaximum: 32_000, provenance: .providerMetadata))
        // A re-versioned model is a different key; it does not inherit the prior capability.
        XCTAssertNil(cache.profile(for: v2))
        cache.record(identity: v2, profile: AttacheModelCapabilityProfile(architecturalMaximum: 64_000, provenance: .providerMetadata))
        XCTAssertEqual(cache.profile(for: v2)?.architecturalMaximum, 64_000)
        XCTAssertEqual(cache.profile(for: v1)?.architecturalMaximum, 32_000, "the old lineage is untouched")
    }

    func testSelectionResolvesNewestExactFingerprintedIdentity() throws {
        let cache = AttacheCapabilityCache()
        let selection = ModelIdentity(
            provider: "ollama",
            normalizedEndpoint: "http://localhost:11434",
            requestedModel: "qwen"
        )
        let old = ModelIdentity(
            provider: "ollama",
            normalizedEndpoint: "http://localhost:11434",
            requestedModel: "qwen",
            fingerprint: "sha:old"
        )
        let current = ModelIdentity(
            provider: "ollama",
            normalizedEndpoint: "http://localhost:11434",
            requestedModel: "qwen",
            fingerprint: "sha:current"
        )
        cache.record(
            identity: old,
            profile: AttacheModelCapabilityProfile(
                architecturalMaximum: 32_000,
                provenance: .providerMetadata
            ),
            now: Date(timeIntervalSince1970: 1_000)
        )
        cache.record(
            identity: selection,
            profile: AttacheModelCapabilityProfile(
                architecturalMaximum: 48_000,
                provenance: .localCache
            ),
            now: Date(timeIntervalSince1970: 1_500)
        )
        cache.record(
            identity: current,
            profile: AttacheModelCapabilityProfile(
                architecturalMaximum: 64_000,
                provenance: .providerMetadata
            ),
            now: Date(timeIntervalSince1970: 2_000)
        )

        let resolved = try XCTUnwrap(cache.resolvedRecord(for: selection))
        XCTAssertEqual(resolved.identity, current)
        XCTAssertEqual(resolved.record.profile.architecturalMaximum, 64_000)
    }

    func testInvalidateRemovesOneEntry() {
        let cache = AttacheCapabilityCache()
        let identity = ModelIdentity(provider: "xai", normalizedEndpoint: "https://api.x.ai", requestedModel: "grok")
        cache.record(identity: identity, profile: AttacheModelCapabilityProfile(architecturalMaximum: 128_000, provenance: .providerMetadata))
        XCTAssertNotNil(cache.profile(for: identity))
        cache.invalidate(for: identity)
        XCTAssertNil(cache.profile(for: identity))
    }

    // MARK: - Offline / staleness (acceptance: stale or unknown without blocking)

    func testStaleRecordIsVisibleAndMarkedStale() {
        let cache = AttacheCapabilityCache()
        let identity = ModelIdentity(provider: "groq", normalizedEndpoint: "https://api.groq.com", requestedModel: "llama")
        let old = Date(timeIntervalSince1970: 1_000)
        cache.record(
            identity: identity,
            profile: AttacheModelCapabilityProfile(architecturalMaximum: 128_000, provenance: .providerMetadata),
            now: old
        )
        // Offline: the last known record is still returned.
        XCTAssertEqual(cache.profile(for: identity)?.architecturalMaximum, 128_000)
        let now = Date(timeIntervalSince1970: 1_000 + 10_000)
        XCTAssertFalse(cache.hasFresh(identity: identity, maxAge: 3_600, now: now))
    }

    func testFreshRecordIsNotStale() {
        let cache = AttacheCapabilityCache()
        let identity = ModelIdentity(provider: "groq", normalizedEndpoint: "https://api.groq.com", requestedModel: "llama")
        cache.record(identity: identity, profile: AttacheModelCapabilityProfile(architecturalMaximum: 128_000, provenance: .providerMetadata))
        XCTAssertTrue(cache.hasFresh(identity: identity, maxAge: 3_600))
    }

    // MARK: - No inference / no content (acceptance: no inference call, no credential content)

    func testParsersArePureAndContentFree() {
        // Parsers operate on already-fetched metadata and never incur inference.
        // The returned profile carries only capability fields, never credentials.
        let codex = AttacheCapabilityParser.parseCodexCache(["context_window": 128_000])
        let ollama = AttacheCapabilityParser.parseOllama(show: ["model_info": ["llama.context_length": 8192]])
        let hosted = AttacheCapabilityParser.parseHostedModel(["context_window": 200_000])
        XCTAssertNotNil(codex?.architecturalMaximum)
        XCTAssertNotNil(ollama?.architecturalMaximum)
        XCTAssertNotNil(hosted?.architecturalMaximum)
    }

    func testParserVersionIsRecorded() {
        let cache = AttacheCapabilityCache()
        let identity = ModelIdentity(provider: "xai", normalizedEndpoint: "https://api.x.ai", requestedModel: "grok")
        cache.record(identity: identity, profile: AttacheModelCapabilityProfile(architecturalMaximum: 128_000, provenance: .providerMetadata))
        XCTAssertEqual(cache.record(for: identity)?.parserVersion, AttacheCapabilityParser.parserVersion)
    }
}
