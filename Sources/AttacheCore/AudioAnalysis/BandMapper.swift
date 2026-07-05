import Foundation

struct BandMapper {
    let bandCount: Int
    private let fftSize: Int
    private let sampleRate: Double
    private let binCount: Int
    private let bandRanges: [(start: Int, end: Int)]

    init(bandCount: Int, fftSize: Int, sampleRate: Double) {
        self.bandCount = bandCount
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.binCount = fftSize / 2

        let minFreq = 40.0
        let maxFreq = min(16_000.0, sampleRate / 2)
        var ranges: [(start: Int, end: Int)] = []
        for band in 0..<bandCount {
            let f0 = minFreq * pow(maxFreq / minFreq, Double(band) / Double(bandCount))
            let f1 = minFreq * pow(maxFreq / minFreq, Double(band + 1) / Double(bandCount))
            let bin0 = max(1, Int(f0 / sampleRate * Double(fftSize)))
            let bin1 = max(bin0 + 1, min(binCount, Int(f1 / sampleRate * Double(fftSize))))
            ranges.append((bin0, bin1))
        }
        self.bandRanges = ranges
    }

    func bands(from magnitudes: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: bandCount)
        guard magnitudes.count >= binCount else { return output }
        for (index, range) in bandRanges.enumerated() {
            guard range.start < range.end, range.end <= magnitudes.count else { continue }
            var sum: Float = 0
            for bin in range.start..<range.end { sum += magnitudes[bin] }
            output[index] = sum / Float(range.end - range.start)
        }
        return output
    }

    func summary(from magnitudes: [Float]) -> (bass: Float, mid: Float, treble: Float) {
        (bass: energy(magnitudes, fromHz: 40, toHz: 250),
         mid: energy(magnitudes, fromHz: 250, toHz: 2_000),
         treble: energy(magnitudes, fromHz: 2_000, toHz: 16_000))
    }

    func centroid(from magnitudes: [Float]) -> Float {
        guard magnitudes.count >= binCount else { return 0 }
        var weighted = 0.0
        var total = 0.0
        for bin in 1..<binCount {
            let frequency = Double(bin) / Double(fftSize) * sampleRate
            let magnitude = Double(magnitudes[bin])
            weighted += frequency * magnitude
            total += magnitude
        }
        guard total > 0 else { return 0 }
        return Float(min(1, (weighted / total) / (sampleRate / 2)))
    }

    private func energy(_ magnitudes: [Float], fromHz lowHz: Double, toHz highHz: Double) -> Float {
        let lowBin = max(1, Int(lowHz / sampleRate * Double(fftSize)))
        let highBin = min(binCount, Int(highHz / sampleRate * Double(fftSize)))
        guard lowBin < highBin, highBin <= magnitudes.count else { return 0 }
        var sum: Float = 0
        for bin in lowBin..<highBin { sum += magnitudes[bin] }
        return sum / Float(highBin - lowBin)
    }
}
