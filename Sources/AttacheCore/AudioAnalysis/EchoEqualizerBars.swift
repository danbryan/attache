import Foundation

/// Pure, deterministic mapping from analyzed per-band audio energy to the
/// mirrored equalizer bar heights the full Echo visualizer draws.
///
/// The full-screen Echo presence is a classic symmetric equalizer: the real
/// analyzed audio bands (`VisualizerRenderState.bars`, produced by the playback
/// analyzer) are folded into a left-right mirrored profile and each band is
/// shaped by a fixed response curve into a normalized bar height. Extracting
/// the mapping here keeps it identical every render for the same input, so the
/// visualizer reacts to the actual spoken audio and never to randomness. Given
/// the same energy vector the output is always the same: silence maps to a flat
/// floor, louder bands map to taller bars, and the profile is mirrored around
/// center.
public enum EchoEqualizerBars {
    /// Re-sample `bars` into a left-right mirrored profile. The first source
    /// band sits at the center and the profile tapers symmetrically toward the
    /// edges, so the drawn equalizer reads as a classic mirrored spectrum.
    /// Pure and order-preserving; a vector with two or fewer entries is
    /// returned unchanged (there is nothing to mirror).
    public static func centered(_ bars: [Float]) -> [Float] {
        guard bars.count > 2 else { return bars }

        let lastSourceIndex = Double(bars.count - 1)
        let visualCenter = Double(bars.count - 1) / 2
        let maxDistance = max(1, visualCenter - 0.5)

        return bars.indices.map { index in
            let distance = abs(Double(index) - visualCenter)
            let normalizedDistance = min(1, max(0, (distance - 0.5) / maxDistance))
            return interpolated(in: bars, at: normalizedDistance * lastSourceIndex)
        }
    }

    /// Linear interpolation between adjacent source bands at a fractional
    /// position, clamped to the array bounds.
    static func interpolated(in bars: [Float], at position: Double) -> Float {
        guard !bars.isEmpty else { return 0 }
        let lower = max(0, min(bars.count - 1, Int(position.rounded(.down))))
        let upper = max(0, min(bars.count - 1, lower + 1))
        let fraction = Float(position - Double(lower))
        return bars[lower] + (bars[upper] - bars[lower]) * fraction
    }

    /// The fixed response curve applied to one band's analyzed energy: a gentle
    /// gamma lift so quiet detail is visible, scaled by the caller's intensity
    /// and clamped to a full-height ceiling. Monotonic in `raw`, and silence
    /// (`raw == 0`) always maps to `0`.
    public static func normalizedHeight(forEnergy raw: Float, intensity: Double = 1) -> Double {
        let energy = pow(max(0, Double(raw)), 0.55) * 2.4 * intensity
        return min(1, max(0, energy))
    }

    /// The full mapping the visualizer draws: mirror the analyzed bands (unless
    /// the caller asked for the raw left-to-right spectrum) and shape each into
    /// a normalized `0...1` bar height. Deterministic for a given input.
    public static func barHeights(
        from bars: [Float],
        intensity: Double = 1,
        mirrored: Bool = true
    ) -> [Double] {
        let source = mirrored ? centered(bars) : bars
        return source.map { normalizedHeight(forEnergy: $0, intensity: intensity) }
    }

    /// The same real mirrored equalizer mapping, resampled to exactly `count`
    /// bars. The compact Echo presence and the character mouths draw fewer bars
    /// than the full-screen native spectrum, but through THIS single mapping, so
    /// every surface reacts to the same analyzed audio identically: the center
    /// bar carries the lowest source band, the profile tapers symmetrically to
    /// the treble edges, and each band is shaped by the shared response curve.
    /// Deterministic. An empty source (no audio) or an all-zero source (silence)
    /// yields a flat floor of zeros, so a resting mouth or Echo never shows
    /// invented motion.
    public static func barHeights(
        from bars: [Float],
        count: Int,
        intensity: Double = 1
    ) -> [Double] {
        guard count > 0 else { return [] }
        guard !bars.isEmpty else { return [Double](repeating: 0, count: count) }

        let lastSourceIndex = Double(bars.count - 1)
        let visualCenter = Double(count - 1) / 2
        let maxDistance = max(1, visualCenter - 0.5)

        return (0..<count).map { index in
            let distance = abs(Double(index) - visualCenter)
            let normalizedDistance = min(1, max(0, (distance - 0.5) / maxDistance))
            let raw = interpolated(in: bars, at: normalizedDistance * lastSourceIndex)
            return normalizedHeight(forEnergy: raw, intensity: intensity)
        }
    }

    /// Echo's at-rest waveform, drawn only when NO audio is playing so the
    /// compact presence stays visibly alive without inventing motion: a static,
    /// gentle symmetric arch (deterministic, clock-free). The moment audio
    /// arrives the real spectrum takes over; while audio is playing but silent,
    /// the real all-zero spectrum flattens the bars instead of this arch.
    public static func restingProfile(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [0.16] }
        let last = Double(count - 1)
        return (0..<count).map { index in
            // A low, single-humped arch peaking at center; never a flat line so
            // Echo reads as a resting equalizer, never taller than a quiet band.
            0.16 + 0.20 * sin(Double.pi * Double(index) / last)
        }
    }
}

/// The illustrated character mouths (robot Attaché, cowboy Colt) draw a small
/// equalizer inside the mouth slot while speaking. It uses fewer bands than the
/// full-screen spectrum so the bars read cleanly at mouth size, but folds the
/// real analyzed audio through the SAME `EchoEqualizerBars` mapping, so the
/// mouth reacts to the actual spoken spectrum exactly as the full equalizer
/// does. Pure and deterministic; the draw site multiplies these shapes by the
/// mouth's loudness envelope (`mouthOpen`).
public enum EchoCharacterMouth {
    /// Five mirrored bands read cleanly in the mouth slot: enough to show a
    /// real spectrum shape, few enough not to blur at mouth size.
    public static let bandCount = 5

    /// The fixed symmetric rest shape used when no analyzed spectrum is
    /// available (for example a paused frame that carries no live bands),
    /// scaled by the loudness envelope at the draw site. Deterministic and
    /// clock-free, so a held mouth never animates on its own.
    public static let restShape: [Double] = [0.6, 0.85, 1.0, 0.85, 0.6]

    /// Per-band multipliers (0...1) shaping the mouth bars: the real mirrored
    /// spectrum when audio is present, else the fixed rest shape. A quiet floor
    /// keeps the bars reading as an equalizer even on near-silent bands. The
    /// draw site multiplies these by `mouthOpen`, so true silence (mouth below
    /// the neutral threshold) never reaches here and the resting geometry is
    /// preserved.
    public static func bandShapes(from bars: [Float]) -> [Double] {
        guard !bars.isEmpty else { return restShape }
        let spectrum = EchoEqualizerBars.barHeights(from: bars, count: bandCount)
        return spectrum.map { 0.4 + 0.6 * $0 }
    }
}
