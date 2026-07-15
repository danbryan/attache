import AVFoundation
import Combine
import Foundation
import Speech

struct MicrophoneInputDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let isDefault: Bool
}

final class MicTranscriptController: NSObject, ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isTesting = false
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var transcript = ""
    @Published private(set) var status = "Voice input off."

    private var captureSession: AVCaptureSession?
    private var captureOutput: AVCaptureAudioDataOutput?
    private let captureQueue = DispatchQueue(label: "com.bryanlabs.attache.microphone-capture")
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var language = AttacheCaptionLanguage.named("en")
    private var onDeviceOnly = false
    private var lowLatency = true
    private var preferredDeviceID = ""
    private var captureMode: CaptureMode = .speech
    // True between start() and the async authorization callback; cleared by stop()
    // so a release before permission resolves doesn't leave the mic running.
    private var pendingStart = false
    private var deliveryCompletion: ((String) -> Void)?
    private var deliveryTimer: Timer?

    func configure(languageID: String, onDeviceOnly: Bool, lowLatency: Bool, preferredDeviceID: String) {
        language = AttacheCaptionLanguage.named(languageID)
        self.onDeviceOnly = onDeviceOnly
        self.lowLatency = lowLatency
        self.preferredDeviceID = preferredDeviceID
        if isListening, !isTesting {
            stop()
            start()
        } else if isTesting {
            stopMicTest()
            startMicTest()
        }
    }

    static func inputDevices() -> [MicrophoneInputDevice] {
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: microphoneDeviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        var seen = Set<String>()
        return discovery.devices.compactMap { device in
            guard !seen.contains(device.uniqueID) else { return nil }
            seen.insert(device.uniqueID)
            return MicrophoneInputDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isDefault: device.uniqueID == defaultID
            )
        }
    }

    func toggle() {
        (isListening || isPreparing) ? stop() : start()
    }

    func clearTranscript() {
        transcript = ""
    }

    func start() {
        guard !isListening, !isPreparing else { return }
        stopMicTest()
        captureMode = .speech
        transcript = ""
        audioLevel = 0
        pendingStart = true
        isPreparing = true
        status = "Requesting microphone and speech access."

        SFSpeechRecognizer.requestAuthorization { [weak self] speechStatus in
            DispatchQueue.main.async {
                guard let self, self.pendingStart else { return }
                guard speechStatus == .authorized else {
                    self.pendingStart = false
                    self.isPreparing = false
                    self.status = "Speech recognition permission is required."
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        guard self.pendingStart else { return }
                        guard granted else {
                            self.pendingStart = false
                            self.isPreparing = false
                            self.status = "Microphone permission is required."
                            return
                        }
                        self.startAuthorized()
                    }
                }
            }
        }
    }

    func stop(status nextStatus: String = "Voice input off.") {
        pendingStart = false
        isPreparing = false
        isTesting = false
        deliveryTimer?.invalidate()
        deliveryTimer = nil
        deliveryCompletion = nil
        cleanupRecognition(status: nextStatus)
    }

    func startMicTest() {
        guard !isListening, !isPreparing, !isTesting else { return }
        captureMode = .test
        transcript = ""
        audioLevel = 0
        pendingStart = true
        isPreparing = true
        status = "Requesting microphone access for test."

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.pendingStart else { return }
                guard granted else {
                    self.pendingStart = false
                    self.isPreparing = false
                    self.status = "Microphone permission is required."
                    return
                }
                do {
                    let device = try self.startAudioCapture(appendingTo: nil)
                    self.pendingStart = false
                    self.isPreparing = false
                    self.isListening = true
                    self.isTesting = true
                    self.status = "Testing microphone via \(device)."
                } catch {
                    self.pendingStart = false
                    self.isPreparing = false
                    self.isTesting = false
                    self.audioLevel = 0
                    self.status = Self.microphoneStartErrorMessage(error)
                }
            }
        }
    }

    func stopMicTest() {
        guard isTesting || captureMode == .test else { return }
        pendingStart = false
        isPreparing = false
        isTesting = false
        isListening = false
        audioLevel = 0
        stopAudioCapture()
        status = "Voice input off."
    }

    /// Push-to-talk finish: stop feeding audio, let the recognizer produce its
    /// final result, then deliver it (with a fallback to the latest partial if the
    /// final is slow). This is what actually captures the spoken turn on release.
    func finishAndDeliver(_ completion: @escaping (String) -> Void) {
        pendingStart = false
        isPreparing = false
        guard isListening, recognitionTask != nil else {
            let text = transcript
            cleanupRecognition(status: "Voice input off.")
            completion(text)
            return
        }
        deliveryCompletion = completion
        status = "Transcribing…"
        stopAudioCapture()
        recognitionRequest?.endAudio()
        deliveryTimer?.invalidate()
        deliveryTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.deliverFinal(self.transcript)
        }
    }

    private func deliverFinal(_ text: String) {
        deliveryTimer?.invalidate()
        deliveryTimer = nil
        let completion = deliveryCompletion
        deliveryCompletion = nil
        cleanupRecognition(status: "Voice input off.")
        completion?(text)
    }

    private func cleanupRecognition(status nextStatus: String) {
        stopAudioCapture()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isListening = false
        isTesting = false
        audioLevel = 0
        status = nextStatus
    }

    private func startAuthorized() {
        stopExistingRecognition()

        let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: language.speechLocale))
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            pendingStart = false
            isPreparing = false
            status = "Speech recognizer unavailable for \(language.name)."
            return
        }
        if onDeviceOnly && !speechRecognizer.supportsOnDeviceRecognition {
            pendingStart = false
            isPreparing = false
            status = "On-device speech is unavailable for \(language.name)."
            return
        }
        recognizer = speechRecognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if onDeviceOnly {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let captureDescription: String
        do {
            captureDescription = try startAudioCapture(appendingTo: request)
        } catch {
            pendingStart = false
            isPreparing = false
            recognitionRequest = nil
            status = Self.microphoneStartErrorMessage(error)
            return
        }
        pendingStart = false
        isPreparing = false
        isListening = true
        status = "Listening in \(language.name) via \(captureDescription)."

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result, self.lowLatency || result.isFinal {
                    self.transcript = result.bestTranscription.formattedString
                }
                if result?.isFinal == true {
                    if self.deliveryCompletion != nil {
                        self.deliverFinal(self.transcript)
                    } else {
                        self.status = "Final transcript captured."
                    }
                } else if error != nil {
                    // An error after we asked to finish still hands back whatever
                    // was transcribed; otherwise surface it.
                    if self.deliveryCompletion != nil {
                        self.deliverFinal(self.transcript)
                    } else {
                        self.stop(status: "Voice input stopped.")
                    }
                }
            }
        }
    }

    private func stopExistingRecognition() {
        stopAudioCapture()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    private func startAudioCapture(appendingTo request: SFSpeechAudioBufferRecognitionRequest?) throws -> String {
        stopAudioCapture()
        guard let device = selectedInputDevice() else {
            throw MicrophoneStartError.unavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            output.setSampleBufferDelegate(nil, queue: nil)
            throw MicrophoneStartError.failed("Cannot attach the selected microphone.")
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            output.setSampleBufferDelegate(nil, queue: nil)
            throw MicrophoneStartError.failed("Cannot attach the microphone sample output.")
        }
        session.addOutput(output)
        session.commitConfiguration()

        captureSession = session
        captureOutput = output

        captureQueue.sync {
            session.startRunning()
        }
        guard session.isRunning else {
            output.setSampleBufferDelegate(nil, queue: nil)
            captureOutput = nil
            captureSession = nil
            throw MicrophoneStartError.failed("The microphone capture session did not start.")
        }
        return device.localizedName
    }

    private func selectedInputDevice() -> AVCaptureDevice? {
        if !preferredDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let device = AVCaptureDevice(uniqueID: preferredDeviceID) {
            return device
        }
        return AVCaptureDevice.default(for: .audio)
    }

    private func stopAudioCapture() {
        let session = captureSession
        captureOutput?.setSampleBufferDelegate(nil, queue: nil)
        captureOutput = nil
        captureSession = nil
        guard let session else { return }
        captureQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private static func microphoneStartErrorMessage(_ error: Error) -> String {
        if case MicrophoneStartError.unavailable = error {
            return "Microphone is unavailable. Check Privacy > Microphone in System Settings."
        }
        if case MicrophoneStartError.failed(let message) = error {
            return "Microphone start failed: \(message)"
        }
        let nsError = error as NSError
        if nsError.domain == "com.apple.coreaudio.avfaudio", nsError.code == -10868 {
            return "Microphone input format was rejected by CoreAudio (-10868). Try again or change input device."
        }
        return "Microphone start failed: \(error.localizedDescription)"
    }
}

extension MicTranscriptController {
    /// Test-only pose override (INF-244's screenshot-matrix success criterion):
    /// lets the UI smoke harness put the call composer into the mic-`.listening`
    /// visual state (`CallPhase.derive`, `CallStatusPresentation`'s
    /// `listeningText`, and `CallHUD.swift`'s `callMicStatusText`) without ever
    /// opening `AVCaptureSession` or asking `SFSpeechRecognizer` for
    /// authorization. Real mic/speech permission prompts would interrupt
    /// unattended automation, and there is no reason to touch real audio
    /// hardware just to prove a status string renders.
    ///
    /// Safety-critical: inert unless `ATTACHE_UI_TEST=1` is ALSO present,
    /// mirroring `InstructionReplyEngine.expiryWindow(fromEnvironment:)` and
    /// `SpeechPlaybackController.shouldMuteAudioOutput`, so a real user could
    /// never trigger this in production. See
    /// `MicTranscriptControllerForceListeningTests` for the explicit
    /// non-bypass proof (the flag set WITHOUT `ATTACHE_UI_TEST=1` has no
    /// effect).
    static func shouldForceListeningForPose(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["ATTACHE_UI_TEST"] == "1" && environment["ATTACHE_UI_TEST_FORCE_LISTENING"] == "1"
    }

    /// Applies the pose override if the environment requests it. Never starts
    /// `AVCaptureSession` or `SFSpeechRecognizer`; only flips the same
    /// published flag `CallPhase.derive` and `CallHUD.swift` already read, so
    /// real capture code paths (`start()`, `stop()`, `startMicTest()`) are
    /// untouched.
    func applyForcedListeningPoseIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard Self.shouldForceListeningForPose(environment: environment) else { return }
        isListening = true
        status = "Listening (posed for a screenshot)."
    }
}

