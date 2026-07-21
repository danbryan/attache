import Foundation

/// Loudness normalization for Attaché's spoken audio, so every voice engine sits
/// at one standard loudness and the OS volume is the only volume control. The
/// on-device Attaché Premium voice (pocket-tts, 24 kHz mono float) synthesizes
/// noticeably quieter than mastered media at the same system volume; this brings
/// each take up (or down) to a broadcast-style speech target with a true-peak
/// ceiling so nothing clips.
///
/// Pure and unit-tested in Core (no audio framework, no I/O): the integrated
/// loudness is measured per ITU-R BS.1770 (K-weighting plus the two-stage
/// gating), the gain is the difference to the target, capped so a silent or
/// broken take is never amplified into noise, and a final true-peak limiter
/// scales the whole take so no sample (and no reconstructed inter-sample peak)
/// exceeds the ceiling.
public enum SpokenAudioLoudness {

    /// Broadcast-style integrated loudness target for speech. Streaming/broadcast
    /// specs cluster at -16 LUFS (podcast/AES) to -23 LUFS (EBU R128); -16 keeps
    /// speech present against mastered media without pumping.
    public static let targetLUFS: Double = -16.0

    /// True-peak ceiling. -1.5 dBTP leaves headroom for inter-sample overshoot on
    /// D/A reconstruction and for lossy re-encode, so the take never clips.
    public static let truePeakCeilingDBFS: Double = -1.5

    /// Maximum boost applied. A silent or near-silent take measures extremely low;
    /// without a cap its computed gain would be enormous and would amplify the
    /// noise floor into audible hiss. +20 dB covers a genuinely quiet-but-valid
    /// take while refusing to chase silence.
    public static let maxGainDB: Double = 20.0

    /// When the measured loudness is already within this of the target, leave the
    /// samples untouched (identity), so a correctly leveled take is a no-op.
    public static let noOpToleranceDB: Double = 1.0

    /// Below this integrated loudness the take is treated as effectively silent and
    /// returned unchanged, so pure silence stays silence and a broken empty take is
    /// not amplified. Matches BS.1770's absolute gate threshold.
    public static let silenceFloorLUFS: Double = -70.0

    // MARK: - Measurement

    public struct Measurement: Equatable, Sendable {
        /// Gated integrated loudness in LUFS. `-.infinity` for digital silence.
        public let integratedLUFS: Double
        /// Estimated true peak in dBFS (4x oversampled). `-.infinity` for silence.
        public let truePeakDBFS: Double
        /// Absolute sample peak (linear, 0...∞).
        public let samplePeak: Float

        public init(integratedLUFS: Double, truePeakDBFS: Double, samplePeak: Float) {
            self.integratedLUFS = integratedLUFS
            self.truePeakDBFS = truePeakDBFS
            self.samplePeak = samplePeak
        }
    }

    public static func measure(samples: [Float], sampleRate: Int) -> Measurement {
        let lufs = integratedLoudness(samples: samples, sampleRate: sampleRate)
        let truePeak = truePeakLinear(samples: samples)
        let samplePeak = samples.reduce(Float(0)) { max($0, abs($1)) }
        return Measurement(
            integratedLUFS: lufs,
            truePeakDBFS: truePeak > 0 ? 20 * log10(Double(truePeak)) : -.infinity,
            samplePeak: samplePeak
        )
    }

    // MARK: - Normalization

    /// Bring `samples` to the loudness target with a true-peak ceiling. Returns the
    /// input unchanged for silence, a broken/empty take, or a take already within
    /// `noOpToleranceDB` of the target whose peaks are already under the ceiling.
    /// Never changes the sample count.
    ///
    /// A single loudness gain would push a peaky (high crest factor) take's peaks
    /// well over the ceiling; scaling the whole take back down to fit the ceiling
    /// (a global limiter) would then leave loudness several dB under target and
    /// inconsistent across takes. Instead the loudness gain lands the bulk at
    /// target and a look-ahead peak limiter shaves only the transient peaks, so
    /// loudness stays near target AND the ceiling holds, with no waveshaping
    /// distortion of the voice.
    public static func normalize(samples: [Float], sampleRate: Int) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0 else { return samples }

        let lufs = integratedLoudness(samples: samples, sampleRate: sampleRate)

        // Silence / broken take: never amplify a noise floor into hiss.
        guard lufs.isFinite, lufs > silenceFloorLUFS else { return samples }

        let rawGainDB = targetLUFS - lufs
        // Attenuation is unbounded (a hot take is pulled down); boosting is capped
        // so a near-silent take is not blown up into audible noise.
        let gainDB = min(rawGainDB, maxGainDB)

        let gained: [Float]
        if abs(gainDB) <= noOpToleranceDB {
            // Already correctly leveled; skip the gain but still enforce the ceiling.
            gained = samples
        } else {
            let gain = Float(pow(10.0, gainDB / 20.0))
            gained = samples.map { $0 * gain }
        }

