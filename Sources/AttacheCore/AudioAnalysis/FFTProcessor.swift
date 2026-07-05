import Accelerate

final class FFTProcessor {
    let size: Int
    private let halfSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var realParts: [Float]
    private var imagParts: [Float]
    private var magnitudeScratch: [Float]

    init(size: Int = 1_024) {
        self.size = size
        self.halfSize = size / 2
        self.log2n = vDSP_Length(log2(Double(size)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("Failed to allocate the FFT setup for size \(size); the size must be a power of two.")
        }
        self.setup = setup
        self.window = [Float](repeating: 0, count: size)
        self.windowed = [Float](repeating: 0, count: size)
        self.realParts = [Float](repeating: 0, count: size / 2)
        self.imagParts = [Float](repeating: 0, count: size / 2)
        self.magnitudeScratch = [Float](repeating: 0, count: size / 2)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Returns the half-spectrum magnitudes. The returned array is a reused
    /// scratch buffer valid only until the next call; callers consume it
    /// immediately (the analyzer reads it to build one frame) and never retain it.
    func magnitudes(_ samples: [Float]) -> [Float] {
        guard samples.count >= size else { return [] }

        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(size))

        realParts.withUnsafeMutableBufferPointer { realBuffer in
            imagParts.withUnsafeMutableBufferPointer { imagBuffer in
                var split = DSPSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imagBuffer.baseAddress!
                )
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudeScratch, 1, vDSP_Length(halfSize))
            }
        }

        var scale = Float(1.0 / Float(size))
        vDSP_vsmul(magnitudeScratch, 1, &scale, &magnitudeScratch, 1, vDSP_Length(halfSize))
        return magnitudeScratch
    }
}
