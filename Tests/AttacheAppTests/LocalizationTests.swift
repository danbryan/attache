import XCTest
@testable import AttacheApp

/// INF-194: the interface ships in the friends languages. These tests read
/// the compiled localization tables straight from the module bundle.
final class LocalizationTests: XCTestCase {
    private let languages = ["ko", "es", "pt", "pl", "de", "nb", "th"]

    private func table(for language: String) throws -> [String: String] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Localizable", withExtension: "strings",
                              subdirectory: nil, localization: language),
            "missing Localizable.strings for \(language)"
        )
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: String])
    }

    func testEveryLanguageShipsTheFullTable() throws {
        let reference = try table(for: "ko")
        XCTAssertGreaterThanOrEqual(reference.count, 240, "expected the full catalog")
        for language in languages {
            let strings = try table(for: language)
            XCTAssertEqual(strings.count, reference.count, "\(language) is missing keys")
            for (key, value) in strings {
                XCTAssertFalse(value.isEmpty, "\(language) has an empty value for \(key)")
            }
        }
    }

    func testCoreSurfaceStringsAreTranslated() throws {
        // Spot checks: the strings a non-English user hits in the first minute.
        let expectations: [(lang: String, key: String, contains: String)] = [
            ("ko", "Open Inbox", "받은함"),
            ("es", "Playback speed", "reproducción"),
            ("pl", "Keyboard Shortcuts", "Skróty"),
            ("de", "Settings…", "Einstellungen"),
            ("nb", "History", "Historikk"),
            ("th", "Voice & Captions", "เสียง")
        ]
        for expectation in expectations {
            let strings = try table(for: expectation.lang)
            let value = try XCTUnwrap(strings[expectation.key], "\(expectation.lang) missing \(expectation.key)")
            XCTAssertTrue(value.contains(expectation.contains),
                          "\(expectation.lang)/\(expectation.key) = \(value)")
        }
    }

    func testTranslationsPreserveFormatSpecifiers() throws {
        for language in languages {
            for (key, value) in try table(for: language) where key.contains("%") {
                XCTAssertTrue(value.contains("%"),
                              "\(language)/\(key) dropped a format specifier")
            }
        }
    }
}