extension MicTranscriptController: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }
        updateAudioLevel(from: sampleBuffer)
        if captureMode == .speech {
            recognitionRequest?.appendAudioSampleBuffer(sampleBuffer)
        }
    }

    private func updateAudioLevel(from sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, totalLength > 0, let dataPointer else { return }
        let sampleCount = totalLength / MemoryLayout<Float32>.size
        guard sampleCount > 0 else { return }
        let samples = dataPointer.withMemoryRebound(to: Float32.self, capacity: sampleCount) { pointer in
            UnsafeBufferPointer(start: pointer, count: sampleCount)
        }
        var sum: Double = 0
        for sample in samples {
            let value = Double(sample)
            sum += value * value
        }
        let rms = sqrt(sum / Double(sampleCount))
        let normalized = min(1, max(0, rms * 10))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.audioLevel = max(self.audioLevel * 0.72, normalized)
        }
    }
}

private enum MicrophoneStartError: Error {
    case unavailable
    case failed(String = "The microphone could not be started.")
}

private enum CaptureMode {
    case speech
    case test
}

private var microphoneDeviceTypes: [AVCaptureDevice.DeviceType] {
    if #available(macOS 14.0, *) {
        return [.microphone, .external]
    }
    return [.builtInMicrophone, .externalUnknown]
}
