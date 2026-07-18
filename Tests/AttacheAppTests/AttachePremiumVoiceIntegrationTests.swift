import XCTest
import AttacheCore
@testable import AttacheApp

/// End-to-end synthesis through the REAL native runtime, guarded so it runs only
/// when the dylib and weights are present and skips cleanly otherwise (a plain
/// `swift build && scripts/test.sh` on a machine that never built the runtime
/// must stay green). Bounded: the synthesis runs on a background queue and the
/// test fails on timeout rather than hanging, and nothing is left stranded.
final class AttachePremiumVoiceIntegrationTests: XCTestCase {

    /// Default dev-staging location produced by scripts/build-premium-voice-runtime.sh.
    private var stagedDylibURL: URL {
        if let override = ProcessInfo.processInfo.environment[AttachePremiumVoiceRuntime.dylibEnvOverride] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/premium-voice/libpocket_tts.dylib")
    }

    /// Weights dir with models/ and voices/ subtrees. Override to point at an
    /// installed set; defaults to the E0 spike output.
    private var weightsPaths: PremiumVoiceRuntimePaths? {
        let env = ProcessInfo.processInfo.environment
        let base: URL
        if let dir = env["ATTACHE_PREMIUM_VOICE_TEST_WEIGHTS"] {
            base = URL(fileURLWithPath: dir)
        } else if let spike = env["ATTACHE_E0_SPIKE_DIR"] {
            base = URL(fileURLWithPath: spike).appendingPathComponent("PocketTTS.cpp")
        } else {
            base = URL(fileURLWithPath:
                "/private/tmp/claude-501/-Users-danb-code-github-com-danbryan-attache/b4fb4128-9707-4522-a640-76ef90ca9a82/scratchpad/e0-spike/PocketTTS.cpp")
        }
        let models = base.appendingPathComponent("models", isDirectory: true)
        let voices = base.appendingPathComponent("voices", isDirectory: true)
        let tokenizer = models.appendingPathComponent("tokenizer.model")
        let fm = FileManager.default
        guard fm.fileExists(atPath: tokenizer.path),
              fm.fileExists(atPath: voices.appendingPathComponent("azelma.wav").path) else {
            return nil
        }
        return PremiumVoiceRuntimePaths(modelsDirectory: models, voicesDirectory: voices, tokenizerPath: tokenizer)
    }

    func testRealRuntimeSynthesizesNonSilentAudio() throws {
        let dylib = stagedDylibURL
        guard FileManager.default.fileExists(atPath: dylib.path) else {
            throw XCTSkip("premium voice runtime dylib not staged at \(dylib.path); build it with scripts/build-premium-voice-runtime.sh")
        }
        guard let paths = weightsPaths else {
            throw XCTSkip("premium voice weights not present; skipping integration synthesis")
        }

        let runtime = AttachePremiumVoiceRuntime(
            idleUnloadInterval: 1000,
            libraryFactory: { try DlopenPremiumVoiceRuntimeLibrary(dylibURL: dylib) }
        )
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("premium-integration-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }

        // Run the blocking native synthesis off the test thread with a hard cap.
        let done = expectation(description: "synthesis completes")
        let box = ResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try runtime.synthesize(text: "Every single test finally passed.", paths: paths, outputURL: out)
                box.error = nil
            } catch {
                box.error = error
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 120)
        runtime.unload()

        if let error = box.error {
            throw error
        }
        let data = try Data(contentsOf: out)
        let parsed = try PremiumVoiceWav.parse(data)
        XCTAssertGreaterThan(parsed.frameCount, 24_000, "expected at least ~1s of audio")

        // Assert nonzero energy: read the float payload and compute RMS.
        let rms = Self.rms(ofFloatWav: data, dataByteOffset: 44, frameCount: parsed.frameCount)
        XCTAssertGreaterThan(rms, 0.001, "synthesized audio must not be silent")
    }

    /// The preview phrase the app speaks, synthesized through the REAL engine
    /// and asserted to exceed five seconds with nonzero energy. This is the body
    /// `scripts/premium-voice-smoke.sh` drives via `swift test --filter`; the
    /// script stages the dylib and points `ATTACHE_PREMIUM_VOICE_TEST_WEIGHTS`
    /// at real weights, so under the gate this runs rather than skips. Bounded:
    /// the native synthesis runs off the test thread with a hard timeout.
    func testRealRuntimeSynthesizesPreviewPhraseOverFiveSeconds() throws {
        let dylib = stagedDylibURL
        guard FileManager.default.fileExists(atPath: dylib.path) else {
            throw XCTSkip("premium voice runtime dylib not staged at \(dylib.path); build it with scripts/build-premium-voice-runtime.sh")
        }
        guard let paths = weightsPaths else {
            throw XCTSkip("premium voice weights not present; skipping preview-phrase synthesis")
        }

        let phrase = "Oh wow, we actually pulled it off! After three brutal failed builds, every single test finally passed, and honestly I could cry with relief right now."
        let runtime = AttachePremiumVoiceRuntime(
            idleUnloadInterval: 1000,
            libraryFactory: { try DlopenPremiumVoiceRuntimeLibrary(dylibURL: dylib) }
        )
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("premium-preview-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }

        let done = expectation(description: "preview synthesis completes")
        let box = ResultBox()
        let start = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try runtime.synthesize(text: phrase, paths: paths, outputURL: out)
                box.error = nil
            } catch {
                box.error = error
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 300)
        let elapsed = Date().timeIntervalSince(start)
        runtime.unload()

        if let error = box.error { throw error }
        let data = try Data(contentsOf: out)
        let parsed = try PremiumVoiceWav.parse(data)
        print("premium-voice-smoke: synthesized \(String(format: "%.1f", parsed.durationSeconds))s of audio in \(String(format: "%.1f", elapsed))s")
        XCTAssertGreaterThan(parsed.durationSeconds, 5, "preview phrase should exceed five seconds")

        let rms = Self.rms(ofFloatWav: data, dataByteOffset: 44, frameCount: parsed.frameCount)
        XCTAssertGreaterThan(rms, 0.001, "synthesized audio must not be silent")
    }

    private final class ResultBox { var error: Error? }

    private static func rms(ofFloatWav data: Data, dataByteOffset: Int, frameCount: Int) -> Float {
        guard frameCount > 0, data.count >= dataByteOffset + frameCount * 4 else { return 0 }
        var sumSquares: Double = 0
        data.withUnsafeBytes { raw in
            let floats = raw.baseAddress!.advanced(by: dataByteOffset).assumingMemoryBound(to: Float.self)
            for i in 0..<frameCount {
                let v = Double(floats[i])
                sumSquares += v * v
            }
        }
        return Float((sumSquares / Double(frameCount)).squareRoot())
    }
}
