import XCTest
import AttacheCore
@testable import AttacheApp

/// Exercises the runtime wrapper (serialization, path validation, typed errors,
/// and correct WAV writing) with a fake native library, so no dylib is needed.
final class AttachePremiumVoiceRuntimeTests: XCTestCase {

    /// A stand-in for libpocket_tts.dylib that emits a fixed tone. Can be told to
    /// throw on a number of leading `stream` calls to model a transient or
    /// persistent runtime failure.
    final class FakeLibrary: PremiumVoiceRuntimeLibrary {
        var createdHandles = 0
        var destroyedHandles = 0
        var samplesPerChunk = 512
        var chunkCount = 20
        var lastLsdSteps: Int32?
        var lastTemperature: Float?
        /// When set, the next `failStreamCalls` calls to `stream` throw this error
        /// (decrementing each time), then subsequent calls succeed.
        var streamError: Error?
        var failStreamCalls = 0
        var streamCallCount = 0
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
        func stream(handle: OpaquePointer, text: String, voice: String, onChunk: (UnsafePointer<Float>, Int) -> Void) throws {
            streamCallCount += 1
            if failStreamCalls > 0, let error = streamError {
                failStreamCalls -= 1
                throw error
            }
            for c in 0..<chunkCount {
                var buffer = (0..<samplesPerChunk).map { i in sinf(Float(c * samplesPerChunk + i) * 0.03) * 0.6 }
                buffer.withUnsafeBufferPointer { onChunk($0.baseAddress!, $0.count) }
            }
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

    /// A failed native stream must surface as the typed `.streamFailed` error and
    /// carry the runtime's own diagnostic message, so the shipped 0.6.0 process
    /// abort becomes a recoverable Swift error.
    func testFailedStreamPropagatesTypedErrorWithMessage() throws {
        let fake = FakeLibrary()
        fake.streamError = PremiumVoiceRuntimeError.streamFailed(message: "ORT: non-zero status")
        fake.failStreamCalls = 1
        let runtime = AttachePremiumVoiceRuntime(idleUnloadInterval: 1000, libraryFactory: { fake })
        let paths = try makeValidPaths()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString).wav")

        XCTAssertThrowsError(try runtime.synthesize(text: "boom", paths: paths, outputURL: out)) { error in
            guard case .streamFailed(let message) = error as? PremiumVoiceRuntimeError else {
                return XCTFail("expected .streamFailed, got \(error)")
            }
            XCTAssertEqual(message, "ORT: non-zero status")
        }
    }

    /// After a stream failure the engine handle is torn down, so the NEXT
    /// synthesize reloads a clean handle instead of reusing possibly-corrupt ONNX
    /// session state. Models the retry path: attempt 1 fails, attempt 2 succeeds
    /// on a freshly created engine.
    func testEngineIsCleanlyReloadedAfterFailure() throws {
        let fake = FakeLibrary()
        fake.streamError = PremiumVoiceRuntimeError.streamFailed(message: "transient")
        fake.failStreamCalls = 1
        let runtime = AttachePremiumVoiceRuntime(idleUnloadInterval: 1000, libraryFactory: { fake })
        let paths = try makeValidPaths()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString).wav")

        // Attempt 1: engine created, stream throws, engine destroyed.
        XCTAssertThrowsError(try runtime.synthesize(text: "first", paths: paths, outputURL: out))
        XCTAssertEqual(fake.createdHandles, 1)
        XCTAssertEqual(fake.destroyedHandles, 1, "a failed synthesis must drop the engine")

        // Attempt 2: a fresh engine is created and synthesis succeeds.
        try runtime.synthesize(text: "second", paths: paths, outputURL: out)
        XCTAssertEqual(fake.createdHandles, 2, "the next synthesis must reload a clean engine")
        let parsed = try PremiumVoiceWav.parse(try Data(contentsOf: out))
        XCTAssertEqual(parsed.frameCount, fake.samplesPerChunk * fake.chunkCount)
    }

    /// The retry helper the playback layer uses re-drives synthesis, so a
    /// transient stream failure recovers on the second attempt with no fallback.
    func testRetryRecoversFromTransientStreamFailure() async throws {
        let fake = FakeLibrary()
        fake.streamError = PremiumVoiceRuntimeError.streamFailed(message: "transient")
        fake.failStreamCalls = 1
        let runtime = AttachePremiumVoiceRuntime(idleUnloadInterval: 1000, libraryFactory: { fake })
        let paths = try makeValidPaths()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString).wav")

        try await retrying(attempts: 2, backoff: 0) {
            try runtime.synthesize(text: "recap", paths: paths, outputURL: out)
        }
        XCTAssertEqual(fake.streamCallCount, 2, "the first attempt fails, the second succeeds")
        XCTAssertEqual(fake.createdHandles, 2, "the second attempt runs on a reloaded engine")
    }

    /// A persistent stream failure exhausts the retries and rethrows, which is the
    /// signal the playback layer turns into a system-voice fallback.
    func testRetryRethrowsAfterExhaustingAttempts() async throws {
        let fake = FakeLibrary()
        fake.streamError = PremiumVoiceRuntimeError.streamFailed(message: "persistent")
        fake.failStreamCalls = 5
        let runtime = AttachePremiumVoiceRuntime(idleUnloadInterval: 1000, libraryFactory: { fake })
        let paths = try makeValidPaths()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString).wav")

        do {
            try await retrying(attempts: 2, backoff: 0) {
                try runtime.synthesize(text: "recap", paths: paths, outputURL: out)
            }
            XCTFail("expected the exhausted retry to rethrow")
        } catch {
            guard case .streamFailed = error as? PremiumVoiceRuntimeError else {
                return XCTFail("expected .streamFailed after exhaustion, got \(error)")
            }
        }
        XCTAssertEqual(fake.streamCallCount, 2, "both attempts ran")
    }
}
