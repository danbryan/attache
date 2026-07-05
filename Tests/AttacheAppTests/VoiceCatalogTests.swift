import XCTest
@testable import AttacheApp

final class VoiceCatalogTests: XCTestCase {
    private func option(_ id: String, _ name: String) -> CompanionVoiceOption {
        CompanionVoiceOption(id: id, name: name, gender: "female", localeIdentifier: "en_US")
    }

    func testDetectsNewPremiumVoice() {
        let current = [option("com.apple.voice.compact.en-US.Samantha", "Samantha")]
        let fresh = current + [option("com.apple.voice.premium.en-US.Ava", "Ava (Premium)")]
        let found = CompanionVoiceCatalog.newlyAvailableVoice(fresh: fresh, current: current)
        XCTAssertEqual(found?.name, "Ava (Premium)")
    }

    func testDetectsNewCompactVoiceToo() {
        let premium = option("com.apple.voice.premium.en-US.Ava", "Ava (Premium)")
        let current = [premium]
        let fresh = current + [option("com.apple.voice.compact.en-GB.Jamie", "Jamie")]
        XCTAssertEqual(CompanionVoiceCatalog.newlyAvailableVoice(fresh: fresh, current: current)?.name, "Jamie")
    }

    func testPremiumWinsWhenSeveralArriveTogether() {
        let current: [CompanionVoiceOption] = []
        let fresh = [option("com.apple.voice.compact.en-GB.Jamie", "Jamie"),
                     option("com.apple.voice.enhanced.en-US.Allison", "Allison (Enhanced)"),
                     option("com.apple.voice.premium.en-US.Ava", "Ava (Premium)")]
        XCTAssertEqual(CompanionVoiceCatalog.newlyAvailableVoice(fresh: fresh, current: current)?.name,
                       "Ava (Premium)")
    }
}

extension VoiceCatalogTests {
    private func compact(_ name: String, _ locale: String = "en_US") -> CompanionVoiceOption {
        CompanionVoiceOption(id: "com.apple.voice.compact.\(locale).\(name)", name: name, gender: "female", localeIdentifier: locale)
    }
    private func legacy(_ name: String) -> CompanionVoiceOption {
        CompanionVoiceOption(id: "com.apple.speech.synthesis.voice.\(name)", name: name, gender: "male", localeIdentifier: "en_US")
    }
    private func premium(_ name: String, _ locale: String = "en_US") -> CompanionVoiceOption {
        CompanionVoiceOption(id: "com.apple.voice.premium.\(locale).\(name)", name: "\(name) (Premium)", gender: "female", localeIdentifier: locale)
    }

    func testEnglishSystemGetsHandPickedTrio() {
        let options = [compact("Samantha"), compact("Karen", "en_AU"), compact("Daniel", "en_GB"),
                       legacy("Ralph"), compact("Joelle"), compact("Jamie", "en_GB"),
                       compact("Moira", "en_IE"), compact("Rishi", "en_IN")]
        let top = CompanionVoiceCatalog.recommended(from: options, primaryLanguage: "en").prefix(3).map(\.name)
        XCTAssertEqual(Array(top), ["Joelle", "Ralph", "Jamie"])
    }

    func testInstalledPremiumsLeadOnEnglishSystems() {
        let options = [compact("Joelle"), legacy("Ralph"), premium("Ava"), premium("Zoe")]
        let top = CompanionVoiceCatalog.recommended(from: options, primaryLanguage: "en").prefix(3).map(\.name)
        XCTAssertEqual(Array(top), ["Ava (Premium)", "Zoe (Premium)", "Joelle"])
    }

    func testNonEnglishSystemLeadsWithNativeVoices() {
        let options = [compact("Joelle"), legacy("Ralph"), compact("Yuna", "ko_KR"), premium("Yuna2", "ko_KR")]
        let top = CompanionVoiceCatalog.recommended(from: options, primaryLanguage: "ko").prefix(3).map(\.name)
        XCTAssertEqual(top.first, "Yuna2 (Premium)")
        XCTAssertEqual(top.dropFirst().first, "Yuna")
    }

    func testDemotedNamesComeAfterNeutralFallbacks() {
        let options = [compact("Samantha"), compact("Tessa", "en_ZA")]
        let top = CompanionVoiceCatalog.recommended(from: options, primaryLanguage: "en").map(\.name)
        XCTAssertEqual(top, ["Tessa", "Samantha"])
    }
}
