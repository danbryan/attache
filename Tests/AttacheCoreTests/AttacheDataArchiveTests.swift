import AttacheCore
import XCTest

final class AttacheDataArchiveTests: XCTestCase {
    // MARK: Manifest round-trip

    func testManifestRoundTrip() throws {
        let manifest = AttacheDataArchive.Manifest(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "0.4.0",
            contents: ["Attache.sqlite", "Personalities", "defaults.plist"]
        )
        let data = try AttacheDataArchive.encodeManifest(manifest)
        let decoded = try AttacheDataArchive.decodeManifest(from: data)
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.formatVersion, AttacheDataArchive.currentFormatVersion)
    }

    func testDecodeMalformedManifestThrows() {
        let garbage = Data("not a manifest".utf8)
        XCTAssertThrowsError(try AttacheDataArchive.decodeManifest(from: garbage)) { error in
            XCTAssertEqual(error as? AttacheDataArchive.ArchiveError, .malformedManifest)
        }
    }

    // MARK: Version refusal

    func testCurrentAndOlderFormatsRestore() throws {
        let current = AttacheDataArchive.Manifest(
            formatVersion: AttacheDataArchive.currentFormatVersion,
            createdAt: Date(), appVersion: "x", contents: [])
        XCTAssertNoThrow(try AttacheDataArchive.validateRestorable(manifest: current))

        let older = AttacheDataArchive.Manifest(
            formatVersion: 0, createdAt: Date(), appVersion: "x", contents: [])
        XCTAssertNoThrow(try AttacheDataArchive.validateRestorable(manifest: older))
    }

    func testFutureFormatIsRefused() {
        let future = AttacheDataArchive.Manifest(
            formatVersion: AttacheDataArchive.currentFormatVersion + 1,
            createdAt: Date(), appVersion: "x", contents: [])
        XCTAssertThrowsError(try AttacheDataArchive.validateRestorable(manifest: future)) { error in
            XCTAssertEqual(
                error as? AttacheDataArchive.ArchiveError,
                .unsupportedFutureFormat(
                    found: AttacheDataArchive.currentFormatVersion + 1,
                    supported: AttacheDataArchive.currentFormatVersion))
        }
    }

    // MARK: Filesystem inclusion / exclusion

    func testEventTokenAndAudioCacheAlwaysExcluded() {
        XCTAssertFalse(AttacheDataArchive.includesEntry(named: "event-token", includePremiumVoice: true))
        XCTAssertFalse(AttacheDataArchive.includesEntry(named: "AudioCache", includePremiumVoice: true))
    }

    func testPremiumVoiceExcludedByDefaultIncludedWhenOptedIn() {
        XCTAssertFalse(AttacheDataArchive.includesEntry(named: "PremiumVoice", includePremiumVoice: false))
        XCTAssertTrue(AttacheDataArchive.includesEntry(named: "PremiumVoice", includePremiumVoice: true))
    }

    func testPlannedContentsFiltersAndSorts() {
        let names = [
            "Personalities", "Attache.sqlite", "event-token", "AudioCache",
            "PremiumVoice", "SessionPrivacyRegistry.json"
        ]
        let withoutVoice = AttacheDataArchive.plannedContents(
            fromEntryNames: names, includePremiumVoice: false)
        XCTAssertEqual(withoutVoice, ["Attache.sqlite", "Personalities", "SessionPrivacyRegistry.json"])
        XCTAssertFalse(withoutVoice.contains("event-token"))
        XCTAssertFalse(withoutVoice.contains("AudioCache"))
        XCTAssertFalse(withoutVoice.contains("PremiumVoice"))

        let withVoice = AttacheDataArchive.plannedContents(
            fromEntryNames: names, includePremiumVoice: true)
        XCTAssertTrue(withVoice.contains("PremiumVoice"))
        XCTAssertFalse(withVoice.contains("event-token"))
        XCTAssertFalse(withVoice.contains("AudioCache"))
    }

    // MARK: Premium voice backup option

    func testIncludePremiumVoiceOptionShownOnlyWhenInstalled() {
        XCTAssertTrue(AttacheDataArchive.showsIncludePremiumVoiceOption(isPremiumVoiceInstalled: true))
        XCTAssertFalse(AttacheDataArchive.showsIncludePremiumVoiceOption(isPremiumVoiceInstalled: false))
    }

    func testResolvedIncludePremiumVoiceRequiresInstalledAndOptIn() {
        XCTAssertTrue(AttacheDataArchive.resolvedIncludePremiumVoice(
            isPremiumVoiceInstalled: true, userRequestedInclusion: true))
        XCTAssertFalse(AttacheDataArchive.resolvedIncludePremiumVoice(
            isPremiumVoiceInstalled: true, userRequestedInclusion: false))
        // A checked box can never smuggle in a voice that is not installed.
        XCTAssertFalse(AttacheDataArchive.resolvedIncludePremiumVoice(
            isPremiumVoiceInstalled: false, userRequestedInclusion: true))
        XCTAssertFalse(AttacheDataArchive.resolvedIncludePremiumVoice(
            isPremiumVoiceInstalled: false, userRequestedInclusion: false))
    }

    // MARK: Sensitive defaults redaction

    func testSensitiveDefaultsKeysAreStripped() {
        let raw: [String: String] = [
            "attache.presentationLLMAPIKey": "sk-secret",
            "attache.presentationLLMAPIKeySecretRef": "op://vault/item",
            "attache.configuredSecretAccounts": "a,b",
            "attache.theme": "macOS",
            "attache.captionFontSize": "24",
            "attache.someToken": "abc",
            "attache.userPassword": "hunter2",
            "attache.serviceCredential": "z",
            "attache.bearerThing": "y"
        ]
        let result = AttacheDataArchive.redactingSensitiveKeys(raw)
        XCTAssertEqual(result.kept, [
            "attache.theme": "macOS",
            "attache.captionFontSize": "24"
        ])
        XCTAssertEqual(result.stripped, [
            "attache.bearerThing",
            "attache.configuredSecretAccounts",
            "attache.presentationLLMAPIKey",
            "attache.presentationLLMAPIKeySecretRef",
            "attache.serviceCredential",
            "attache.someToken",
            "attache.userPassword"
        ])
    }

    func testNonSensitiveKeysAreNotFlaggedSensitive() {
        for key in ["attache.theme", "attache.captionLineCount", "attache.watchedSessions",
                    "attache.voicemailMode", "attache.uiTextScale"] {
            XCTAssertFalse(AttacheDataArchive.isSensitiveDefaultsKey(key), key)
        }
    }
}
