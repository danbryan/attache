import XCTest
@testable import AttacheApp

final class CloudConsentTests: XCTestCase {
    func testLoopbackHostsAreLocal() {
        XCTAssertTrue(NetworkSecurity.isLoopbackHost("127.0.0.1"))
        XCTAssertTrue(NetworkSecurity.isLoopbackHost("localhost"))
        XCTAssertTrue(NetworkSecurity.isLoopbackHost("::1"))
        XCTAssertFalse(NetworkSecurity.isLoopbackHost("api.x.ai"))
        XCTAssertFalse(NetworkSecurity.isLoopbackHost(nil))
    }

    func testCloudEndpointDetection() {
        // Local model servers are not cloud.
        XCTAssertFalse(NetworkSecurity.isCloudEndpoint("http://127.0.0.1:11434/v1"))
        XCTAssertFalse(NetworkSecurity.isCloudEndpoint("http://localhost:1234/v1"))
        XCTAssertFalse(NetworkSecurity.isCloudEndpoint(""))
        XCTAssertFalse(NetworkSecurity.isCloudEndpoint("   "))
        // Off-machine endpoints are cloud.
        XCTAssertTrue(NetworkSecurity.isCloudEndpoint("https://api.x.ai/v1"))
        XCTAssertTrue(NetworkSecurity.isCloudEndpoint("https://api.groq.com/openai/v1"))
        XCTAssertTrue(NetworkSecurity.isCloudEndpoint("https://api.openai.com/v1"))
    }

    func testPresentationProvidersClassification() {
        // Fixed cloud endpoints require consent.
        XCTAssertTrue(NetworkSecurity.isCloudEndpoint(AttachePresentationProvider.xai.defaultBaseURL))
        XCTAssertTrue(NetworkSecurity.isCloudEndpoint(AttachePresentationProvider.groq.defaultBaseURL))
        // Local model servers do not.
        XCTAssertFalse(NetworkSecurity.isCloudEndpoint(AttachePresentationProvider.ollama.defaultBaseURL))
        // CLI providers carry no Attaché endpoint.
        XCTAssertTrue(AttachePresentationProvider.claudeCLI.isCLI)
        XCTAssertTrue(AttachePresentationProvider.codexCLI.isCLI)
    }

    func testVoiceEngineClassification() {
        XCTAssertFalse(AttacheSpeechProvider.system.sendsToCloud)
        XCTAssertTrue(AttacheSpeechProvider.elevenLabs.sendsToCloud)
        XCTAssertTrue(AttacheSpeechProvider.xai.sendsToCloud)
        XCTAssertTrue(AttacheSpeechProvider.openai.sendsToCloud)
    }
}
