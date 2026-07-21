import AttacheCore
import Foundation
import OSLog
import Speech

/// On-device forced alignment: recognizes the words in a synthesized clip and
/// hands their timings plus the KNOWN script to the pure `ForcedAlignment`
/// mapper, recovering exact per-word timing for karaoke captions on engines that
/// supply none (premium, system, xAI, OpenAI). Recognition runs off the main
/// thread over `SFSpeechURLRecognitionRequest` with `requiresOnDeviceRecognition`
/// so nothing leaves the device. It NEVER blocks playback: the caller starts
/// audio on the estimated timeline and applies the exact one when this finishes.
///
/// Permission is requested at most once. A denial (or an environment without
/// on-device recognition) is logged a single time and then permanently falls the
/// aligner back to "unavailable", so no clip re-prompts or re-logs.
final class SpeechForcedAligner {
    static let shared = SpeechForcedAligner()

    private let logger = Logger(subsystem: "com.bryanlabs.attache", category: "alignment")
    private let lock = NSLock()
    private var permanentlyUnavailable = false
    private var loggedUnavailable = false
    private var activeTasks: [UUID: SFSpeechRecognitionTask] = [:]

    /// Test seam: when set, recognition is served by this closure instead of
    /// `SFSpeechRecognizer`, so the never-block wiring and completion handling are
    /// exercised without depending on the OS recognizer being available.
    var recognizerOverride: ((_ audioURL: URL, _ completion: @escaping ([RecognizedWord]?) -> Void) -> Void)?

    /// Hard ceiling so a stuck recognizer can never wedge the pipeline; on expiry
    /// the in-flight task is cancelled and the completion fires with nil.
    var recognitionTimeout: TimeInterval = 25

    private init() {}

    /// Aligns `scriptText` against the words recognized in `audioURL`. Calls
    /// `completion` exactly once with an accepted exact alignment, or nil when
    /// recognition is unavailable/denied, times out, or the recovered timing is
    /// below the confidence threshold (caller then keeps the estimated timeline).
    /// `completion` may run on an arbitrary queue.
    func align(
        audioURL: URL,
        scriptText: String,
        totalDurationMs: Int,
        completion: @escaping (CaptionAlignment?) -> Void
    ) {
        let trimmed = scriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion(nil); return }

        if let recognizerOverride {
            recognizerOverride(audioURL) { [weak self] words in
                self?.finishAlignment(words: words, scriptText: scriptText, totalDurationMs: totalDurationMs, completion: completion)
            }
            return
        }

        lock.lock()
        let unavailable = permanentlyUnavailable
        lock.unlock()
        if unavailable { completion(nil); return }

        ensureAuthorized { [weak self] authorized in
            guard let self else { completion(nil); return }
            guard authorized else { completion(nil); return }
            self.runRecognition(audioURL: audioURL, scriptText: scriptText, totalDurationMs: totalDurationMs, completion: completion)
        }
    }

    // MARK: - Authorization

    private func ensureAuthorized(_ done: @escaping (Bool) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            done(true)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                if status == .authorized {
                    done(true)
                } else {
                    self?.markUnavailable("speech recognition permission was not granted")
                    done(false)
                }
            }
        default:
            markUnavailable("speech recognition permission is denied or restricted")
            done(false)
        }
    }

    /// Latches the aligner off and logs the reason exactly once, so a denied
    /// permission never re-prompts and never re-logs per clip.
    private func markUnavailable(_ reason: String) {
        lock.lock()
        let shouldLog = !loggedUnavailable
        loggedUnavailable = true
        permanentlyUnavailable = true
        lock.unlock()
        if shouldLog {
            logger.info("Forced alignment disabled for this session: \(reason, privacy: .public). Captions keep estimated timing.")
        }
    }

    // MARK: - Recognition

    private func runRecognition(
        audioURL: URL,
        scriptText: String,
        totalDurationMs: Int,
        completion: @escaping (CaptionAlignment?) -> Void
    ) {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            markUnavailable("no speech recognizer is available")
            completion(nil)
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            markUnavailable("on-device speech recognition is not supported here")
            completion(nil)
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        if #available(macOS 13.0, *) {
            request.addsPunctuation = false
        }

        let taskID = UUID()
        let completedFlag = CompletionLatch()

        let deliver: (CaptionAlignment?) -> Void = { [weak self] alignment in
            guard completedFlag.tryComplete() else { return }
            self?.removeTask(taskID)
            completion(alignment)
        }

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let error {
                self.logger.debug("Forced alignment recognition failed: \(error.localizedDescription, privacy: .public)")
                deliver(nil)
                return
            }
            guard let result, result.isFinal else { return }
            let words = result.bestTranscription.segments.map { segment in
                RecognizedWord(
                    text: segment.substring,
                    startMs: Int((segment.timestamp * 1000).rounded()),
                    durationMs: max(1, Int((segment.duration * 1000).rounded()))
                )
            }
            self.finishAlignment(words: words, scriptText: scriptText, totalDurationMs: totalDurationMs, completion: deliver)
        }

        lock.lock()
        activeTasks[taskID] = task
        lock.unlock()

        // Bounded: never let a wedged recognizer hold the clip's alignment open.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + recognitionTimeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let pending = self.activeTasks[taskID]
            self.lock.unlock()
            pending?.cancel()
            deliver(nil)
        }
    }

    private func finishAlignment(
        words: [RecognizedWord]?,
        scriptText: String,
        totalDurationMs: Int,
        completion: @escaping (CaptionAlignment?) -> Void
    ) {
        guard let words, !words.isEmpty else { completion(nil); return }
        let result = ForcedAlignment.align(
            scriptText: scriptText,
            recognized: words,
            totalDurationMs: totalDurationMs
        )
        completion(result.accepted ? result.alignment : nil)
    }

    private func removeTask(_ id: UUID) {
        lock.lock()
        activeTasks[id] = nil
        lock.unlock()
    }
}

/// One-shot latch so a recognition callback plus its timeout can race to finish
/// but the completion runs exactly once.
private final class CompletionLatch {
    private let lock = NSLock()
    private var done = false

    func tryComplete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
