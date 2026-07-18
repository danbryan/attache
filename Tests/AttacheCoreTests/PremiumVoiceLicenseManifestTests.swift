import XCTest
@testable import AttacheCore

/// The license manifest is the single source of truth for voice attribution.
/// These lock: the shipped catalog is exactly the permissive Azelma voice, no
/// noncommercial id can leak in, every CC BY 4.0 entry carries attribution and a
/// URL, and the manifest matches the JSON mirror the generator script renders
/// from (so THIRD-PARTY-LICENSES cannot drift from Core).
final class PremiumVoiceLicenseManifestTests: XCTestCase {

    func testShippedContainsExactlyAzelma() throws {
        let manifest = PremiumVoiceLicenseManifest.shipped
        XCTAssertEqual(manifest.entries.map(\.id), ["azelma"])
        let azelma = try XCTUnwrap(manifest.entry(id: "azelma"))
        XCTAssertEqual(azelma.displayName, "Azelma")
        XCTAssertEqual(azelma.license, .ccBy4)
    }

    func testKnownNoncommercialIdsAreAbsent() {
        let manifest = PremiumVoiceLicenseManifest.shipped
        for id in ["cosette", "jean"] {
            XCTAssertNil(manifest.entry(id: id), "\(id) is a noncommercial catalog voice and must not ship")
        }
    }

    func testEveryCCBy4EntryCarriesAttributionAndURL() {
        let manifest = PremiumVoiceLicenseManifest.shipped
        XCTAssertTrue(
            manifest.entriesMissingRequiredAttribution.isEmpty,
            "every CC BY 4.0 entry must carry non-empty attribution text and a license URL"
        )
        for entry in manifest.entries where entry.license == .ccBy4 {
            XCTAssertFalse(entry.attributionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(entry.licenseURL.absoluteString.isEmpty)
        }
    }

    func testMissingAttributionIsDetected() {
        let bad = PremiumVoiceLicenseManifest.Entry(
            id: "x",
            displayName: "X",
            sourceDescription: "s",
            license: .ccBy4,
            attributionText: "   ",
            licenseURL: URL(string: "https://example.com")!
        )
        XCTAssertTrue(bad.isMissingRequiredAttribution)

        let cc0 = PremiumVoiceLicenseManifest.Entry(
            id: "y",
            displayName: "Y",
            sourceDescription: "s",
            license: .cc0,
            attributionText: "",
            licenseURL: URL(string: "https://example.com")!
        )
        XCTAssertFalse(cc0.isMissingRequiredAttribution, "cc0 does not require attribution text")
    }

    func testShippedMatchesJSONMirror() throws {
        // The generator script renders the voice section from this JSON; a match
        // here is what guarantees THIRD-PARTY-LICENSES cannot drift from Core.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AttacheCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let jsonURL = repoRoot
            .appendingPathComponent("licenses")
            .appendingPathComponent("premium-voice-voices.json")
        let data = try Data(contentsOf: jsonURL)
        let mirror = try PremiumVoiceLicenseManifest.parse(data)
        XCTAssertEqual(mirror, PremiumVoiceLicenseManifest.shipped)
    }

    func testJSONRoundTrip() throws {
        let decoded = try PremiumVoiceLicenseManifest.parse(PremiumVoiceLicenseManifest.shipped.encoded())
        XCTAssertEqual(decoded, PremiumVoiceLicenseManifest.shipped)
    }
}

/// The About pane credit lines are produced by a pure Core formatter so their
/// exact wording and the tappable-link markup are testable without a view.
final class PremiumVoiceCreditsTests: XCTestCase {

    func testFixedEngineAndUpdatesCredits() {
        XCTAssertEqual(PremiumVoiceCredits.engineCredit, "Speech engine: pocket-tts by Kyutai, MIT License.")
        XCTAssertTrue(PremiumVoiceCredits.engineSubcredit.contains("ONNX Runtime"))
        XCTAssertTrue(PremiumVoiceCredits.engineSubcredit.contains("SentencePiece"))
        XCTAssertEqual(PremiumVoiceCredits.updatesCredit, "In-app updates: Sparkle, MIT License.")
    }

    func testAzelmaPlainCredit() throws {
        let entry = try XCTUnwrap(PremiumVoiceLicenseManifest.shipped.entry(id: "azelma"))
        let plain = PremiumVoiceCredits.voiceCreditPlain(entry)
        XCTAssertTrue(plain.hasPrefix("Azelma voice: Derived from the VCTK Corpus"))
        XCTAssertTrue(plain.contains("Voice embedding by Kyutai"))
        XCTAssertTrue(plain.contains("on-device synthesis voice"))
    }

    func testAzelmaMarkdownCarriesTappableLicenseLink() throws {
        let entry = try XCTUnwrap(PremiumVoiceLicenseManifest.shipped.entry(id: "azelma"))
        let markdown = PremiumVoiceCredits.voiceCreditMarkdown(entry)
        XCTAssertTrue(
            markdown.contains("[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)"),
            "the license name must render as a tappable link"
        )
    }

    func testMarkdownFallsBackWhenPhraseAbsent() {
        let entry = PremiumVoiceLicenseManifest.Entry(
            id: "z",
            displayName: "Z",
            sourceDescription: "s",
            license: .ccBy4,
            attributionText: "No license phrase here.",
            licenseURL: URL(string: "https://example.com")!
        )
        // Plain text has no "CC BY 4.0" phrase, so no link is injected.
        XCTAssertEqual(
            PremiumVoiceCredits.voiceCreditMarkdown(entry),
            PremiumVoiceCredits.voiceCreditPlain(entry)
        )
    }
}
