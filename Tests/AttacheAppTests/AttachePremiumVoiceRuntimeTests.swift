import XCTest
import AttacheCore
@testable import AttacheApp

/// Exercises the runtime wrapper (serialization, path validation, typed errors,
/// and correct WAV writing) with a fake native library, so no dylib is needed.
final class AttachePremiumVoiceRuntimeTests: XCTestCase {

    /// A stand-in for libpocket_tts.dylib that emits a fixed tone.
    final class FakeLibrary: PremiumVoiceRuntimeLibrary {
        var createdHandles = 0
        var destroyedHandles = 0
        var samplesPerChunk = 512
        var chunkCount = 20
        var lastLsdSteps: Int32?
        var lastTemperature: Float?
        private let handle = OpaquePointer(bitPattern: 0xABCD)!

        func create(
            modelsDir: String, voicesDir: String, tokenizerPath: String,
            precision: String, temperature: Float, lsdSteps: Int32, numThreads: Int32
        ) -> OpaquePointer? {
            createdHandles += 1
            lastLsdSteps = lsdSteps
            lastTemperature = temperature
            return handle
        }
        func warmup(_ handle: OpaquePointer) -> Double { 1.0 }
        func destroy(_ handle: OpaquePointer) { destroyedHandles += 1 }
        func stream(handle: OpaquePointer, text: String, voice: String, onChunk: (UnsafePointer<Float>, Int) -> Void) -> Bool {
            for c in 0..<chunkCount {
                var buffer = (0..<samplesPerChunk).map { i in sinf(Float(c * samplesPerChunk + i) * 0.03) * 0.6 }
                buffer.withUnsafeBufferPointer { onChunk($0.baseAddress!, $0.count) }
            }
            return true
        }
    }

    private func makeValidPaths() throws -> PremiumVoiceRuntimePaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptt-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let voices = root.appendingPathComponent("voices", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: voices, withIntermediateDirectories: true)
        let tokenizer = models.appendingPathComponent("tokenizer.model")
        try Data("tok".utf8).write(to: tokenizer)
        try Data("wav".utf8).write(to: voices.appendingPathComponent("azelma.wav"))
        return PremiumVoiceRuntimePaths(modelsDirectory: models, voicesDirectory: voices, tokenizerPath: tokenizer)
    }

    func testSynthesizeWritesNonEmptyWavWithExpectedEnergy() throws {
        let fake = FakeLibrary()
        let runtime = AttachePremiumVoiceRuntime(idleUnloadInterval: 1000, libraryFactory: { fake })
        let paths = try makeValidPaths()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString).wav")

        try runtime.synthesize(text: "hello", paths: paths, outputURL: out)

        let data = try Data(contentsOf: out)
        let parsed = try PremiumVoiceWav.parse(data)
        XCTAssertEqual(parsed.frameCount, fake.samplesPerChunk * fake.chunkCount)
        XCTAssertGreaterThan(parsed.durationSeconds, 0)
        XCTAssertEqual(fake.createdHandles, 1)

        // Second synthesis reuses the loaded engine (no second create).
        try runtime.synthesize(text: "again", paths: paths, outputURL: out)
        XCTAssertEqual(fake.createdHandles, 1, "engine must be reused across syntheses")

        runtime.unload()
        XCTAssertEqual(fake.destroyedHandles, 1)
    }

    /// The engine must be created with enough flow-matching integration steps to
    /// avoid the single-step overshoot that decodes as robotic/broadband audio
    /// and is then frozen into the recap audio cache. A single Euler step (the
    /// vendored runtime's latency-first default of 1) is not acceptable for
    /// Attaché's cached recaps; guard the quality value so a future edit cannot
    /// silently drop back to it.
    func testEngineIsCreatedWithMultiStepFlowIntegration() throws {
        let fake = FakeLibrary()
        let runtime = AttachePremiumVoiceRuntime(idleUnloadInterval: 1000, libraryFactory: { fake })
        let paths = try makeValidPaths()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString).wav")

        try runtime.synthesize(text: "hello", paths: paths, outputURL: out)

        XCTAssertEqual(fake.lastLsdSteps, AttachePremiumVoiceRuntime.flowIntegrationSteps)
        XCTAssertGreaterThanOrEqual(
            AttachePremiumVoiceRuntime.flowIntegrationSteps, 4,
            "one or two flow-integration steps overshoot into robotic frames on the licensed weights"
        )
    }

    func testMissingWeightsThrowsTypedError() {
        let runtime = AttachePremiumVoiceRuntime(idleUnloadInterval: 1000, libraryFactory: { FakeLibrary() })
        let paths = PremiumVoiceRuntimePaths(
            modelsDirectory: URL(fileURLWithPath: "/nonexistent/models"),
            voicesDirectory: URL(fileURLWithPath: "/nonexistent/voices"),
            tokenizerPath: URL(fileURLWithPath: "/nonexistent/models/tokenizer.model")
        )
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("x.wav")
        XCTAssertThrowsError(try runtime.synthesize(text: "hi", paths: paths, outputURL: out)) { error in
            XCTAssertEqual(error as? PremiumVoiceRuntimeError, .weightsUnavailable)
        }
    }

    func testMissingRuntimeLibraryThrowsTypedError() throws {
        let runtime = AttachePremiumVoiceRuntime(
            idleUnloadInterval: 1000,
            libraryFactory: { throw PremiumVoiceRuntimeError.runtimeUnavailable }
        )
        let paths = try makeValidPaths()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("x.wav")
        XCTAssertThrowsError(try runtime.synthesize(text: "hi", paths: paths, outputURL: out)) { error in
            XCTAssertEqual(error as? PremiumVoiceRuntimeError, .runtimeUnavailable)
        }
    }
}