        let ceiling = Float(pow(10.0, truePeakCeilingDBFS / 20.0))
        return peakLimit(gained, ceiling: ceiling, sampleRate: sampleRate)
    }

    /// Look-ahead peak limiter: attenuates only the samples in the neighborhood of a
    /// peak that would exceed `ceiling`, leaving the rest of the take at full
    /// loudness. Guarantees every output sample satisfies `|y| <= ceiling` (the
    /// per-sample gain is a moving minimum that includes each peak, so the limit is
    /// mathematically enforced, not just clipped). Distortion-free: the gain is a
    /// smoothly time-varying envelope, not a waveshaper. Returns the input array
    /// unchanged when nothing exceeds the ceiling.
    static func peakLimit(_ x: [Float], ceiling: Float, sampleRate: Int) -> [Float] {
        guard !x.isEmpty, ceiling > 0 else { return x }
        let samplePeak = x.reduce(Float(0)) { max($0, abs($1)) }
        if samplePeak <= ceiling { return x }

        // Instantaneous gain needed to hold each sample at the ceiling.
        var gain = x.map { v -> Float in
            let a = abs(v)
            return a > ceiling ? ceiling / a : 1
        }

        // Attack window (~1.5 ms): a moving minimum with look-ahead and look-back,
        // so the gain is already pulled down as a peak arrives rather than snapping
        // at the peak edge (which would add a click). The window includes each
        // sample, so gain[n] <= ceiling/|x[n]| at every peak: the ceiling holds.
        let attack = max(1, Int((0.0015 * Double(sampleRate)).rounded()))
        gain = movingMinimum(gain, radius: attack)

        // Release (~80 ms): let the gain recover gently after a peak. Attack is
        // instant (gain drops immediately); release rises via a one-pole and is
        // clamped to never exceed the moving-minimum requirement, so the guarantee
        // is preserved.
        let releaseCoef = Float(exp(-1.0 / (0.08 * Double(sampleRate))))
        var env: Float = 1
        var out = x
        for n in 0..<x.count {
            let g = gain[n]
            if g < env {
                env = g // instant attack
            } else {
                env = releaseCoef * env + (1 - releaseCoef) * g // gentle release
            }
            let applied = min(g, env)
            out[n] = x[n] * applied
        }
        return out
    }

    /// Moving minimum over a centered window of the given radius (naive; the window
    /// is a few dozen samples).
    private static func movingMinimum(_ x: [Float], radius: Int) -> [Float] {
        guard radius > 0 else { return x }
        var out = x
        let n = x.count
        for i in 0..<n {
            let lo = max(0, i - radius)
            let hi = min(n - 1, i + radius)
            var m = x[lo]
            var j = lo + 1
            while j <= hi { m = min(m, x[j]); j += 1 }
            out[i] = m
        }
        return out
    }

    // MARK: - ITU-R BS.1770 integrated loudness (mono)

    /// Gated integrated loudness in LUFS. `-.infinity` when the signal is digital
    /// silence or too short to form a single 400 ms block.
    public static func integratedLoudness(samples: [Float], sampleRate: Int) -> Double {
        guard sampleRate > 0, !samples.isEmpty else { return -.infinity }

        // K-weighting: stage 1 high-shelf pre-filter, stage 2 RLB high-pass.
        // Coefficients are derived analytically for the actual sample rate (the
        // standard tabulates 48 kHz only), following pyloudnorm's approach.
        let stage1 = highShelfCoefficients(sampleRate: sampleRate)
        let stage2 = highPassCoefficients(sampleRate: sampleRate)
        let weighted = biquad(biquad(samples.map { Double($0) }, stage1), stage2)

        // 400 ms blocks, 75% overlap (100 ms hop).
        let blockSize = Int((0.4 * Double(sampleRate)).rounded())
        let hop = max(1, Int((0.1 * Double(sampleRate)).rounded()))
        guard weighted.count >= blockSize, blockSize > 0 else { return -.infinity }

        var blockMeanSquares: [Double] = []
        var start = 0
        while start + blockSize <= weighted.count {
            var sum = 0.0
            for i in start..<(start + blockSize) { sum += weighted[i] * weighted[i] }
            blockMeanSquares.append(sum / Double(blockSize))
            start += hop
        }
        guard !blockMeanSquares.isEmpty else { return -.infinity }

        // Block loudness (G = 1 for mono).
        func loudness(_ meanSquare: Double) -> Double {
            meanSquare > 0 ? -0.691 + 10 * log10(meanSquare) : -.infinity
        }

        // Absolute gate at -70 LUFS.
        let absoluteGated = blockMeanSquares.filter { loudness($0) >= -70.0 }
        guard !absoluteGated.isEmpty else { return -.infinity }

        // Relative gate: mean of absolute-gated blocks, minus 10 LU.
        let absMean = absoluteGated.reduce(0, +) / Double(absoluteGated.count)
        let relativeThreshold = loudness(absMean) - 10.0
        let relativeGated = absoluteGated.filter { loudness($0) >= relativeThreshold }
        let gated = relativeGated.isEmpty ? absoluteGated : relativeGated

        let mean = gated.reduce(0, +) / Double(gated.count)
        return loudness(mean)
    }

    // MARK: - True peak (4x oversample)

    /// Estimated true peak (linear) via 4x polyphase oversampling with a
    /// Hann-windowed sinc, so inter-sample overshoot is caught rather than only the
    /// raw sample peak. Returns the raw sample peak when the signal is too short to
    /// oversample.
    public static func truePeakLinear(samples: [Float]) -> Float {
        let samplePeak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard samples.count >= Self.oversampleTapsPerPhase else { return samplePeak }

        let factor = Self.oversampleFactor
        let tapsPerPhase = Self.oversampleTapsPerPhase
        let half = tapsPerPhase / 2
        var peak = samplePeak
        // For each input position, evaluate the interpolated sub-samples between it
        // and the next input sample using the per-phase FIR kernels.
        for phase in 1..<factor {
            let kernel = Self.polyphaseKernels[phase]
            for n in 0..<samples.count {
                var acc: Float = 0
                for k in 0..<tapsPerPhase {
                    let idx = n + k - half + 1
                    if idx >= 0, idx < samples.count {
                        acc += samples[idx] * kernel[k]
                    }
                }
                peak = max(peak, abs(acc))
            }
        }
        return peak
    }

    // MARK: - Biquad filtering (Direct Form I, transposed-safe scalar)

    private struct Biquad { let b0, b1, b2, a1, a2: Double }

    private static func biquad(_ x: [Double], _ c: Biquad) -> [Double] {
        var y = [Double](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for n in 0..<x.count {
            let x0 = x[n]
            let out = c.b0 * x0 + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
            y[n] = out
            x2 = x1; x1 = x0
            y2 = y1; y1 = out
        }
        return y
    }

    /// Stage 1 K-weighting high-shelf pre-filter (fc/Q/gain per pyloudnorm).
    private static func highShelfCoefficients(sampleRate: Int) -> Biquad {
        let db = 3.999843853973347
        let q = 0.7071752369554196
        let fc = 1681.9744509555319
        let A = pow(10.0, db / 40.0)
        let w0 = 2.0 * Double.pi * (fc / Double(sampleRate))
        let alpha = sin(w0) / (2.0 * q)
        let cosw = cos(w0)
        let sqrtA = A.squareRoot()
        let b0 = A * ((A + 1) + (A - 1) * cosw + 2 * sqrtA * alpha)
        let b1 = -2 * A * ((A - 1) + (A + 1) * cosw)
        let b2 = A * ((A + 1) + (A - 1) * cosw - 2 * sqrtA * alpha)
        let a0 = (A + 1) - (A - 1) * cosw + 2 * sqrtA * alpha
        let a1 = 2 * ((A - 1) - (A + 1) * cosw)
        let a2 = (A + 1) - (A - 1) * cosw - 2 * sqrtA * alpha
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// Stage 2 K-weighting RLB high-pass (fc/Q per pyloudnorm).
    private static func highPassCoefficients(sampleRate: Int) -> Biquad {
        let q = 0.5003270373238773
        let fc = 38.13547087602444
        let w0 = 2.0 * Double.pi * (fc / Double(sampleRate))
        let alpha = sin(w0) / (2.0 * q)
        let cosw = cos(w0)
        let b0 = (1 + cosw) / 2
        let b1 = -(1 + cosw)
        let b2 = (1 + cosw) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosw
        let a2 = 1 - alpha
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    // MARK: - Oversampling kernels

    private static let oversampleFactor = 4
    private static let oversampleTapsPerPhase = 12

    /// Per-phase Hann-windowed sinc kernels for `oversampleFactor` upsampling.
    /// Phase 0 is the identity (the input sample itself) and is unused by the peak
    /// scan; phases 1...factor-1 evaluate the interpolated sub-samples.
    private static let polyphaseKernels: [[Float]] = {
        let factor = oversampleFactor
        let taps = oversampleTapsPerPhase
        let half = taps / 2
        var kernels: [[Float]] = []
        for phase in 0..<factor {
            let frac = Double(phase) / Double(factor)
            var kernel = [Float](repeating: 0, count: taps)
            var sum = 0.0
            for k in 0..<taps {
                // Sample offset of tap k relative to the interpolation point.
                let t = Double(k - half + 1) - frac
                let sincVal: Double
                if abs(t) < 1e-9 {
                    sincVal = 1.0
                } else {
                    let x = Double.pi * t
                    sincVal = sin(x) / x
                }
                // Hann window across the tap span.
                let window = 0.5 - 0.5 * cos(2.0 * Double.pi * (Double(k) + 0.5) / Double(taps))
                let coeff = sincVal * window
                kernel[k] = Float(coeff)
                sum += coeff
            }
            // Normalize to unity DC gain so interpolated amplitude is unbiased.
            if sum != 0 {
                for k in 0..<taps { kernel[k] = Float(Double(kernel[k]) / sum) }
            }
            kernels.append(kernel)
        }
        return kernels
    }()
}
