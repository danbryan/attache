import Foundation
import AVFoundation
import AttacheCore

/// Levels the on-device system voice (NSSpeechSynthesizer) output file to the same
/// standard spoken-audio loudness as the premium and cloud engines, so the OS
/// volume is the only volume control and no engine is quieter than the others.
///
/// NSSpeechSynthesizer writes a finished AIFF at whatever level the macOS voice
/// produces (measured ~-22 LUFS, quieter even than the raw premium voice), and it
/// exposes no gain knob, so the leveling happens as an in-place post-process on the
/// written file. The loudness math is the shared, unit-tested
/// `SpokenAudioLoudness` in Core; this App-side shim only reads the file to floats,
/// runs that function, and writes the result back.
enum SystemVoiceLoudnessNormalizer {

    /// Normalize the audio file at `url` in place. Best-effort: any read/write or
    /// format problem leaves the original file untouched, so a normalization miss
    /// degrades to the (quieter) original rather than to a broken card.
    static func normalizeFileInPlace(at url: URL) {
        guard let reader = try? AVAudioFile(forReading: url) else { return }
        let format = reader.processingFormat
        let frames = AVAudioFrameCount(reader.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        do {
            try reader.read(into: buffer)
        } catch {
            return
        }
        guard let channelData = buffer.floatChannelData else { return }

        let channelCount = Int(format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let sampleRate = Int(format.sampleRate.rounded())

        // Downmix to mono to measure loudness (the system voice is mono; a downmix
        // is a safe no-op for it and correct for any stereo voice).
        var mono = [Float](repeating: 0, count: frameCount)
        for c in 0..<channelCount {
            let p = channelData[c]
            for i in 0..<frameCount { mono[i] += p[i] }
        }
        if channelCount > 1 {
            let inv = 1 / Float(channelCount)
            for i in 0..<frameCount { mono[i] *= inv }
        }

        let normalized = SpokenAudioLoudness.normalize(samples: mono, sampleRate: sampleRate)
        // Nothing to do (silence, near-target, or the limiter left it unchanged).
        if normalized.count == mono.count, normalized == mono { return }

        // Apply the derived per-sample gain to every channel so a stereo image is
        // preserved. gain = normalized/mono, guarding divide-by-zero at silence.
        for c in 0..<channelCount {
            let p = channelData[c]
            for i in 0..<frameCount {
                let original = mono[i]
                if original != 0 {
                    p[i] *= normalized[i] / original
                } else {
                    p[i] = normalized[i]
                }
            }
        }

        // Write the leveled audio back to the same URL in the original file format.
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".leveling-\(UUID().uuidString).\(url.pathExtension)")
        do {
            let writer = try AVAudioFile(
                forWriting: tmp,
                settings: reader.fileFormat.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            try writer.write(from: buffer)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return
        }
        // Swap the leveled file in atomically; on any failure keep the original.
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
