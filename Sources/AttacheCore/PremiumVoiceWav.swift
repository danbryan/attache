import Foundation

/// A minimal, correct RIFF/WAVE reader and writer for the Attaché Premium voice
/// path. The vendored C streaming runtime emits raw 32-bit float PCM chunks and
/// its CLI writes a placeholder-sized RIFF header (the `data` size is a ~2 GB
/// stand-in), so Attaché writes its own header from the true sample count rather
/// than trusting the stream header. Kept pure in Core so the byte layout is unit
/// tested without the App target or the native runtime.
public enum PremiumVoiceWav {

    public struct Format: Equatable, Sendable {
        public let sampleRate: Int
        public let channelCount: Int
        public let bitsPerSample: Int
        /// 3 = IEEE float, 1 = PCM integer (WAVE format tag).
        public let formatTag: Int

        public init(sampleRate: Int, channelCount: Int, bitsPerSample: Int, formatTag: Int) {
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.bitsPerSample = bitsPerSample
            self.formatTag = formatTag
        }
    }

    public struct Parsed: Equatable, Sendable {
        public let format: Format
        /// Frames = samples per channel. Total samples = frameCount * channelCount.
        public let frameCount: Int
        public let dataByteCount: Int

        public var durationSeconds: Double {
            format.sampleRate > 0 ? Double(frameCount) / Double(format.sampleRate) : 0
        }
    }

    public enum WavError: Error, Equatable {
        case truncated
        case notRIFF
        case notWAVE
        case missingFormatChunk
        case missingDataChunk
        case unsupportedSampleRate
    }

    /// Encode mono 32-bit float PCM to a correctly sized IEEE-float WAV.
    public static func encodeFloatPCM(_ samples: [Float], sampleRate: Int) -> Data {
        precondition(sampleRate > 0, "sample rate must be positive")
        let channelCount = 1
        let bitsPerSample = 32
        let bytesPerSample = bitsPerSample / 8
        let blockAlign = channelCount * bytesPerSample
        let byteRate = sampleRate * blockAlign
        let dataBytes = samples.count * bytesPerSample
        let riffChunkSize = 36 + dataBytes

        var data = Data()
        data.reserveCapacity(44 + dataBytes)
        func appendASCII(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func appendU32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func appendU16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }

        appendASCII("RIFF")
        appendU32(UInt32(riffChunkSize))
        appendASCII("WAVE")

        appendASCII("fmt ")
        appendU32(16)                              // PCM fmt chunk size
        appendU16(3)                               // IEEE float
        appendU16(UInt16(channelCount))
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(byteRate))
        appendU16(UInt16(blockAlign))
        appendU16(UInt16(bitsPerSample))

        appendASCII("data")
        appendU32(UInt32(dataBytes))
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Parse the header + locate the `data` chunk, tolerating extra chunks
    /// (LIST/fact/etc.) placed before `data`. Does not copy the audio payload.
    public static func parse(_ data: Data) throws -> Parsed {
        guard data.count >= 12 else { throw WavError.truncated }
        func ascii(_ offset: Int) -> String {
            String(bytes: data[data.startIndex + offset ..< data.startIndex + offset + 4], encoding: .ascii) ?? ""
        }
        func u32(_ offset: Int) -> Int {
            let base = data.startIndex + offset
            let b0 = Int(data[base]); let b1 = Int(data[base + 1])
            let b2 = Int(data[base + 2]); let b3 = Int(data[base + 3])
            return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
        }
        func u16(_ offset: Int) -> Int {
            let base = data.startIndex + offset
            return Int(data[base]) | (Int(data[base + 1]) << 8)
        }

        guard ascii(0) == "RIFF" else { throw WavError.notRIFF }
        guard ascii(8) == "WAVE" else { throw WavError.notWAVE }

        var offset = 12
        var format: Format?
        var dataByteCount: Int?

        while offset + 8 <= data.count {
            let chunkID = ascii(offset)
            let chunkSize = u32(offset + 4)
            let bodyStart = offset + 8

            if chunkID == "fmt " {
                guard bodyStart + 16 <= data.count else { throw WavError.truncated }
                format = Format(
                    sampleRate: u32(bodyStart + 4),
                    channelCount: u16(bodyStart + 2),
                    bitsPerSample: u16(bodyStart + 14),
                    formatTag: u16(bodyStart)
                )
            } else if chunkID == "data" {
                // The stream writer may store a placeholder size larger than the
                // file; clamp to the bytes actually present.
                let available = data.count - bodyStart
                dataByteCount = max(0, min(chunkSize, available))
                break
            }

            // Chunks are word-aligned (pad byte when the size is odd).
            offset = bodyStart + chunkSize + (chunkSize & 1)
        }

        guard let format else { throw WavError.missingFormatChunk }
        guard let dataByteCount else { throw WavError.missingDataChunk }
        guard format.sampleRate > 0 else { throw WavError.unsupportedSampleRate }

        let bytesPerFrame = max(1, (format.bitsPerSample / 8) * max(1, format.channelCount))
        let frameCount = dataByteCount / bytesPerFrame
        return Parsed(format: format, frameCount: frameCount, dataByteCount: dataByteCount)
    }
}
