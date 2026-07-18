import XCTest
@testable import AttacheCore

/// The pinned release descriptor is the single source of truth for the download
/// URL, checksum, version, and unpacked size. These lock the placeholder state
/// (so a mis-shipped build fails closed) and the parse/normalize rules.
final class PremiumVoiceReleaseTests: XCTestCase {

    func testPinnedCarriesTheShippedReleaseAsset() {
        // The premium-voice-v1 GitHub release asset is uploaded; pinned must
        // carry its real checksum, never the placeholder (a placeholder here
        // would fail every user download closed).
        let pinned = PremiumVoiceRelease.pinned
        XCTAssertFalse(pinned.isChecksumPlaceholder, "pinned must reference the uploaded asset, not the placeholder")
        XCTAssertEqual(
            pinned.normalizedSHA256,
            "63c0c620bf80a82f1df31cc017d048fff331fc4762ada2c121c45a2a67031a5c"
        )
        XCTAssertEqual(pinned.version, "v1")
        XCTAssertEqual(pinned.bundleURL.scheme, "https")
        XCTAssertEqual(
            pinned.bundleURL.absoluteString,
            "https://github.com/danbryan/attache/releases/download/premium-voice-v1/premium-voice-int8.tar.gz"
        )
        XCTAssertGreaterThan(pinned.unpackedSizeBytes, 100_000_000)
        XCTAssertTrue(pinned.contents.contains("models/tokenizer.model"))
        XCTAssertTrue(pinned.contents.contains("voices/azelma.wav"))
    }

    func testNormalizesValidChecksumLowercased() {
        let sha = String(repeating: "AB", count: 32) // 64 hex chars, uppercase
        let release = PremiumVoiceRelease(
            version: "v1",
            bundleURL: URL(string: "https://example.com/x.tar.gz")!,
            sha256: sha,
            unpackedSizeBytes: 10,
            contents: []
        )
        XCTAssertFalse(release.isChecksumPlaceholder)
        XCTAssertEqual(release.normalizedSHA256, sha.lowercased())
    }

    func testRejectsWrongLengthOrNonHexChecksum() {
        XCTAssertNil(PremiumVoiceRelease.normalizedSHA256("abc123"))
        XCTAssertNil(PremiumVoiceRelease.normalizedSHA256(String(repeating: "z", count: 64)))
        XCTAssertNil(PremiumVoiceRelease.normalizedSHA256(PremiumVoiceRelease.checksumPlaceholder))
    }

    func testPinnedCarriesDistinctDownloadSize() {
        // Measured sizes of the shipped tarball vs its unpacked footprint.
        let pinned = PremiumVoiceRelease.pinned
        XCTAssertEqual(pinned.downloadSizeBytes, 113_179_974)
        XCTAssertEqual(pinned.effectiveDownloadSizeBytes, 113_179_974)
        XCTAssertEqual(pinned.downloadSizeDescription, "113.2 MB")
        XCTAssertEqual(pinned.unpackedSizeBytes, 203_011_198)
        XCTAssertNotEqual(pinned.downloadSizeBytes, pinned.unpackedSizeBytes)
    }

    func testDownloadSizeFallsBackToUnpackedWhenAbsent() {
        let release = PremiumVoiceRelease(
            version: "v1",
            bundleURL: URL(string: "https://example.com/x.tar.gz")!,
            sha256: String(repeating: "a", count: 64),
            unpackedSizeBytes: 215_000_000,
            contents: []
        )
        XCTAssertNil(release.downloadSizeBytes)
        XCTAssertEqual(release.effectiveDownloadSizeBytes, 215_000_000)
    }

    func testDownloadSizeSurvivesJSONRoundTrip() throws {
        let original = PremiumVoiceRelease(
            version: "v9",
            bundleURL: URL(string: "https://example.com/premium-voice-int8.tar.gz")!,
            sha256: String(repeating: "a", count: 64),
            unpackedSizeBytes: 215_000_000,
            downloadSizeBytes: 189_000_000,
            contents: []
        )
        let decoded = try PremiumVoiceRelease.parse(original.encoded())
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.downloadSizeBytes, 189_000_000)
    }

    func testJSONRoundTrip() throws {
        let original = PremiumVoiceRelease(
            version: "v2",
            bundleURL: URL(string: "https://example.com/premium-voice-int8.tar.gz")!,
            sha256: String(repeating: "a", count: 64),
            unpackedSizeBytes: 215_000_000,
            contents: ["models/tokenizer.model", "voices/azelma.wav"]
        )
        let data = try original.encoded()
        let decoded = try PremiumVoiceRelease.parse(data)
        XCTAssertEqual(decoded, original)
    }
}
