import XCTest
@testable import AttacheCore

final class DiagnosticSnapshotTests: XCTestCase {
    func testRenderedContainsKindsAndCountsNotSecrets() {
        let snapshot = DiagnosticSnapshot(
            appVersion: "0.1.1",
            enabledSources: ["codex", "claude_code"],
            presentationProviderKind: "ollama",
            voiceProviderKind: "system",
            cardCount: 42,
            instructionCount: 3,
            taggingFailureCount: 2,
            logLines: ["watcher: tail read failed for session abc"]
        )
        let text = snapshot.rendered()
        XCTAssertTrue(text.contains("app_version: 0.1.1"))
        XCTAssertTrue(text.contains("enabled_sources: codex, claude_code"))
        XCTAssertTrue(text.contains("presentation_provider: ollama"))
        XCTAssertTrue(text.contains("cards: 42"))
        XCTAssertTrue(text.contains("instructions: 3"))
        XCTAssertTrue(text.contains("tagging_failures: 2"))
        XCTAssertTrue(text.contains("watcher: tail read failed"))
    }

    func testTaggingFailureCountDefaultsToZero() {
        let snapshot = DiagnosticSnapshot(
            appVersion: "0.1.1", enabledSources: [], presentationProviderKind: "none",
            voiceProviderKind: "system", cardCount: 0, instructionCount: 0)
        XCTAssertTrue(snapshot.rendered().contains("tagging_failures: 0"))
    }

    func testConversationFallbackCountDefaultsToZeroAndRenders() {
        let snapshot = DiagnosticSnapshot(
            appVersion: "0.1.1", enabledSources: [], presentationProviderKind: "none",
            voiceProviderKind: "system", cardCount: 0, instructionCount: 0)
        XCTAssertEqual(snapshot.conversationFallbackCount, 0)
        XCTAssertTrue(snapshot.rendered().contains("conversation_fallbacks: 0"))

        let withFallbacks = DiagnosticSnapshot(
            appVersion: "0.1.1", enabledSources: [], presentationProviderKind: "ollama",
            voiceProviderKind: "system", cardCount: 0, instructionCount: 0,
            conversationFallbackCount: 3)
        XCTAssertTrue(withFallbacks.rendered().contains("conversation_fallbacks: 3"))
    }

    func testEmptySourcesRenderNone() {
        let snapshot = DiagnosticSnapshot(
            appVersion: "0.1.1", enabledSources: [], presentationProviderKind: "none",
            voiceProviderKind: "system", cardCount: 0, instructionCount: 0)
        XCTAssertTrue(snapshot.rendered().contains("enabled_sources: none"))
    }

    func testLogLinesCappedAtFifty() {
        let many = (0..<200).map { "line \($0)" }
        let snapshot = DiagnosticSnapshot(
            appVersion: "0.1.1", enabledSources: ["codex"], presentationProviderKind: "ollama",
            voiceProviderKind: "system", cardCount: 1, instructionCount: 0, logLines: many)
        let rendered = snapshot.rendered()
        XCTAssertTrue(rendered.contains("line 199"))
        XCTAssertFalse(rendered.contains("line 149"))   // only the last 50 kept
    }
}
