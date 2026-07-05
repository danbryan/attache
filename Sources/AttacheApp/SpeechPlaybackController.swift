import AppKit
import AVFoundation
import Combine
import AttacheCore
import Foundation

final class SpeechPlaybackController: NSObject, ObservableObject, NSSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    /// True from the moment a card/preview starts synthesizing until it finishes,
    /// fails, or is stopped. Unlike `isPlaying` (only true after synthesis and
    /// decode), this covers the synthesis window, so the live path can queue a
    /// second update instead of cancelling the one being synthesized.
    @Published private(set) var isBusy = false
    @Published private(set) var durationMs = 0
    @Published private(set) var currentCardID: String?
    @Published private(set) var currentText: String = ""
    @Published private(set) var currentAlignment: CaptionAlignment?
    @Published private(set) var voiceIdentifier: String?

    /// Clock-driven state (~20 Hz). Kept in its own observable so observing the
    /// controller doesn't invalidate the whole window on every tick; only the
    /// caption, scrubber, and visualizer observe `clock`.
    let clock = PlaybackTimeline()

    // Forwards so the rest of the controller reads/writes the clock state by its
    // original names while it actually lives on `clock`.
    private var currentTimeMs: Int {
        get { clock.currentTimeMs }
        set { clock.currentTimeMs = newValue }
    }
    private var activeWordIndex: Int? {
        get { clock.activeWordIndex }
        set { clock.activeWordIndex = newValue }
    }
    private var renderState: VisualizerRenderState {
        get { clock.renderState }
        set { clock.renderState = newValue }
    }
    private var envelope: Double {
        get { clock.envelope }
        set { clock.envelope = newValue }
    }

    /// Fires when a card's playback ends: `success` is true only after the audio
    /// played to the end, false when synthesis/decode/analysis failed. Never fires
    /// on an explicit `stop()` (a preemption, not a finish).
    var onFinished: ((_ cardID: String, _ success: Bool) -> Void)?
    /// Fires when a preview (voice sample or conversation reply) ends, so the live
    /// queue can resume after a reply preempted an update.
    var onPreviewFinished: (() -> Void)?
    var onPlaybackError: ((String) -> Void)?

    /// Whether the in-flight generation is a preview (reply/sample) rather than a
    /// card, so the right completion hook fires.
    private var activeIsPreview = false

    private let speechFileSynthesizer = NSSpeechSynthesizer()
    private var speechConfiguration = CompanionSpeechConfiguration.systemDefault
    /// Time-stretch applied at the player, so it works for every voice engine,
    /// costs no re-synthesis, and the caption clock (which reads the player's
    /// currentTime) stays in sync automatically. Applies live mid-playback.
    var playbackRate: Float = 1.0 {
        didSet {
            let clamped = min(2.0, max(0.5, playbackRate))
            if clamped != playbackRate { playbackRate = clamped; return }
            player?.rate = clamped
            reanchorClock()
        }
    }
    // AVAudioPlayer's currentTime reporting turns coarse under a non-1x rate,
    // which made captions wander when the speed changed. The clock anchors on
    // the player's position and extrapolates with the wall clock scaled by
    // the rate, re-anchoring whenever the player disagrees enough to matter.
    private var clockAnchorAudioMs = 0
    private var clockAnchorHost: TimeInterval = 0

    private func reanchorClock() {
        clockAnchorAudioMs = Int(((player?.currentTime ?? 0) * 1000).rounded())
        clockAnchorHost = ProcessInfo.processInfo.systemUptime
    }
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var timeline = AnalyzedAudioTimeline.empty
    private var generationID: UUID?
    private var generatedAudioURL: URL?
    private var generationCompletion: ((Bool) -> Void)?
    private var finishingNormally = false
    private var audioCacheRetentionSeconds: TimeInterval = 24 * 3600
    private var lastAudioCacheCleanup = Date.distantPast

    // When true, the current audio file lives in the persistent cache and must
    // survive playback so the next replay can reuse it instead of re-synthesizing.
    private var generatedAudioIsCached = false

    /// Persistent home for synthesized recap audio, so replaying a card reuses the
    /// clip instead of re-running the voice (no credits, no network wait).
    private lazy var audioCacheDirectory: URL? = {
        let directory = CompanionAppSupport.supportDirectory()
            .appendingPathComponent("AudioCache", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            return nil
        }
    }()

    // Playhead/visualizer refresh rate. Lower = less CPU during playback at the
    // cost of caption/visualizer smoothness. Tunable for the battery vs. polish
    // trade via `defaults write com.bryanlabs.attache attache.playbackClockHz <n>`.
    private let clockHz: Double = {
        let stored = UserDefaults.standard.double(forKey: "attache.playbackClockHz")
        return (5...60).contains(stored) ? stored : 20
    }()

    override init() {
        super.init()
        speechFileSynthesizer.delegate = self
        speechFileSynthesizer.rate = 185
    }

    func setAudioCacheRetention(minutes: Int) {
        audioCacheRetentionSeconds = TimeInterval(max(0, minutes) * 60)
        cleanExpiredAudioCache(force: true)
    }

    func cleanExpiredAudioCache(force: Bool = true) {
        guard force || Date().timeIntervalSince(lastAudioCacheCleanup) > 3600 else { return }
        guard let directory = audioCacheDirectory else { return }
        lastAudioCacheCleanup = Date()

        let now = Date()
        let retention = audioCacheRetentionSeconds
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for file in files where shouldManageCachedAudioFile(file) {
            if let generatedAudioURL,
               file.standardizedFileURL.path == generatedAudioURL.standardizedFileURL.path {
                continue
            }
            if retention <= 0 {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            if now.timeIntervalSince(modified) > retention {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func configureVoice(configuration: CompanionSpeechConfiguration) {
        speechConfiguration = configuration
        guard configuration.provider == .system else {
            voiceIdentifier = nil
            speechFileSynthesizer.setVoice(nil)
            return
        }

        let explicitIdentifier = configuration.systemVoiceIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicitIdentifier,
           !explicitIdentifier.isEmpty,
           speechFileSynthesizer.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: explicitIdentifier)) {
            voiceIdentifier = explicitIdentifier
            return
        }

        if let fallbackIdentifier = CompanionVoiceCatalog.fileExportFallbackVoiceID(),
           speechFileSynthesizer.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: fallbackIdentifier)) {
            voiceIdentifier = fallbackIdentifier
            return
        }

        voiceIdentifier = nil
        speechFileSynthesizer.setVoice(nil)
    }

    func play(_ card: VoicemailCard, startTimeMs: Int = 0) {
        stop()
        cleanExpiredAudioCache(force: false)
        isBusy = true
        activeIsPreview = false

        let generationID = UUID()
        let requestedStartTimeMs = max(0, startTimeMs)
        let cacheURL = cachedAudioURL(for: card)
        let audioURL = cacheURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-\(card.id)-\(generationID.uuidString).\(audioFileExtension)")

        self.generationID = generationID
        generatedAudioURL = audioURL
        generatedAudioIsCached = cacheURL != nil
        currentCardID = card.id
        currentText = card.spokenText
        currentAlignment = card.alignment ?? CaptionAlignmentBuilder.fallback(text: card.spokenText, durationMs: card.durationMs)
        durationMs = max(card.durationMs, currentAlignment?.totalDurationMs ?? 1800)
        currentTimeMs = 0
        activeWordIndex = nil
        envelope = 0
        renderState.reset()

        // Cache hit: this card was already synthesized with this voice. Play the
        // saved clip directly, no synthesis, no voice credits, no network round-trip.
        if let cacheURL, isUsableAudioFile(cacheURL) {
            touchAudioFile(cacheURL)
            beginPlayback(card: card, audioURL: cacheURL, startTimeMs: requestedStartTimeMs)
            return
        }

        generationCompletion = { [weak self] success in
            guard let self, self.generationID == generationID else { return }
            guard success else {
                self.finishWithoutPlayback()
                return
            }
            self.beginPlayback(card: card, audioURL: audioURL, startTimeMs: requestedStartTimeMs)
        }

        synthesizeCurrentVoice(text: card.spokenText, audioURL: audioURL, generationID: generationID)
    }

    func replay(_ card: VoicemailCard) {
        play(card)
    }

    func preview(_ text: String) {
        stop()
        isBusy = true
        activeIsPreview = true

        let generationID = UUID()
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-preview-\(generationID.uuidString).\(audioFileExtension)")
        let duration = CaptionAlignmentBuilder.estimatedDurationMs(for: text)

        self.generationID = generationID
        generatedAudioURL = audioURL
        generatedAudioIsCached = false
        currentCardID = nil
        currentText = text
        currentAlignment = CaptionAlignmentBuilder.fallback(text: text, durationMs: duration)
        durationMs = duration
        currentTimeMs = 0
        activeWordIndex = nil
        envelope = 0
        renderState.reset()

        generationCompletion = { [weak self] success in
            guard let self, self.generationID == generationID else { return }
            guard success else {
                self.finishWithoutPlayback()
                return
            }
            self.beginPreviewPlayback(text: text, audioURL: audioURL)
        }

        synthesizeCurrentVoice(text: text, audioURL: audioURL, generationID: generationID)
    }

    func togglePause() {
        if isPaused {
            resume()
        } else {
            pause()
        }
    }

    func seek(to milliseconds: Int) {
        guard durationMs > 0 else { return }
        let clamped = min(durationMs, max(0, milliseconds))
        player?.currentTime = Double(clamped) / 1000.0
        currentTimeMs = clamped
        reanchorClock()
        if isPlaying {
            updateClock()
        } else {
            activeWordIndex = currentAlignment?.activeWordIndex(at: currentTimeMs)
            var nextState = renderState
            nextState.apply(timeline.frame(at: currentTimeMs))
            renderState = nextState
            envelope = Double(renderState.level)
        }
    }

    func seek(by milliseconds: Int) {
        seek(to: currentTimeMs + milliseconds)
    }

    func pause() {
        guard isPlaying, !isPaused else { return }
        updateClock()
        player?.pause()
        isPaused = true
        timer?.invalidate()
        timer = nil
    }

    func resume() {
        guard isPlaying, isPaused else { return }
        isPaused = false
        player?.play()
        reanchorClock()
        startTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generationCompletion = nil
        generationID = nil
        if speechFileSynthesizer.isSpeaking {
            speechFileSynthesizer.stopSpeaking()
        }
        let hadPlayableAudio = player != nil
        if !hadPlayableAudio {
            generatedAudioIsCached = false
        }
        player?.stop()
        player = nil
        cleanupGeneratedAudio()
        finishingNormally = false
        isPlaying = false
        isPaused = false
        isBusy = false
        currentTimeMs = 0
        activeWordIndex = nil
        envelope = 0
        currentCardID = nil
        currentText = ""
        currentAlignment = nil
        durationMs = 0
        timeline = .empty
        renderState.reset()
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        let completion = generationCompletion
        generationCompletion = nil
        completion?(finishedSpeaking)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let cardID = currentCardID
        let wasPreview = activeIsPreview
        timer?.invalidate()
        timer = nil
        updateClock(forceEnd: true)
        isPlaying = false
        isPaused = false
        isBusy = false
        activeWordIndex = nil

        renderState.reset()
        envelope = 0
        timeline = .empty
        cleanupGeneratedAudio()

        if wasPreview {
            onPreviewFinished?()
        } else if flag, finishingNormally, let cardID {
            onFinished?(cardID, true)
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finishWithoutPlayback()
    }

    private func beginPlayback(card: VoicemailCard, audioURL: URL, startTimeMs: Int) {
        if generatedAudioIsCached {
            touchAudioFile(audioURL)
        }
        analyzeAndStart(
            audioURL: audioURL,
            alignmentText: card.spokenText,
            startTimeMs: startTimeMs,
            finishingNormally: true,
            failureMessage: { "Playback failed: generated voice audio was not readable (\($0.localizedDescription))." }
        )
    }

    private func beginPreviewPlayback(text: String, audioURL: URL) {
        analyzeAndStart(
            audioURL: audioURL,
            alignmentText: text,
            startTimeMs: 0,
            finishingNormally: false,
            failureMessage: { "Voice preview failed: \($0.localizedDescription)" }
        )
    }

    /// Decode and analyze the audio off the main thread, then start playback on
    /// the main thread. The generation guard drops a stale analysis if a newer
    /// playback or preview began while this one was still decoding.
    private func analyzeAndStart(audioURL: URL, alignmentText: String, startTimeMs: Int, finishingNormally: Bool, failureMessage: @escaping (Error) -> String) {
        let generation = generationID
        Task(priority: .userInitiated) { [weak self] in
            do {
                let analyzed = try AudioFileAnalysis.analyze(url: audioURL)
                let audioPlayer = try AVAudioPlayer(contentsOf: audioURL)
                audioPlayer.enableRate = true
                audioPlayer.prepareToPlay()
                await MainActor.run { [weak self] in
                    guard let self, self.generationID == generation else { return }
                    audioPlayer.delegate = self
                    self.timeline = analyzed
                    self.player = audioPlayer
                    self.durationMs = max(1, Int((audioPlayer.duration * 1000).rounded()))
                    self.currentAlignment = CaptionAlignmentBuilder.fallback(text: alignmentText, durationMs: self.durationMs)
                    self.currentTimeMs = min(self.durationMs, max(0, startTimeMs))
                    audioPlayer.currentTime = Double(self.currentTimeMs) / 1000.0
                    self.activeWordIndex = nil
                    self.finishingNormally = finishingNormally
                    self.isPlaying = true
                    self.isPaused = false
                    audioPlayer.rate = self.playbackRate
                    audioPlayer.play()
                    self.reanchorClock()
                    self.updateClock()
                    self.startTimer()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.generationID == generation else { return }
                    self.onPlaybackError?(failureMessage(error))
                    self.finishWithoutPlayback()
                }
            }
        }
    }

    private func synthesizeCurrentVoice(text: String, audioURL: URL, generationID: UUID) {
        if speechConfiguration.provider == .system {
            if !speechFileSynthesizer.startSpeaking(text, to: audioURL) {
                generationCompletion?(false)
            }
            return
        }

        let configuration = speechConfiguration
        Task(priority: .userInitiated) { [configuration, audioURL, generationID, text] in
            do {
                // One retry on a transient synthesis failure so a single flaky
                // request doesn't drop the recap to the plain fallback (INF-157).
                try await retrying(attempts: 2) {
                    try await CompanionRemoteVoiceService.synthesize(
                        text: text,
                        configuration: configuration,
                        outputURL: audioURL
                    )
                }
                await MainActor.run { [weak self] in
                    guard let self, self.generationID == generationID else { return }
                    self.generationCompletion?(true)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.generationID == generationID else { return }
                    self.onPlaybackError?("Voice generation failed: \(error.localizedDescription)")
                    self.generationCompletion?(false)
                }
            }
        }
    }

    private var audioFileExtension: String {
        speechConfiguration.provider == .system ? "aiff" : "mp3"
    }

    private func finishWithoutPlayback() {
        let cardID = currentCardID
        let wasPreview = activeIsPreview
        timer?.invalidate()
        timer = nil
        isPlaying = false
        isPaused = false
        isBusy = false
        finishingNormally = false
        envelope = 0
        renderState.reset()
        timeline = .empty
        // This path only runs on failure (synthesis, decode, or analysis), so the
        // file is partial/unplayable and must not be left behind as a cache hit.
        generatedAudioIsCached = false
        cleanupGeneratedAudio()

        // Report the failure so the live queue can keep the card unread and advance.
        if wasPreview {
            onPreviewFinished?()
        } else if let cardID {
            onFinished?(cardID, false)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / clockHz, repeats: true) { [weak self] _ in
            self?.updateClock()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func updateClock(forceEnd: Bool = false) {
        guard isPlaying else { return }
        let playerTimeMs = Int(((player?.currentTime ?? 0) * 1000).rounded())
        let smoothTimeMs: Int
        if isPaused || abs(playbackRate - 1.0) < 0.01 {
            smoothTimeMs = playerTimeMs
        } else {
            let elapsed = ProcessInfo.processInfo.systemUptime - clockAnchorHost
            let extrapolated = clockAnchorAudioMs + Int(elapsed * 1000 * Double(playbackRate))
            if abs(playerTimeMs - extrapolated) > 350 {
                // Seek, stall, or real drift: trust the player and re-anchor.
                reanchorClock()
                smoothTimeMs = playerTimeMs
            } else {
                smoothTimeMs = extrapolated
            }
        }
        currentTimeMs = forceEnd ? durationMs : min(durationMs, max(0, smoothTimeMs))
        activeWordIndex = currentAlignment?.activeWordIndex(at: currentTimeMs)

        var nextState = renderState
        if isPaused {
            nextState.apply(timeline.frame(at: currentTimeMs))
        } else {
            nextState.apply(timeline.frame(at: currentTimeMs))
        }
        renderState = nextState
        envelope = Double(renderState.level)
    }

    private func cleanupGeneratedAudio() {
        if let generatedAudioURL, !generatedAudioIsCached {
            try? FileManager.default.removeItem(at: generatedAudioURL)
        }
        generatedAudioURL = nil
        generatedAudioIsCached = false
    }

    private func cachedAudioURL(for card: VoicemailCard) -> URL? {
        guard audioCacheRetentionSeconds > 0 else { return nil }
        guard let audioCacheDirectory else { return nil }
        let token = Self.stableHash("\(card.id)|\(card.spokenText)|\(voiceSignature())")
        return audioCacheDirectory.appendingPathComponent("recap-\(token).\(audioFileExtension)")
    }

    private func isUsableAudioFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int else {
            return false
        }
        return size > 0
    }

    private func touchAudioFile(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func shouldManageCachedAudioFile(_ url: URL) -> Bool {
        guard url.lastPathComponent.hasPrefix("recap-") else { return false }
        switch url.pathExtension.lowercased() {
        case "aiff", "aif", "mp3", "m4a", "wav":
            return true
        default:
            return false
        }
    }

    /// A stable token for the active voice so a voice or provider change yields a
    /// distinct cache file rather than replaying the previous voice.
    private func voiceSignature() -> String {
        let config = speechConfiguration
        let raw: String
        switch config.provider {
        case .system:
            raw = "system|\(voiceIdentifier ?? config.systemVoiceIdentifier ?? "default")"
        case .elevenLabs:
            raw = "eleven|\(config.elevenLabsVoiceID)|\(config.elevenLabsModelID)|\(config.elevenLabsOutputFormat)"
        case .xai:
            raw = "xai|\(config.xaiVoiceID)|\(config.xaiLanguage)"
        case .openai:
            raw = "openai|\(config.openaiVoiceID)|\(config.openaiModel)"
        }
        return Self.stableHash(raw)
    }

    // FNV-1a, so the cache key is stable across launches (Swift's Hasher is seeded
    // per-process and would not be).
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
