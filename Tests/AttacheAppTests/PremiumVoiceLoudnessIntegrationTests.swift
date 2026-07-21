import XCTest
import AttacheCore
@testable import AttacheApp

/// Integration test through the synthesizer's injectable native layer: a fake
/// library emits a QUIET take, and the runtime must write a loudness-normalized
/// WAV (near the target, ceiling-bounded) before it is cached. No dylib or weights
/// needed; this proves the normalization is wired into the synthesis path itself,
/// not just available as a pure function.
final class PremiumVoiceLoudnessIntegrationTests: XCTestCase {

    /// Emits a low-level sine so the raw take sits well below the loudness target.
    final class QuietLibrary: PremiumVoiceRuntimeLibrary {
        let amplitude: Float
        let sampleRate = 24_000
        let seconds = 2.0
        init(amplitude: Float) { self.amplitude = amplitude }
        private let handle = OpaquePointer(bitPattern: 0x1234)!

        func create(modelsDir: String, voicesDir: String, tokenizerPath: String, precision: String,
                    temperature: Float, lsdSteps: Int32, numThreads: Int32) -> OpaquePointer? { handle }
        func warmup(_ handle: OpaquePointer) -> Double { 0 }
        func destroy(_ handle: OpaquePointer) {}
        func stream(handle: OpaquePointer, text: String, voice: String, onChunk: (UnsafePointer<Float>, Int) -> Void) throws {
            let count = Int(Double(sampleRate) * seconds)
            let w = 2 * Float.pi * 300 / Float(sampleRate)
            var buf = (0..<count).map { amplitude * sinf(w * Float($0)) }
            buf.withUnsafeBufferPointer { onChunk($0.baseAddress!, $0.count) }
        }
    }

    private func makeValidPaths() throws -> PremiumVoiceRuntimePaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ptt-loud-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let voices = root.appendingPathComponent("voices", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: voices, withIntermediateDirectories: true)
        let tokenizer = models.appendingPathComponent("tokenizer.model")
        try Data("tok".utf8).write(to: tokenizer)
        try Data("wav".utf8).write(to: voices.appendingPathComponent("azelma.wav"))
        return PremiumVoiceRuntimePaths(modelsDirectory: models, voicesDirectory: voices, tokenizerPath: tokenizer)
    }

    private func floatSamples(fromWav data: Data) throws -> [Float] {
        let parsed = try PremiumVoiceWav.parse(data)
        let offset = data.count - parsed.dataByteCount
        return data.withUnsafeBytes { raw -> [Float] in
            let ptr = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: ptr, count: parsed.frameCount))
        }
    }

    func testRuntimeNormalizesQuietTakeBeforeCaching() throws {
        let fake = QuietLibrary(amplitude: 0.05)
        let runtime = AttachePremiumVoiceRuntime(idleUnloadInterval: 1000, libraryFactory: { fake })
        let paths = try makeValidPaths()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("norm-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }

        // The raw take (what the fake emits) is clearly below the loudness target.
        let rawLUFS = SpokenAudioLoudness.integratedLoudness(
            samples: (0..<48_000).map { 0.05 * sinf(2 * Float.pi * 300 / 24_000 * Float($0)) },
            sampleRate: 24_000
        )
        XCTAssertLessThan(rawLUFS, SpokenAudioLoudness.targetLUFS - 3)

        try runtime.synthesize(text: "hello", paths: paths, outputURL: out)

        let samples = try floatSamples(fromWav: try Data(contentsOf: out))
        let wroteLUFS = SpokenAudioLoudness.integratedLoudness(samples: samples, sampleRate: 24_000)
        XCTAssertEqual(wroteLUFS, SpokenAudioLoudness.targetLUFS, accuracy: 1.5,
                       "the cached WAV must be loudness-normalized to the target, not the raw quiet level")

        let ceiling = Float(pow(10.0, SpokenAudioLoudness.truePeakCeilingDBFS / 20.0))
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertLessThanOrEqual(peak, ceiling + 1e-5, "the cached WAV must respect the ceiling")
        XCTAssertLessThan(peak, 1.0)
    }

    func testRuntimeLimitsHotTakeToCeiling() throws {
        // A hot take (near full scale) must be pulled down so the cached WAV never
        // clips.
        let fake = QuietLibrary(amplitude: 0.99)
        let runtime = AttachePremiumVoiceRuntime(idleUnloadInterval: 1000, libraryFactory: { fake })
        let paths = try makeValidPaths()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("hot-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }

        try runtime.synthesize(text: "loud", paths: paths, outputURL: out)

        let samples = try floatSamples(fromWav: try Data(contentsOf: out))
        let ceiling = Float(pow(10.0, SpokenAudioLoudness.truePeakCeilingDBFS / 20.0))
        XCTAssertLessThanOrEqual(samples.reduce(Float(0)) { max($0, abs($1)) }, ceiling + 1e-5)
        let lufs = SpokenAudioLoudness.integratedLoudness(samples: samples, sampleRate: 24_000)
        XCTAssertEqual(lufs, SpokenAudioLoudness.targetLUFS, accuracy: 1.5)
    }
}
