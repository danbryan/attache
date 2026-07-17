import XCTest
@testable import AttacheApp

/// Unit tests for the pure voice picker filtering/grouping logic (INF-352
/// step 5). Uses a fixed fixture catalog, never real installed voices or
/// network voice lists, so results are fully deterministic.
final class VoicePickerFilterTests: XCTestCase {
    // MARK: Fixtures

    private let systemOptions: [AttacheVoiceOption] = [
        AttacheVoiceOption(id: "com.apple.voice.premium.en_US.Ava", name: "Ava (Premium)", gender: "female", localeIdentifier: "en_US"),
        AttacheVoiceOption(id: "com.apple.voice.enhanced.en_US.Allison", name: "Allison (Enhanced)", gender: "female", localeIdentifier: "en_US"),
        AttacheVoiceOption(id: "com.apple.voice.compact.en_US.Samantha", name: "Samantha", gender: "female", localeIdentifier: "en_US"),
        AttacheVoiceOption(id: "com.apple.voice.compact.ko_KR.Yuna", name: "Yuna", gender: "female", localeIdentifier: "ko_KR")
    ]
    private let xaiOptions: [RemoteVoiceOption] = [
        RemoteVoiceOption(id: "ara", name: "Ara", provider: .xai, detail: "en")
    ]
    private let openaiOptions: [RemoteVoiceOption] = [
        RemoteVoiceOption(id: "marin", name: "Marin", provider: .openai, detail: "natural, newest")
    ]

    private func names(_ result: VoicePickerResult) -> Set<String> {
        Set(result.groups.flatMap(\.entries).map(\.name))
    }

    // MARK: Search

    func testNameSearchNarrowsCorrectly() {
        let state = VoicePickerFilterState(searchText: "Ava")
        let result = VoicePickerFilter.result(systemOptions: systemOptions, xaiOptions: xaiOptions, openaiOptions: openaiOptions, state: state)
        XCTAssertEqual(names(result), ["Ava (Premium)"])
    }

    func testLanguageSearchNarrowsCorrectly() {
        let state = VoicePickerFilterState(searchText: "Korean")
        let result = VoicePickerFilter.result(systemOptions: systemOptions, xaiOptions: xaiOptions, openaiOptions: openaiOptions, state: state)
        XCTAssertEqual(names(result), ["Yuna"])
    }

    // MARK: Engine filters

    func testSystemOnlyEngineFilterNarrowsCorrectly() {
        let state = VoicePickerFilterState(engines: [.system])
        let result = VoicePickerFilter.result(systemOptions: systemOptions, xaiOptions: xaiOptions, openaiOptions: openaiOptions, state: state)
        XCTAssertEqual(names(result), ["Ava (Premium)", "Allison (Enhanced)", "Samantha", "Yuna"])
    }

    func testGrokOnlyEngineFilterNarrowsCorrectly() {
        let state = VoicePickerFilterState(engines: [.xai])
        let result = VoicePickerFilter.result(systemOptions: systemOptions, xaiOptions: xaiOptions, openaiOptions: openaiOptions, state: state)
        XCTAssertEqual(names(result), ["Ara"])
    }

    func testOpenAIOnlyEngineFilterNarrowsCorrectly() {
        let state = VoicePickerFilterState(engines: [.openai])
        let result = VoicePickerFilter.result(systemOptions: systemOptions, xaiOptions: xaiOptions, openaiOptions: openaiOptions, state: state)
        XCTAssertEqual(names(result), ["Marin"])
    }

    // MARK: Quality filters

    func testPremiumQualityFilterNarrowsCorrectly() {
        let state = VoicePickerFilterState(qualities: [.premium])
        let result = VoicePickerFilter.result(systemOptions: systemOptions, xaiOptions: xaiOptions, openaiOptions: openaiOptions, state: state)
        // Cloud voices have no quality tier and are unaffected by the quality filter.
        XCTAssertEqual(names(result), ["Ava (Premium)", "Ara", "Marin"])
    }

    func testEnhancedQualityFilterNarrowsCorrectly() {
        let state = VoicePickerFilterState(qualities: [.enhanced])
        let result = VoicePickerFilter.result(systemOptions: systemOptions, xaiOptions: xaiOptions, openaiOptions: openaiOptions, state: state)
        XCTAssertEqual(names(result), ["Allison (Enhanced)", "Ara", "Marin"])
    }

    func testCompactQualityFilterNarrowsCorrectly() {
        let state = VoicePickerFilterState(qualities: [.compact])
        let result = VoicePickerFilter.result(systemOptions: systemOptions, xaiOptions: xaiOptions, openaiOptions: openaiOptions, state: state)
        XCTAssertEqual(names(result), ["Samantha", "Yuna", "Ara", "Marin"])
    }

    // MARK: Combined filter

    func testCombinedEngineQualitySearchFilterNarrowsCorrectly() {
        let state = VoicePickerFilterState(searchText: "a", engines: [.system], qualities: [.premium])
        let result = VoicePickerFilter.result(systemOptions: systemOptions, xaiOptions: xaiOptions, openaiOptions: openaiOptions, state: state)
        XCTAssertEqual(names(result), ["Ava (Premium)"])
    }

    // MARK: Empty result

    func testUnmatchedLanguageFilterReturnsEmptyNotCrash() {
        let state = VoicePickerFilterState(languageCode: "fr")
        let result = VoicePickerFilter.result(systemOptions: systemOptions, xaiOptions: xaiOptions, openaiOptions: openaiOptions, state: state)
        XCTAssertTrue(result.groups.allSatisfy { $0.entries.isEmpty })
        XCTAssertTrue(result.recommended.isEmpty || result.recommended.allSatisfy { $0.languageCode == "fr" })
    }

    // MARK: Grouping order

    func testUserLocaleGroupSortsFirst() {
        let state = VoicePickerFilterState()
        let result = VoicePickerFilter.result(
            systemOptions: systemOptions, xaiOptions: xaiOptions, openaiOptions: openaiOptions,
            state: state, userLanguageCode: "ko"
        )
        let nonEmptyGroups = result.groups.filter { !$0.entries.isEmpty }
        XCTAssertEqual(nonEmptyGroups.first?.languageCode, "ko")
    }

    // MARK: Recommended ordering matches AttacheVoiceCatalog.recommended's contract

    func testRecommendedOrderingMatchesVoiceCatalogContract() {
        let options = [
            AttacheVoiceOption(id: "com.apple.voice.compact.en_US.Joelle", name: "Joelle", gender: "female", localeIdentifier: "en_US"),
            AttacheVoiceOption(id: "com.apple.speech.synthesis.voice.Ralph", name: "Ralph", gender: "male", localeIdentifier: "en_US"),
            AttacheVoiceOption(id: "com.apple.voice.premium.en_US.Ava", name: "Ava (Premium)", gender: "female", localeIdentifier: "en_US"),
            AttacheVoiceOption(id: "com.apple.voice.premium.en_US.Zoe", name: "Zoe (Premium)", gender: "female", localeIdentifier: "en_US")
        ]
        let expected = AttacheVoiceCatalog.recommended(from: options, primaryLanguage: "en").prefix(3).map(\.name)
        let result = VoicePickerFilter.result(
            systemOptions: options, xaiOptions: [], openaiOptions: [],
            state: VoicePickerFilterState(), primaryLanguage: "en"
        )
        XCTAssertEqual(result.recommended.map(\.name), Array(expected))
    }
}
