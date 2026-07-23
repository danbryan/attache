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
}
