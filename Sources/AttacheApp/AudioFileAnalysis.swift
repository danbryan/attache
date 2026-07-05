import Accelerate
import AVFoundation
import AttacheCore
import Foundation

enum AudioFileAnalysis {
    static func analyze(url: URL) throws -> AnalyzedAudioTimeline {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCapacity = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return .empty
        }

        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else {
            return .empty
        }

        let channelCount = max(1, Int(format.channelCount))
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return .empty }

        // Average the channels into mono: mono += channel * (1/channelCount).
        var scale = 1.0 / Float(channelCount)
        var mono = [Float](repeating: 0, count: frameLength)
        mono.withUnsafeMutableBufferPointer { out in
            guard let base = out.baseAddress else { return }
            for channel in 0..<channelCount {
                vDSP_vsma(channels[channel], 1, &scale, base, 1, base, 1, vDSP_Length(frameLength))
            }
        }

        return AudioTimelineBuilder.analyze(samples: mono, sampleRate: format.sampleRate)
    }
}
