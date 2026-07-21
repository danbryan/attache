import XCTest
@testable import AttacheCore

/// Unit tests for the pure spoken-audio loudness normalizer: quiet input is
/// brought up to the target, loud input is pulled down, the true-peak ceiling is
/// enforced, the boost is capped, an already-leveled take is a no-op, and silence
/// stays silence.
final class SpokenAudioLoudnessTests: XCTestCase {

    private let sampleRate = 24_000
    private var ceilingLinear: Float { Float(pow(10.0, SpokenAudioLoudness.truePeakCeilingDBFS / 20.0)) }

    /// A `seconds`-long sine of the given linear amplitude at `sampleRate`.
    private func sine(amplitude: Float, seconds: Double = 2.0, frequency: Float = 300) -> [Float] {
        let count = Int(Double(sampleRate) * seconds)
        let w = 2 * Float.pi * frequency / Float(sampleRate)
        return (0..<count).map { amplitude * sinf(w * Float($0)) }
    }

    func testQuietInputIsBroughtUpToTarget() {
        let input = sine(amplitude: 0.05)
        let before = SpokenAudioLoudness.integratedLoudness(samples: input, sampleRate: sampleRate)
        XCTAssertLessThan(before, SpokenAudioLoudness.targetLUFS - 3, "test input must start clearly below target")

        let out = SpokenAudioLoudness.normalize(samples: input, sampleRate: sampleRate)
        let after = SpokenAudioLoudness.integratedLoudness(samples: out, sampleRate: sampleRate)
        XCTAssertEqual(out.count, input.count)
        XCTAssertEqual(after, SpokenAudioLoudness.targetLUFS, accuracy: 1.5, "quiet input should land near the target")
        XCTAssertGreaterThan(after, before)
    }

    func testLoudInputIsAttenuatedToTarget() {
        let input = sine(amplitude: 0.9)
        let before = SpokenAudioLoudness.integratedLoudness(samples: input, sampleRate: sampleRate)
        XCTAssertGreaterThan(before, SpokenAudioLoudness.targetLUFS + 3, "test input must start clearly above target")

        let out = SpokenAudioLoudness.normalize(samples: input, sampleRate: sampleRate)
        let after = SpokenAudioLoudness.integratedLoudness(samples: out, sampleRate: sampleRate)
        XCTAssertEqual(after, SpokenAudioLoudness.targetLUFS, accuracy: 1.5, "loud input should land near the target")
        XCTAssertLessThan(after, before)
    }

    func testTruePeakCeilingIsEnforced() {
        // Low average level (so a boost is applied) with sparse near-full-scale
        // spikes (high crest), so a plain gain would push peaks well over the
        // ceiling and the limiter must catch them.
        var input = sine(amplitude: 0.08)
        for i in stride(from: 500, to: input.count, by: 4000) {
            input[i] = 0.98
            input[i + 1] = -0.97
        }
        let out = SpokenAudioLoudness.normalize(samples: input, sampleRate: sampleRate)

        let samplePeak = out.reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertLessThanOrEqual(samplePeak, ceilingLinear + 1e-5, "no sample may exceed the ceiling")
        XCTAssertLessThan(samplePeak, 1.0, "no sample may sit at full scale")
        // The oversampled true peak stays close to the ceiling (a little inter-sample
        // overshoot is allowed, but well below 0 dBFS / clipping).
        let truePeak = SpokenAudioLoudness.truePeakLinear(samples: out)
        XCTAssertLessThan(truePeak, 1.0, "reconstructed peak must not clip")
    }

    func testBoostIsCappedForNearSilentInput() {
        // Very quiet but above the silence floor: the raw gain to target exceeds the
        // cap, so exactly the cap is applied (target is NOT reached).
        let input = sine(amplitude: 0.002)
        let before = SpokenAudioLoudness.integratedLoudness(samples: input, sampleRate: sampleRate)
        XCTAssertGreaterThan(before, SpokenAudioLoudness.silenceFloorLUFS)
        XCTAssertLessThan(before, SpokenAudioLoudness.targetLUFS - SpokenAudioLoudness.maxGainDB - 2,
                          "input must be quiet enough that the cap binds")

        let out = SpokenAudioLoudness.normalize(samples: input, sampleRate: sampleRate)
        // The peaks are tiny, so the limiter is a no-op and the applied gain is
        // exactly the cap. Measure it from a representative non-zero sample.
        let idx = (0..<out.count).max(by: { abs(input[$0]) < abs(input[$1]) })!
        let appliedGain = out[idx] / input[idx]
        XCTAssertEqual(appliedGain, Float(pow(10.0, SpokenAudioLoudness.maxGainDB / 20.0)), accuracy: 0.01,
                       "a near-silent take must be boosted by exactly the cap, not chased to target")
        let after = SpokenAudioLoudness.integratedLoudness(samples: out, sampleRate: sampleRate)
        XCTAssertEqual(after, before + SpokenAudioLoudness.maxGainDB, accuracy: 0.5)
        XCTAssertLessThan(after, SpokenAudioLoudness.targetLUFS - 3, "capped boost must not reach target")
    }

    func testAlreadyLeveledInputIsNoOp() {
        // Build a take already at the target with peaks under the ceiling by
        // pre-scaling a sine to exactly the target loudness.
        let base = sine(amplitude: 0.2)
        let lufs = SpokenAudioLoudness.integratedLoudness(samples: base, sampleRate: sampleRate)
        let gain = Float(pow(10.0, (SpokenAudioLoudness.targetLUFS - lufs) / 20.0))
        let atTarget = base.map { $0 * gain }
        XCTAssertLessThan(atTarget.reduce(Float(0)) { max($0, abs($1)) }, ceilingLinear,
                          "a target-level sine peaks below the ceiling")

        let out = SpokenAudioLoudness.normalize(samples: atTarget, sampleRate: sampleRate)
        XCTAssertEqual(out, atTarget, "a correctly leveled take must be returned unchanged")
    }

    func testSilenceStaysSilence() {
        let silence = [Float](repeating: 0, count: sampleRate)
        XCTAssertEqual(SpokenAudioLoudness.normalize(samples: silence, sampleRate: sampleRate), silence)

        // Sub-floor noise is treated as silence too (never amplified into hiss).
        let nearSilent = sine(amplitude: 1e-6)
        XCTAssertEqual(SpokenAudioLoudness.normalize(samples: nearSilent, sampleRate: sampleRate), nearSilent)
    }

    func testEmptyInputIsUnchanged() {
        XCTAssertEqual(SpokenAudioLoudness.normalize(samples: [], sampleRate: sampleRate), [])
    }

    func testPeakLimiterGuaranteesCeilingAndNoOpsWhenUnderIt() {
        let ceiling: Float = 0.5
        // Under the ceiling: identity.
        let quiet = sine(amplitude: 0.3)
        XCTAssertEqual(SpokenAudioLoudness.peakLimit(quiet, ceiling: ceiling, sampleRate: sampleRate), quiet)
        // Over the ceiling: every sample is held at or below it.
        let hot = sine(amplitude: 0.9)
        let limited = SpokenAudioLoudness.peakLimit(hot, ceiling: ceiling, sampleRate: sampleRate)
        XCTAssertLessThanOrEqual(limited.reduce(Float(0)) { max($0, abs($1)) }, ceiling + 1e-6)
    }

    func testTruePeakIsAtLeastSamplePeak() {
        let s = sine(amplitude: 0.7, frequency: 11_000) // near Nyquist: inter-sample overshoot
        let samplePeak = s.reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertGreaterThanOrEqual(SpokenAudioLoudness.truePeakLinear(samples: s), samplePeak)
    }
}
