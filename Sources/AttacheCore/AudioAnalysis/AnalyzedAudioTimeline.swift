import Foundation

public struct AnalyzedAudioTimeline: Sendable, Equatable {
    public var frames: [AnalysisFrame]
    public var durationMs: Int

    public init(frames: [AnalysisFrame], durationMs: Int) {
        self.frames = frames
        self.durationMs = durationMs
    }

    public static var empty: AnalyzedAudioTimeline {
        AnalyzedAudioTimeline(frames: [], durationMs: 0)
    }

    public func frame(at milliseconds: Int) -> AnalysisFrame {
        guard !frames.isEmpty else { return AnalysisFrame() }
        let seconds = Double(max(0, milliseconds)) / 1000.0

        var low = 0
        var high = frames.count - 1
        var picked = 0
        while low <= high {
            let mid = (low + high) / 2
            if frames[mid].timestamp <= seconds {
                picked = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return frames[picked]
    }
}

public enum AudioTimelineBuilder {
    public static func analyze(samples: [Float], sampleRate: Double, frameSize: Int = 1_024) -> AnalyzedAudioTimeline {
        guard !samples.isEmpty, sampleRate > 0 else { return .empty }

        let analyzer = AudioAnalyzer(sampleRate: sampleRate, fftSize: frameSize)
        var frames: [AnalysisFrame] = []
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + frameSize)
            let chunk = Array(samples[offset..<end])
            let timestamp = Double(offset) / sampleRate
            frames.append(analyzer.process(mono: chunk, timestamp: timestamp))
            offset = end
        }

        let durationMs = Int((Double(samples.count) / sampleRate * 1000).rounded())
        return AnalyzedAudioTimeline(frames: frames, durationMs: durationMs)
    }
}
