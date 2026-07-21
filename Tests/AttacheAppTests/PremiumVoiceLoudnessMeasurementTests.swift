import XCTest
import AppKit
import AttacheCore
@testable import AttacheApp

/// TEMPORARY measurement harness (not shipped): synthesizes a handful of phrases
/// through the REAL premium runtime, writing the raw take AND the normalized take
/// to the session scratchpad so the WAVs can be measured with an external LUFS
/// tool, plus one system-voice sample. Gated exactly like the integration test:
/// it skips cleanly when the dylib/weights are absent.
final class PremiumVoiceLoudnessMeasurementTests: XCTestCase {

    private let scratch = "/private/tmp/claude-501/-Users-danb-code-github-com-danbryan-attache/b4fb4128-9707-4522-a640-76ef90ca9a82/scratchpad/loudness"

    private var stagedDylibURL: URL {
        if let override = ProcessInfo.processInfo.environment[AttachePremiumVoiceRuntime.dylibEnvOverride] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/premium-voice/libpocket_tts.dylib")
    }

    private var weightsPaths: PremiumVoiceRuntimePaths? {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["ATTACHE_PREMIUM_VOICE_TEST_WEIGHTS"] else { return nil }
        let base = URL(fileURLWithPath: dir)
        let models = base.appendingPathComponent("models", isDirectory: true)
        let voices = base.appendingPathComponent("voices", isDirectory: true)
        let tokenizer = models.appendingPathComponent("tokenizer.model")
        let fm = FileManager.default
        guard fm.fileExists(atPath: tokenizer.path),
              fm.fileExists(atPath: voices.appendingPathComponent("azelma.wav").path) else { return nil }
        return PremiumVoiceRuntimePaths(modelsDirectory: models, voicesDirectory: voices, tokenizerPath: tokenizer)
    }

    private let phrases: [(String, String)] = [
        ("p1-short", "Every single test finally passed."),
        ("p2-medium", "Oh wow, we actually pulled it off! After three brutal failed builds, every single test finally passed."),
        ("p3-technical", "I moved the config into Core and wired the new adapter through the coordinator, so the two-way path stays isolated."),
        ("p4-alert", "Heads up, the deploy is blocked on a signing error and needs your attention."),
    ]

    func testMeasurePremiumRawVersusNormalized() throws {
        let dylib = stagedDylibURL
        guard FileManager.default.fileExists(atPath: dylib.path) else {
            throw XCTSkip("premium voice runtime dylib not staged at \(dylib.path)")
        }
        guard let paths = weightsPaths else {
            throw XCTSkip("premium voice weights not present (set ATTACHE_PREMIUM_VOICE_TEST_WEIGHTS)")
        }
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)

        let lib = try DlopenPremiumVoiceRuntimeLibrary(dylibURL: dylib)
        guard let handle = lib.create(
            modelsDir: paths.modelsDirectory.path,
            voicesDir: paths.voicesDirectory.path,
            tokenizerPath: paths.tokenizerPath.path,
            precision: paths.precision,
            temperature: 0.7,
            lsdSteps: AttachePremiumVoiceRuntime.flowIntegrationSteps,
            numThreads: 0
        ) else { throw XCTSkip("engine init failed") }
        _ = lib.warmup(handle)
        defer { lib.destroy(handle) }

        for (name, text) in phrases {
            var raw: [Float] = []
            let done = expectation(description: "synth \(name)")
            let box = SampleBox()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try lib.stream(handle: handle, text: text, voice: paths.voiceFileName) { ptr, count in
                        box.samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
                    }
                } catch { box.error = error }
                done.fulfill()
            }
            wait(for: [done], timeout: 180)
            if let error = box.error { throw error }
            raw = box.samples
            XCTAssertFalse(raw.isEmpty)

            let normalized = SpokenAudioLoudness.normalize(samples: raw, sampleRate: 24_000)
            let rawWav = PremiumVoiceWav.encodeFloatPCM(raw, sampleRate: 24_000)
            let normWav = PremiumVoiceWav.encodeFloatPCM(normalized, sampleRate: 24_000)
            try rawWav.write(to: URL(fileURLWithPath: "\(scratch)/\(name)-raw.wav"))
            try normWav.write(to: URL(fileURLWithPath: "\(scratch)/\(name)-norm.wav"))
            print("MEASURE \(name): rawSamples=\(raw.count)")
        }
    }

    /// One system-voice (NSSpeechSynthesizer) phrase to a scratchpad AIFF so its
    /// level can be measured against the premium path.
    func testMeasureSystemVoiceSample() throws {
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let out = URL(fileURLWithPath: "\(scratch)/system-p1.aiff")
        let synth = NSSpeechSynthesizer()
        let delegate = SpeechDoneDelegate()
        synth.delegate = delegate
        let done = expectation(description: "system synth")
        delegate.onDone = { done.fulfill() }
        guard synth.startSpeaking("Every single test finally passed.", to: out) else {
            throw XCTSkip("system synth failed to start")
        }
        wait(for: [done], timeout: 60)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        print("MEASURE system: wrote \(out.path)")
    }

    private final class SampleBox { var samples: [Float] = []; var error: Error? }

    private final class SpeechDoneDelegate: NSObject, NSSpeechSynthesizerDelegate {
        var onDone: (() -> Void)?
        func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
            onDone?()
        }
    }
}
