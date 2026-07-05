import AttacheCore
import XCTest

final class AudioAnalyzerTests: XCTestCase {
    func testSilenceProducesNoVisualEnergy() {
        let timeline = AudioTimelineBuilder.analyze(
            samples: [Float](repeating: 0, count: 4_096),
            sampleRate: 48_000
        )

        XCTAssertFalse(timeline.frames.isEmpty)
        XCTAssertEqual(timeline.frames.last?.silence, 1)
        XCTAssertEqual(timeline.frames.last?.rms ?? 1, 0, accuracy: 0.0001)
        XCTAssertEqual(timeline.frames.last?.peak ?? 1, 0, accuracy: 0.0001)
    }

    func testToneProducesDeterministicBands() {
        let sampleRate = 48_000.0
        let samples = (0..<4_096).map { index -> Float in
            Float(sin(2.0 * Double.pi * 440.0 * Double(index) / sampleRate) * 0.8)
        }

        let first = AudioTimelineBuilder.analyze(samples: samples, sampleRate: sampleRate)
        let second = AudioTimelineBuilder.analyze(samples: samples, sampleRate: sampleRate)

        XCTAssertEqual(first.frames, second.frames)
        XCTAssertGreaterThan(first.frames.last?.rms ?? 0, 0.1)
        XCTAssertGreaterThan(first.frames.last?.bands.max() ?? 0, 0.1)
        XCTAssertEqual(first.frames.last?.silence, 0)
    }
}
