import AttacheCore
import AVFoundation
import Speech
import XCTest
@testable import AttacheApp

/// Opt-in measurement of on-device forced alignment against the REAL premium
/// voice: synthesizes three phrases, recognizes each, and reports recognition
/// wall time vs clip duration, anchored-word fraction, and the maximum per-word
/// deviation between the recovered exact timeline and the old estimated one (i.e.
/// how wrong the estimates were). Never part of the normal suite: it runs only
/// when `ATTACHE_MEASURE_FORCED_ALIGNMENT=1` AND the dylib + weights are present,
/// and skips cleanly (with a printed note) when speech recognition is unavailable.
final class ForcedAlignmentMeasurementTests: XCTestCase {
    private final class Box { var error: Error? }

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["ATTACHE_MEASURE_FORCED_ALIGNMENT"] == "1"
    }

    private var stagedDylibURL: URL {
        if let override = ProcessInfo.processInfo.environment[AttachePremiumVoiceRuntime.dylibEnvOverride] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/premium-voice/libpocket_tts.dylib")
    }

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

    func testMeasureForcedAlignmentAgainstRealPremiumVoice() throws {
        try XCTSkipUnless(enabled, "set ATTACHE_MEASURE_FORCED_ALIGNMENT=1 to run the alignment measurement")
        let dylib = stagedDylibURL
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dylib.path), "premium voice runtime dylib not staged")
        guard let paths = weightsPaths else { throw XCTSkip("premium voice weights not present") }

        // Authorize on-device recognition; skip gracefully if unavailable/denied.
        let authorized = requestSpeechAuthorization()
        try XCTSkipUnless(authorized, "on-device speech recognition is unavailable or not authorized in this environment")
        guard let recognizer = SFSpeechRecognizer(), recognizer.supportsOnDeviceRecognition else {
            throw XCTSkip("on-device speech recognition is not supported here")
        }

        let phrases: [(name: String, text: String)] = [
            ("short", "Build finished and every test passed."),
            ("number-heavy", "The run processed 1024 files across 37 batches in 5.5 seconds with 0 failures."),
            ("long", String(repeating: "The deployment rolled out cleanly to every node, the migration completed without a single dropped row, and the dashboards all turned green within a couple of minutes. ", count: 4))
        ]

        let runtime = AttachePremiumVoiceRuntime(
            idleUnloadInterval: 1000,
            libraryFactory: { try DlopenPremiumVoiceRuntimeLibrary(dylibURL: dylib) }
        )
        defer { runtime.unload() }

        print("=== Forced alignment measurement (real Azelma premium voice) ===")
        // Cache synthesized clips in a stable scratchpad dir so re-runs iterate on
        // recognition without paying for premium synthesis again.
        let cacheDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("attache-align-measure", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        for phrase in phrases {
            let out = cacheDir.appendingPathComponent("align-measure-\(phrase.name).wav")

            if !FileManager.default.fileExists(atPath: out.path) {
                // Synthesize off the test thread with a hard cap.
                let synthDone = expectation(description: "synthesis \(phrase.name)")
                let box = Box()
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try runtime.synthesize(text: phrase.text, paths: paths, outputURL: out) }
                    catch { box.error = error }
                    synthDone.fulfill()
                }
                wait(for: [synthDone], timeout: 180)
                if let error = box.error { throw error }
            }

            let parsed = try PremiumVoiceWav.parse(Data(contentsOf: out))
            let clipMs = Int((parsed.durationSeconds * 1000).rounded())

            // Recognize and time it.
            let started = Date()
            guard let recognized = recognizeWords(url: out, recognizer: recognizer) else {
                print("[\(phrase.name)] clip=\(clipMs)ms  recognition unavailable in this host " +
                      "(on-device SFSpeech returned neither a final result nor an error within the window; " +
                      "it requires a full app bundle with dictation enabled). Alignment mapping is covered by the fixture tests.")
                continue
            }
            let recogSeconds = Date().timeIntervalSince(started)

            let result = ForcedAlignment.align(scriptText: phrase.text, recognized: recognized, totalDurationMs: clipMs)
            let estimated = CaptionAlignmentBuilder.fallback(text: phrase.text, durationMs: clipMs)

            // Max per-word deviation between the exact and estimated start times.
            var maxDeviationMs = 0
            for (index, word) in result.alignment.words.enumerated() where index < estimated.words.count {
                maxDeviationMs = max(maxDeviationMs, abs(word.startMs - estimated.words[index].startMs))
            }

            print(String(
                format: "[%@] clip=%dms  recog=%.2fs (%.2fx realtime)  anchored=%.0f%%  accepted=%@  maxWordDeviationVsEstimate=%dms",
                phrase.name,
                clipMs,
                recogSeconds,
                clipMs > 0 ? recogSeconds / (Double(clipMs) / 1000.0) : 0,
                result.confidence * 100,
                result.accepted ? "yes" : "no",
                maxDeviationMs
            ))
        }
        print("=== end measurement ===")
    }

    private func requestSpeechAuthorization() -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            let sem = DispatchSemaphore(value: 0)
            var granted = false
            SFSpeechRecognizer.requestAuthorization { status in
                granted = status == .authorized
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 20)
            return granted
        default:
            return false
        }
    }

    private func recognizeWords(url: URL, recognizer: SFSpeechRecognizer) -> [RecognizedWord]? {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        if #available(macOS 13.0, *) { request.addsPunctuation = false }

        let sem = DispatchSemaphore(value: 0)
        var words: [RecognizedWord]?
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let error {
                print("    recognition error: \(error.localizedDescription)")
                sem.signal(); return
            }
            guard let result, result.isFinal else { return }
            words = result.bestTranscription.segments.map {
                RecognizedWord(
                    text: $0.substring,
                    startMs: Int(($0.timestamp * 1000).rounded()),
                    durationMs: max(1, Int(($0.duration * 1000).rounded()))
                )
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 60) == .timedOut {
            task.cancel()
            return nil
        }
        return words
    }
}
