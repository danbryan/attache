import XCTest
@testable import AttacheCore

final class EchoEqualizerBarsTests: XCTestCase {
    // Silence must draw a flat floor: every band at zero energy maps to a zero
    // bar height, so the full Echo equalizer rests instead of showing noise.
    func testSilenceMapsToFlatFloor() {
        let silent = [Float](repeating: 0, count: 56)
        let heights = EchoEqualizerBars.barHeights(from: silent)
        XCTAssertEqual(heights.count, 56)
        XCTAssertTrue(heights.allSatisfy { $0 == 0 }, "silence must be flat")
    }

    // The response curve is deterministic and hits its known anchors: zero maps
    // to zero, and a full band saturates to 1 at unit intensity.
    func testNormalizedHeightAnchors() {
        XCTAssertEqual(EchoEqualizerBars.normalizedHeight(forEnergy: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(EchoEqualizerBars.normalizedHeight(forEnergy: 1), 1, accuracy: 1e-9)
        // A quiet band is lifted by the gamma curve but stays below full.
        let quiet = EchoEqualizerBars.normalizedHeight(forEnergy: 0.1)
        XCTAssertGreaterThan(quiet, 0)
        XCTAssertLessThan(quiet, 1)
        // Recompute through the same Float rounding the function sees, so this
        // stays an exact contract check rather than a Float/Double artifact.
        XCTAssertEqual(quiet, min(1, pow(Double(Float(0.1)), 0.55) * 2.4), accuracy: 1e-9)
    }

    // Louder energy never produces a shorter bar: the mapping is monotonic, so
    // the equalizer tracks the actual audio level.
    func testResponseIsMonotonic() {
        var previous = -1.0
        for step in 0...100 {
            let raw = Float(step) / 100
            let height = EchoEqualizerBars.normalizedHeight(forEnergy: raw)
            XCTAssertGreaterThanOrEqual(height, previous, "height must not decrease as energy rises")
            previous = height
        }
    }

    // Intensity scales the curve monotonically without breaking the ceiling.
    func testIntensityScalesWithoutExceedingCeiling() {
        let low = EchoEqualizerBars.normalizedHeight(forEnergy: 0.2, intensity: 0.5)
        let high = EchoEqualizerBars.normalizedHeight(forEnergy: 0.2, intensity: 2.0)
        XCTAssertGreaterThan(high, low)
        XCTAssertLessThanOrEqual(high, 1)
        XCTAssertLessThanOrEqual(EchoEqualizerBars.normalizedHeight(forEnergy: 1, intensity: 10), 1)
    }

    // The centered profile is a true mirror around its middle for any input, so
    // the equalizer reads as a symmetric spectrum.
    func testCenteredProfileIsMirrored() {
        let input: [Float] = [0.05, 0.2, 0.35, 0.5, 0.65, 0.8, 0.95]
        let centered = EchoEqualizerBars.centered(input)
        XCTAssertEqual(centered.count, input.count)
        for index in centered.indices {
            XCTAssertEqual(
                centered[index],
                centered[centered.count - 1 - index],
                accuracy: 1e-6,
                "profile must mirror around center at index \(index)"
            )
        }
    }

    // A fixed vector locks the exact mirrored mapping so the equalizer is
    // reproducible: the first source band lands at the center, the last at the
    // edges, adjacent bands interpolate.
    func testCenteredMappingIsDeterministicForKnownVector() {
        let input: [Float] = [0, 0.25, 0.5, 0.75, 1.0]
        let centered = EchoEqualizerBars.centered(input)
        let expected: [Float] = [1.0, 1.0 / 3.0, 0.0, 1.0 / 3.0, 1.0]
        XCTAssertEqual(centered.count, expected.count)
        for index in centered.indices {
            XCTAssertEqual(centered[index], expected[index], accuracy: 1e-5)
        }
    }

    // Same input, same output: the mapping carries no hidden state or
    // randomness, so a repeated render draws identical bars.
    func testMappingIsPureAndRepeatable() {
        let input: [Float] = (0..<56).map { Float(($0 * 37) % 100) / 100 }
        let first = EchoEqualizerBars.barHeights(from: input, intensity: 1.0)
        let second = EchoEqualizerBars.barHeights(from: input, intensity: 1.0)
        XCTAssertEqual(first, second)
    }

    // Degenerate short inputs pass through unchanged (nothing to mirror).
    func testShortVectorsPassThrough() {
        XCTAssertEqual(EchoEqualizerBars.centered([]), [])
        XCTAssertEqual(EchoEqualizerBars.centered([0.5]), [0.5])
        XCTAssertEqual(EchoEqualizerBars.centered([0.5, 0.9]), [0.5, 0.9])
    }

    // The energy the playback analyzer publishes on VisualizerRenderState is
    // what feeds the visualizer: apply a real analyzed frame and the equalizer
    // mapping produces nonzero bars, proving the publisher drives the drawing.
    func testPublishedRenderStateEnergyFeedsTheEqualizer() {
        var state = VisualizerRenderState()
        var frame = AnalysisFrame()
        frame.bands = (0..<56).map { _ in Float(0.6) }
        frame.rms = 0.5
        // Envelope followers need a few applications to open up.
        for _ in 0..<12 { state.apply(frame) }

        XCTAssertFalse(state.bars.isEmpty, "analyzer must publish bands")
        XCTAssertGreaterThan(state.bars.max() ?? 0, 0, "published energy must be nonzero")

        let heights = EchoEqualizerBars.barHeights(from: state.bars, intensity: 1.0)
        XCTAssertEqual(heights.count, state.bars.count)
        XCTAssertGreaterThan(heights.max() ?? 0, 0, "the equalizer must react to published energy")
    }
}
