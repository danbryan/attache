import AttacheCore
import XCTest

final class AttacheDataEgressTests: XCTestCase {

    // MARK: - CLI paths (acceptance 1)

    func testCodexAndClaudeCLIAreSubscriptionRemote() {
        XCTAssertEqual(AttacheDataEgressClassifier.classify(providerRawValue: "codex_cli", endpoint: "", isCLI: true, enabled: true), .subscriptionRemoteCLI)
        XCTAssertEqual(AttacheDataEgressClassifier.classify(providerRawValue: "claude_cli", endpoint: "", isCLI: true, enabled: true), .subscriptionRemoteCLI)
        XCTAssertTrue(AttacheDataEgressClassifier.classify(providerRawValue: "codex_cli", endpoint: "", isCLI: true, enabled: true).isRemote,
                      "CLI must be visibly remote/subscription-backed before its first context-bearing request.")
    }

    // MARK: - Ollama by endpoint (acceptance 2)

    func testOllamaLoopbackIsLocal() {
        let egress = AttacheDataEgressClassifier.classify(providerRawValue: "ollama", endpoint: "http://127.0.0.1:11434/v1", isCLI: false, enabled: true)
        XCTAssertEqual(egress, .loopback)
        XCTAssertFalse(egress.isRemote)
    }

    func testOllamaLANIsLocalNetwork() {
        let egress = AttacheDataEgressClassifier.classify(providerRawValue: "ollama", endpoint: "http://192.168.1.50:11434", isCLI: false, enabled: true)
        XCTAssertEqual(egress, .localNetwork)
        XCTAssertTrue(egress.isRemote, "LAN Ollama leaves this Mac and must be disclosed separately from loopback.")
    }

    func testOllamaRemoteIsConfiguredRemote() {
        let egress = AttacheDataEgressClassifier.classify(providerRawValue: "ollama", endpoint: "https://gpu.example.com:11434", isCLI: false, enabled: true)
        XCTAssertEqual(egress, .configuredRemote)
    }

    func testOllamaLoopbackVsLanAreDistinguishable() {
        let local = AttacheDataEgressClassifier.classify(providerRawValue: "ollama", endpoint: "http://127.0.0.1:11434", isCLI: false, enabled: true)
        let lan = AttacheDataEgressClassifier.classify(providerRawValue: "ollama", endpoint: "http://10.0.0.4:11434", isCLI: false, enabled: true)
        XCTAssertNotEqual(local, lan)
    }

    // MARK: - Custom endpoints fail closed (acceptance 3)

    func testCustomRemoteFailsClosedToUnknown() {
        let egress = AttacheDataEgressClassifier.classify(providerRawValue: "custom", endpoint: "https://internal-proxy.example.com/v1", isCLI: false, enabled: true)
        XCTAssertEqual(egress, .unknownCustom, "Custom remote endpoints are unknown until explicitly classified.")
        XCTAssertTrue(egress.isRemote)
    }

    func testCustomLoopbackIsLocal() {
        let egress = AttacheDataEgressClassifier.classify(providerRawValue: "custom", endpoint: "http://localhost:8080/v1", isCLI: false, enabled: true)
        XCTAssertEqual(egress, .loopback)
    }

    func testCustomMalformedFailsClosedToUnknown() {
        let egress = AttacheDataEgressClassifier.classify(providerRawValue: "custom", endpoint: "not a url", isCLI: false, enabled: true)
        XCTAssertEqual(egress, .unknownCustom)
    }

    func testCustomMissingEndpointFailsClosedToUnknown() {
        let egress = AttacheDataEgressClassifier.classify(providerRawValue: "custom", endpoint: nil, isCLI: false, enabled: true)
        XCTAssertEqual(egress, .unknownCustom)
    }

    // MARK: - Hosted APIs (acceptance 4: one classification per provider)

    func testHostedProvidersAreConfiguredRemote() {
        for provider in ["xai", "groq"] {
            let egress = AttacheDataEgressClassifier.classify(providerRawValue: provider, endpoint: "https://api.\(provider).com", isCLI: false, enabled: true)
            XCTAssertEqual(egress, .configuredRemote, "\(provider) should be configuredRemote everywhere.")
        }
    }

    // MARK: - Disabled

    func testDisabledWhenNotEnabled() {
        let egress = AttacheDataEgressClassifier.classify(providerRawValue: "xai", endpoint: "https://api.x.ai", isCLI: false, enabled: false)
        XCTAssertEqual(egress, .disabled)
    }

    // MARK: - Consent transitions (acceptance 5)

    func testReconsentOnLocalToRemote() {
        XCTAssertTrue(AttacheDataEgressClassifier.requiresReconsent(from: .loopback, to: .configuredRemote))
        XCTAssertTrue(AttacheDataEgressClassifier.requiresReconsent(from: .localNetwork, to: .subscriptionRemoteCLI))
    }

