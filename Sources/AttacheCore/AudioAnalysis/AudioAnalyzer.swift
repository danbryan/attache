import Accelerate

public final class AudioAnalyzer {
    private let sampleRate: Double
    private var ring: RingBuffer
    private let fftSize: Int
    private let fft: FFTProcessor
    private let mapper: BandMapper
    private let waveformLength: Int
    private var bandPeak: Float = 0.0001

    public init(
        sampleRate: Double = 48_000,
        historySeconds: Double = 1.0,
        waveformLength: Int = 1_024,
        bandCount: Int = 56,
        fftSize: Int = 1_024
    ) {
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.ring = RingBuffer(capacity: max(Int(sampleRate * historySeconds), fftSize))
        self.waveformLength = waveformLength
        self.fft = FFTProcessor(size: fftSize)
        self.mapper = BandMapper(bandCount: bandCount, fftSize: fftSize, sampleRate: sampleRate)
    }

    public func process(mono: [Float], timestamp: Double) -> AnalysisFrame {
        var frame = AnalysisFrame()
        frame.sampleRate = sampleRate
        frame.timestamp = timestamp
        frame.bands = [Float](repeating: 0, count: mapper.bandCount)
        guard !mono.isEmpty else { return frame }

        ring.append(mono)

        var rms: Float = 0
        vDSP_rmsqv(mono, 1, &rms, vDSP_Length(mono.count))
        frame.rms = rms

        var peak: Float = 0
        vDSP_maxmgv(mono, 1, &peak, vDSP_Length(mono.count))
        frame.peak = peak

        let magnitudes = fft.magnitudes(ring.latest(fftSize))
        if !magnitudes.isEmpty {
            var rawBands = mapper.bands(from: magnitudes)

            var maxBand: Float = 0
            vDSP_maxv(rawBands, 1, &maxBand, vDSP_Length(rawBands.count))
            if maxBand > bandPeak {
                bandPeak = maxBand
            } else {
                bandPeak = bandPeak * 0.999 + maxBand * 0.001
            }
            let norm = 1.0 / max(bandPeak, 0.0001)
            for i in rawBands.indices { rawBands[i] = min(1.4, rawBands[i] * norm) }
            frame.bands = rawBands

            let summary = mapper.summary(from: magnitudes)
            frame.bass = min(1, summary.bass * norm)
            frame.mid = min(1, summary.mid * norm)
            frame.treble = min(1, summary.treble * norm)
            frame.centroid = mapper.centroid(from: magnitudes)
        }

        frame.zeroCrossingRate = AudioAnalyzer.zeroCrossingRate(mono)
        frame.waveform = ring.latest(waveformLength)
        frame.silence = rms < 0.001 ? 1 : 0
        return frame
    }

    private static func zeroCrossingRate(_ samples: [Float]) -> Float {
        guard samples.count > 1 else { return 0 }
        var crossings = 0
        for i in 1..<samples.count {
            if (samples[i] >= 0) != (samples[i - 1] >= 0) { crossings += 1 }
        }
        return Float(crossings) / Float(samples.count)
    }
}
