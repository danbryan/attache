import XCTest
@testable import AttacheCore

/// The Attaché Premium path writes its own RIFF header from the true sample
/// count (the native streaming writer emits a placeholder-sized header). These
/// prove the writer/parser round-trip on duration and sample count and that the
/// parser tolerates the placeholder data size.
final class PremiumVoiceWavTests: XCTestCase {

    func testRoundTripSampleCountAndDuration() throws {
        let sampleRate = 24_000
        let frameCount = 24_000 + 6_000 // 1.25 s
        let samples = (0..<frameCount).map { i in sinf(Float(i) * 0.05) * 0.5 }

        let data = PremiumVoiceWav.encodeFloatPCM(samples, sampleRate: sampleRate)
        // 44-byte canonical header + 4 bytes per float sample.
        XCTAssertEqual(data.count, 44 + frameCount * 4)

        let parsed = try PremiumVoiceWav.parse(data)
        XCTAssertEqual(parsed.frameCount, frameCount)
        XCTAssertEqual(parsed.format.sampleRate, sampleRate)
        XCTAssertEqual(parsed.format.channelCount, 1)
        XCTAssertEqual(parsed.format.bitsPerSample, 32)
        XCTAssertEqual(parsed.format.formatTag, 3) // IEEE float
        XCTAssertEqual(parsed.durationSeconds, Double(frameCount) / Double(sampleRate), accuracy: 1e-9)
    }

    func testEmptyIsAValidZeroLengthWav() throws {
        let data = PremiumVoiceWav.encodeFloatPCM([], sampleRate: 24_000)
        let parsed = try PremiumVoiceWav.parse(data)
        XCTAssertEqual(parsed.frameCount, 0)
        XCTAssertEqual(parsed.durationSeconds, 0)
    }

    func testParserClampsPlaceholderOversizedDataChunk() throws {
        // Mimic the native CLI's streaming header: a `data` size far larger than
        // the bytes actually present. The parser must clamp to what is there.
        let samples: [Float] = [0.1, -0.2, 0.3, -0.4]
        var data = PremiumVoiceWav.encodeFloatPCM(samples, sampleRate: 24_000)
        // Overwrite the 4-byte little-endian data-chunk size (last field before
        // the payload, at offset 40) with a bogus ~2 GB value.
        let bogus: UInt32 = 0x7FFF_FFFF
        data[40] = UInt8(bogus & 0xFF)
        data[41] = UInt8((bogus >> 8) & 0xFF)
        data[42] = UInt8((bogus >> 16) & 0xFF)
        data[43] = UInt8((bogus >> 24) & 0xFF)

        let parsed = try PremiumVoiceWav.parse(data)
        XCTAssertEqual(parsed.frameCount, samples.count)
        XCTAssertEqual(parsed.dataByteCount, samples.count * 4)
    }

    func testRejectsNonRIFF() {
        let junk = Data(repeating: 0, count: 64)
        XCTAssertThrowsError(try PremiumVoiceWav.parse(junk)) { error in
            XCTAssertEqual(error as? PremiumVoiceWav.WavError, .notRIFF)
        }
    }

    func testRejectsTruncated() {
        XCTAssertThrowsError(try PremiumVoiceWav.parse(Data([0x52, 0x49]))) { error in
            XCTAssertEqual(error as? PremiumVoiceWav.WavError, .truncated)
        }
    }
}