    func testReconsentOnRemoteToLocal() {
        XCTAssertTrue(AttacheDataEgressClassifier.requiresReconsent(from: .configuredRemote, to: .loopback))
    }

    func testNoReconsentWithinLocal() {
        XCTAssertFalse(AttacheDataEgressClassifier.requiresReconsent(from: .loopback, to: .localNetwork))
        XCTAssertFalse(AttacheDataEgressClassifier.requiresReconsent(from: .onDevice, to: .loopback))
    }

    func testNoReconsentWithinRemoteSameTrustClass() {
        XCTAssertFalse(AttacheDataEgressClassifier.requiresReconsent(from: .configuredRemote, to: .subscriptionRemoteCLI))
    }

    func testReconsentOnCustomTrustClassChange() {
        XCTAssertTrue(AttacheDataEgressClassifier.requiresReconsent(from: .unknownCustom, to: .configuredRemote))
        XCTAssertTrue(AttacheDataEgressClassifier.requiresReconsent(from: .configuredRemote, to: .unknownCustom))
    }

    func testReconsentOnEnableDisable() {
        XCTAssertTrue(AttacheDataEgressClassifier.requiresReconsent(from: .disabled, to: .configuredRemote))
        XCTAssertTrue(AttacheDataEgressClassifier.requiresReconsent(from: .loopback, to: .disabled))
    }

    func testNoReconsentWhenUnchanged() {
        XCTAssertFalse(AttacheDataEgressClassifier.requiresReconsent(from: .configuredRemote, to: .configuredRemote))
    }

    // MARK: - Endpoint locality matrix (acceptance 7)

    func testIPv4Loopback() {
        XCTAssertEqual(AttacheDataEgressClassifier.endpointLocality("http://127.0.0.1:11434"), .loopback)
        XCTAssertEqual(AttacheDataEgressClassifier.endpointLocality("http://127.255.255.255"), .loopback)
    }

    func testIPv6Loopback() {
        XCTAssertEqual(AttacheDataEgressClassifier.endpointLocality("http://[::1]:8080"), .loopback)
    }

    func testLocalhost() {
        XCTAssertEqual(AttacheDataEgressClassifier.endpointLocality("http://localhost:3000"), .loopback)
    }

    func testLANHostnames() {
        XCTAssertEqual(AttacheDataEgressClassifier.endpointLocality("http://192.168.1.10"), .localNetwork)
        XCTAssertEqual(AttacheDataEgressClassifier.endpointLocality("http://10.0.0.2"), .localNetwork)
        XCTAssertEqual(AttacheDataEgressClassifier.endpointLocality("http://172.16.0.9"), .localNetwork)
        XCTAssertEqual(AttacheDataEgressClassifier.endpointLocality("http://172.31.255.255"), .localNetwork)
        XCTAssertEqual(AttacheDataEgressClassifier.endpointLocality("http://nas.local:11434"), .localNetwork)
        XCTAssertEqual(AttacheDataEgressClassifier.endpointLocality("http://169.254.1.1"), .localNetwork)
    }

    func test172OutsidePrivateRangeIsRemote() {
        XCTAssertEqual(AttacheDataEgressClassifier.endpointLocality("http://172.15.0.1"), .remote)
        XCTAssertEqual(AttacheDataEgressClassifier.endpointLocality("http://172.32.0.1"), .remote)
    }

    func testHTTPSRemoteHosts() {
        XCTAssertEqual(AttacheDataEgressClassifier.endpointLocality("https://api.x.ai/v1"), .remote)
        XCTAssertEqual(AttacheDataEgressClassifier.endpointLocality("https://api.groq.com/openai/v1"), .remote)
    }

    func testMalformedURLIsUnknown() {
        XCTAssertEqual(AttacheDataEgressClassifier.endpointLocality(""), .unknown)
        XCTAssertEqual(AttacheDataEgressClassifier.endpointLocality(nil), .unknown)
        XCTAssertEqual(AttacheDataEgressClassifier.endpointLocality("   "), .unknown)
    }

    // MARK: - Content-free (acceptance 8)

    func testEgressAndLabelsAreContentFree() {
        // No credentials, prompts, or endpoint content appear in the egress or labels.
        for egress in AttacheDataEgress.allCases {
            XCTAssertFalse(egress.disclosureLabel.contains("key"))
            XCTAssertFalse(egress.disclosureLabel.contains("token"))
        }
        // The data categories name kinds of context, not values.
        for category in AttacheDataEgress.dataCategories {
            XCTAssertFalse(category.contains("sk-"))
            XCTAssertFalse(category.contains("Bearer"))
        }
    }
}