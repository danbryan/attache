import XCTest
@testable import AttacheCore

/// INF-175: non-Latin content must survive the pipeline untouched, prompts
/// must carry the user's language, and karaoke must segment spaceless scripts.
final class MultilingualTests: XCTestCase {
    private let korean = "빌드가 완료되었고 테스트 132개가 모두 통과했습니다"
    private let thai = "การสร้างเสร็จสมบูรณ์และการทดสอบทั้งหมดผ่านแล้ว"

    private func claudeLine(_ text: String) -> String {
        """
        {"type":"assistant","timestamp":"2026-07-03T12:00:00.000Z","cwd":"/tmp/proj","message":{"content":[{"type":"text","text":"\(text)"}]}}
        """
    }

    func testKoreanTranscriptContentIntact() {
        let result = TranscriptParser.parse(text: claudeLine(korean), format: .claude, carriedCWD: nil)
        guard case let .assistantProse(text, _)? = result.records.first?.kind else {
            return XCTFail("no prose record parsed")
        }
        XCTAssertEqual(text, korean)
    }

    func testThaiTranscriptContentIntact() {
        let result = TranscriptParser.parse(text: claudeLine(thai), format: .claude, carriedCWD: nil)
        guard case let .assistantProse(text, _)? = result.records.first?.kind else {
            return XCTFail("no prose record parsed")
        }
        XCTAssertEqual(text, thai)
    }

    func testKoreanSurvivesCardStore() throws {
        let store = try CardStore(databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("multilingual-\(UUID().uuidString).sqlite"))
        let event = NormalizedEvent(
            source: "claude_code", eventType: "assistant.completed",
            externalSessionID: "ko-test", title: "한국어 세션",
            text: korean, metadata: [:]
        )
        let card = try store.insertEvent(event)
        XCTAssertTrue(card.spokenText.contains("빌드가 완료되었고"))
        XCTAssertEqual(card.sessionTitle, "한국어 세션")
    }

    func testPresentationPromptCarriesLanguageDirective() {
        let event = NormalizedEvent(
            source: "claude_code", eventType: "assistant.completed",
            title: "t", text: "Build finished.", metadata: [:]
        )
        let prompt = AttachePersonality.presentationPrompt(
            for: event, memoryContext: nil, spokenLanguageName: "Korean")
        let system = prompt.messages.first?.content ?? ""
        XCTAssertTrue(system.contains("in Korean"), system)

        let englishPrompt = AttachePersonality.presentationPrompt(
            for: event, memoryContext: nil, spokenLanguageName: nil)
        XCTAssertFalse(englishPrompt.messages.first?.content.contains("still answer in") ?? true)
    }

    // MARK: Karaoke segmentation

    func testEnglishTokensKeepPunctuation() {
        let alignment = CaptionAlignmentBuilder.fallback(text: "All done, merged and verified.", durationMs: 3000)
        let words = alignment.words.map(\.word)
        XCTAssertTrue(words.contains("done,"), "\(words)")
        XCTAssertTrue(words.contains("verified."), "\(words)")
    }

    func testKoreanSpacedTextSegmentsPerWord() {
        let alignment = CaptionAlignmentBuilder.fallback(text: korean, durationMs: 5000)
        XCTAssertGreaterThanOrEqual(alignment.words.count, 5, "\(alignment.words.map(\.word))")
    }

    func testThaiSpacelessRunSegmentsIntoWords() {
        let alignment = CaptionAlignmentBuilder.fallback(text: thai, durationMs: 5000)
        XCTAssertGreaterThanOrEqual(alignment.words.count, 4,
            "spaceless Thai should split on locale word boundaries: \(alignment.words.map(\.word))")
        // Nothing lost: the pieces concatenate back to the original.
        XCTAssertEqual(alignment.words.map(\.word).joined(), thai.replacingOccurrences(of: " ", with: ""))
    }

    func testChineseRunSegments() {
        let chinese = "构建已完成所有测试均已通过并且部署成功"
        let alignment = CaptionAlignmentBuilder.fallback(text: chinese, durationMs: 5000)
        XCTAssertGreaterThanOrEqual(alignment.words.count, 3, "\(alignment.words.map(\.word))")
    }

    func testShortLatinTokenNotSubSegmented() {
        let alignment = CaptionAlignmentBuilder.fallback(text: "supercalifragilistic expialidocious", durationMs: 3000)
        // Long but single-locale-word tokens stay whole.
        XCTAssertEqual(alignment.words.count, 2, "\(alignment.words.map(\.word))")
    }

}
