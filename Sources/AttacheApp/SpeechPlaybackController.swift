import AppKit
import AVFoundation
import Combine
import AttacheCore
import Foundation
import OSLog

enum PlaybackCompletionValidator {
    /// AVAudioPlayer can report a successful finish after a seek storm or an
    /// implausibly short run. Only mark a card heard when the playhead reached
    /// the end and the elapsed time is credible, unless the user explicitly
    /// sought during this playback.
    static func isCredibleFinish(
        flag: Bool,
        currentTime: TimeInterval,
        duration: TimeInterval,
        elapsed: TimeInterval,
        startOffset: TimeInterval,
        seekCount: Int
    ) -> Bool {
        guard flag else { return false }
        guard seekCount <= 8 else { return false }

        let tolerance = min(2.0, max(0.35, duration * 0.01))
        guard duration <= 0 || currentTime >= duration - tolerance else { return false }
        if seekCount > 0 { return true }

        // Playback rate is clamped to 2x. Anything faster than this lower
        // bound cannot be a natural finish from the requested start offset.
        let remaining = max(0, duration - startOffset)
        let minimumElapsed = max(0, remaining / 2.05 - 0.75)
        return elapsed >= minimumElapsed
    }
}

/// How much of a voicemail a listener must actually reach before it counts as
/// heard and moves from the inbox to History. Full completion is handled by
/// `PlaybackCompletionValidator`; this covers the partial-listen case: stopping,
/// pausing then leaving, starting another card, or hanging up after listening to
/// enough of a card still files it heard. `maxFraction` is a genuine high-water
/// playhead position, so a muted blip or a decode-early false finish (a tiny
/// fraction) never qualifies, and an implausible seek count (a seek storm that
/// jumps the playhead near the end without listening) is rejected the same way
/// the credible-finish validator rejects it. Kept pure so the threshold is unit
/// tested without driving the whole controller.
enum HeardThreshold {
    /// Fraction of the audio the playhead must reach to count as heard.
    static let fraction = 0.5
    /// Below this the clip is too short to infer intent from a 50% high-water
    /// mark; a genuine full play still files heard through the credible-finish
    /// path, so this only rejects degenerate or near-zero durations.
    static let minimumDurationMs = 1000
    /// A storm of seeks can push the high-water mark to the end without the user
    /// listening, so reject an implausible seek count (mirrors
    /// `PlaybackCompletionValidator`'s cap).
    static let maximumCredibleSeekCount = 8

    static func reached(maxFraction: Double, durationMs: Int, seekCount: Int) -> Bool {
        guard durationMs >= minimumDurationMs else { return false }
        guard seekCount <= maximumCredibleSeekCount else { return false }
        return maxFraction >= fraction
    }
}

/// Pure decision for the runtime voice fallback: when a non-system engine's
/// synthesis fails after its retries are exhausted (a cloud outage, or the
/// on-device premium runtime reporting a failed stream), degrade to the
/// on-device system voice and disclose the switch. A `.system` configuration has
/// nowhere to fall back to, so it yields no plan. Kept pure so the choice is unit
/// tested without driving the whole controller.
enum VoiceSynthesisFallback {
    struct Plan {
        var configuration: AttacheSpeechConfiguration
        var disclosure: String
    }

    static func plan(
        afterFailureOf configuration: AttacheSpeechConfiguration,
        systemVoiceIdentifier: String?
    ) -> Plan? {
        guard configuration.provider != .system else { return nil }
        var fallback = configuration
        fallback.provider = .system
        fallback.systemVoiceIdentifier = systemVoiceIdentifier
        return Plan(
            configuration: fallback,
            disclosure: "\(configuration.provider.title) voice failed, so playback is using an on-device voice."
        )
    }
}

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
    /// Fires when a real (non-preview) card reaches the listen-enough threshold on
    /// an exit path that isn't a credible full finish: an explicit `stop()`, a
    /// preemption by another `play()`, pausing then leaving, or hang-up. Lets the
    /// inbox -> History move happen from a partial listen, not only full
    /// completion. Distinct from `onFinished` so these paths mark heard without
    /// driving the live-queue / catch-up drains, which stay owned by `onFinished`.
    var onCardReachedHeardThreshold: ((_ cardID: String) -> Void)?
    /// Fires when a preview (voice sample or conversation reply) ends, so the live
    /// queue can resume after a reply preempted an update.
    var onPreviewFinished: (() -> Void)?
    var onPlaybackError: ((String) -> Void)?
    /// Fires when a non-system voice engine failed and playback transparently
    /// switched to the on-device system voice, so the UI can disclose the switch
    /// (an informational note, not an error) instead of leaving the user with
    /// silence or a raw failure.
    var onVoiceFallbackDisclosure: ((String) -> Void)?

    /// Whether the in-flight generation is a preview (reply/sample) rather than a
    /// card, so the right completion hook fires.
    private var activeIsPreview = false

    private let speechFileSynthesizer = NSSpeechSynthesizer()
    private var speechConfiguration = AttacheSpeechConfiguration.systemDefault
    var configuredSpeechProvider: AttacheSpeechProvider { speechConfiguration.provider }
    /// A creator audition or local-only card can temporarily use another voice.
    /// The live configuration is restored on completion, failure, or cancellation.
    private var previewRestoreConfiguration: AttacheSpeechConfiguration?
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
    private let logger = Logger(subsystem: "com.bryanlabs.attache", category: "playback")
    private let muteAudioOutput = SpeechPlaybackController.shouldMuteAudioOutput()
    private var playbackStartedAt: TimeInterval = 0
    private var playbackStartOffset: TimeInterval = 0
    private var playbackSeekCount = 0
    /// High-water mark of the playhead (ms) reached during the current playback,
    /// reset per card/preview start. Drives the 50%-listened heard decision and,
    /// being the genuine furthest position, guards against a false-finish blip.
    private var playbackMaxTimeMs = 0
    /// Set once the active card has been reported heard (credible finish or
    /// threshold), so a later `stop()` during teardown does not report it twice.
    private var activeCardHeardReported = false
    private var preparedAudioPaths: Set<String> = []
    private var failedAudioPreparationAttempts: [String: Date] = [:]
    private var audioPreparationWaiters: [String: [(Bool) -> Void]] = [:]
    private var systemAudioPreparationJobs: [UUID: SpeechFileExportJob] = [:]

    // When true, the current audio file lives in the persistent cache and must
    // survive playback so the next replay can reuse it instead of re-synthesizing.
    private var generatedAudioIsCached = false

    // When true, the current audio file is a shipped resource (the bundled
    // preview clip), not a throwaway temp file, so post-playback cleanup must
    // never delete it. Without this, `previewClip` stored the bundled Azelma
    // clip as `generatedAudioURL` with `generatedAudioIsCached == false`, and
    // the first playback's `cleanupGeneratedAudio()` removed the asset from the
    // app bundle. Every later Preview (same step, or after paging away and
    // back) then found no file and silently no-opped (INF-387b).
    private var generatedAudioIsProtectedResource = false

    /// Whether captions are currently on (mirrored from the app model). Forced
    /// alignment only runs while captions are enabled: with captions off there is
    /// no karaoke to make exact, so the recognizer never spins up.
    var isCaptioningEnabled = true

    /// Exact per-word timing an engine supplied for the in-flight synthesis
    /// (ElevenLabs with-timestamps), applied when playback starts instead of the
    /// estimated fallback. Cleared as soon as it is consumed.
    private var pendingEngineAlignment: CaptionAlignment?

    /// Test seam for the on-device aligner. When nil, `SpeechForcedAligner.shared`
    /// is used. A test injects a fake (optionally slow) aligner to prove playback
    /// starts on the estimated timeline and upgrades when alignment completes.
    var runForcedAlignment: ((
        _ audioURL: URL,
        _ scriptText: String,
        _ totalDurationMs: Int,
        _ completion: @escaping (CaptionAlignment?) -> Void
    ) -> Void)?

    /// Persistent home for synthesized recap audio, so replaying a card reuses the
    /// clip instead of re-running the voice (no credits, no network wait).
    private lazy var audioCacheDirectory: URL? = {
        let directory = AttacheAppSupport.supportDirectory()
            .appendingPathComponent("AudioCache", isDirectory: true)
        do {
            try Self.securePrivateAudioDirectory(at: directory)
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

    private static let uiTestAudioPrepDelayNanoseconds: UInt64 = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ATTACHE_UI_TEST"] == "1",
              let value = environment["ATTACHE_UI_TEST_AUDIO_PREP_DELAY_MS"],
              let milliseconds = UInt64(value),
              milliseconds > 0 else {
            return 0
        }
        return milliseconds * 1_000_000
    }()

    static func shouldMuteAudioOutput(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["ATTACHE_UI_TEST_MUTE_AUDIO"] == "1"
    }

    static func meteredFrame(averagePowerDB: Float, peakPowerDB: Float, barCount: Int = 56) -> AnalysisFrame {
        func amplitude(from decibels: Float) -> Float {
            guard decibels > -80 else { return 0 }
            return min(1, max(0, pow(10, decibels / 20)))
        }

        let level = amplitude(from: averagePowerDB)
        let peak = amplitude(from: peakPowerDB)
        var frame = AnalysisFrame()
        frame.rms = level
        frame.peak = max(level, peak)
        frame.bass = level * 0.85
        frame.mid = level
        frame.treble = level * 0.7
        frame.centroid = level > 0 ? 0.5 : 0
        frame.silence = level > 0.001 ? 0 : 1
        frame.bands = (0..<max(1, barCount)).map { index in
            let position = Float(index) / Float(max(1, barCount - 1))
            let centerWeight = 0.55 + 0.45 * sin(position * .pi)
            return level * centerWeight
        }
        return frame
    }

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
                removeAlignmentSidecar(for: file)
                continue
            }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            if now.timeIntervalSince(modified) > retention {
                try? FileManager.default.removeItem(at: file)
                removeAlignmentSidecar(for: file)
            }
        }
    }

    func configureVoice(configuration: AttacheSpeechConfiguration) {
        previewRestoreConfiguration = nil
        applyVoiceConfiguration(configuration)
    }

    private func applyVoiceConfiguration(_ configuration: AttacheSpeechConfiguration) {
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

        if let fallbackIdentifier = AttacheVoiceCatalog.fileExportFallbackVoiceID(),
           speechFileSynthesizer.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: fallbackIdentifier)) {
            voiceIdentifier = fallbackIdentifier
            return
        }

        voiceIdentifier = nil
        speechFileSynthesizer.setVoice(nil)
    }

    func play(
        _ card: VoicemailCard,
        startTimeMs: Int = 0,
        configuration: AttacheSpeechConfiguration? = nil
    ) {
        stop()
        if let configuration {
            let liveConfiguration = speechConfiguration
            applyVoiceConfiguration(configuration)
            previewRestoreConfiguration = liveConfiguration
        }
        cleanExpiredAudioCache(force: false)
        isBusy = true
        activeIsPreview = false

        let generationID = UUID()
        let requestedStartTimeMs = max(0, startTimeMs)
        let cacheURL = cachedAudioURL(for: card)
        let audioURL = cacheURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-\(card.id)-\(generationID.uuidString).\(audioFileExtension)")
        let cacheHit = cacheURL.map { self.isUsableAudioFile($0) } ?? false
        logger.info(
            "Playback requested card=\(card.id, privacy: .private(mask: .hash)) cacheHit=\(cacheHit)"
        )

        self.generationID = generationID
        generatedAudioURL = audioURL
        generatedAudioIsCached = cacheURL != nil
        currentCardID = card.id
        currentText = card.spokenText
        currentAlignment = card.alignment ?? CaptionAlignmentBuilder.fallback(text: card.spokenText, durationMs: card.durationMs)
        durationMs = max(card.durationMs, currentAlignment?.totalDurationMs ?? 1800)
        currentTimeMs = 0
        playbackMaxTimeMs = 0
        activeCardHeardReported = false
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

        if let cacheURL {
            let cachePath = cacheURL.standardizedFileURL.path
            if preparedAudioPaths.contains(cachePath) {
                logger.info("Playback waiting for background voice preparation")
                audioPreparationWaiters[cachePath, default: []].append { [weak self] prepared in
                    guard let self, self.generationID == generationID else { return }
                    if prepared, self.isUsableAudioFile(cacheURL) {
                        self.beginPlayback(card: card, audioURL: cacheURL, startTimeMs: requestedStartTimeMs)
                    } else {
                        self.synthesizeCurrentVoice(text: card.spokenText, audioURL: audioURL, generationID: generationID)
                    }
                }
                return
            }
        }

        synthesizeCurrentVoice(text: card.spokenText, audioURL: audioURL, generationID: generationID)
    }

    /// Prepares the selected voice in the persistent cache while a voicemail is
    /// waiting, so Play normally becomes a local cache hit instead of an
    /// interactive cloud request. Multiple reloads coalesce onto one path.
    func prepareAudioCache(for card: VoicemailCard) {
        cleanExpiredAudioCache(force: false)
        guard let cacheURL = cachedAudioURL(for: card) else { return }
        let cachePath = cacheURL.standardizedFileURL.path
        guard !preparedAudioPaths.contains(cachePath) else { return }
        if let lastFailure = failedAudioPreparationAttempts[cachePath],
           Date().timeIntervalSince(lastFailure) < 60 {
            return
        }
        guard !isUsableAudioFile(cacheURL) else {
            touchAudioFile(cacheURL)
            failedAudioPreparationAttempts[cachePath] = nil
            return
        }

        let configuration = speechConfiguration
        let systemVoiceIdentifier = voiceIdentifier
        let temporaryURL = cacheURL
            .deletingLastPathComponent()
            .appendingPathComponent(".preparing-\(UUID().uuidString).\(audioFileExtension(for: configuration))")
        preparedAudioPaths.insert(cachePath)
        logger.info("Background voice preparation started provider=\(configuration.provider.rawValue, privacy: .public)")

        switch configuration.provider {
        case .system:
            let jobID = UUID()
            let job = SpeechFileExportJob(
                configuration: configuration,
                preferredVoiceIdentifier: systemVoiceIdentifier,
                outputURL: temporaryURL
            ) { [weak self] success in
                DispatchQueue.main.async {
                    self?.systemAudioPreparationJobs[jobID] = nil
                    self?.finishAudioCachePreparation(
                        success: success,
                        cacheURL: cacheURL,
                        temporaryURL: temporaryURL,
                        cachePath: cachePath
                    )
                }
            }
            systemAudioPreparationJobs[jobID] = job
            if !job.start(text: card.spokenText) {
                systemAudioPreparationJobs[jobID] = nil
                finishAudioCachePreparation(
                    success: false,
                    cacheURL: cacheURL,
                    temporaryURL: temporaryURL,
                    cachePath: cachePath
                )
            }
        default:
            Task(priority: .utility) { [configuration, temporaryURL, cacheURL, cachePath, text = card.spokenText] in
                do {
                    let engineAlignment = try await AttacheRemoteVoiceService.synthesize(
                        text: text,
                        configuration: configuration,
                        outputURL: temporaryURL
                    )
                    await MainActor.run { [weak self] in
                        self?.finishAudioCachePreparation(
                            success: true,
                            cacheURL: cacheURL,
                            temporaryURL: temporaryURL,
                            cachePath: cachePath
                        )
                        // Persist any engine-supplied exact timing (ElevenLabs)
                        // next to the freshly cached audio so a later Play starts
                        // exact without a network round trip.
                        if let engineAlignment, self?.isUsableAudioFile(cacheURL) == true {
                            self?.writeCachedAlignment(engineAlignment, for: cacheURL)
                        }
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.logger.error(
                            "Background voice preparation failed: \(error.localizedDescription, privacy: .public)"
                        )
                        self?.finishAudioCachePreparation(
                            success: false,
                            cacheURL: cacheURL,
                            temporaryURL: temporaryURL,
                            cachePath: cachePath
                        )
                    }
                }
            }
        }
    }

    func replay(_ card: VoicemailCard, configuration: AttacheSpeechConfiguration? = nil) {
        play(card, configuration: configuration)
    }

    func preview(_ text: String) {
        startPreview(text, configuration: nil)
    }

    func preview(_ text: String, configuration: AttacheSpeechConfiguration) {
        startPreview(text, configuration: configuration)
    }

    /// Plays a pre-rendered clip that already exists on disk (a bundled sample),
    /// with no synthesis, no model load, and no network. Used for the Attaché
    /// Premium row's instant preview: the download and the heavy neural runtime
    /// are never touched just to hear the voice. This is an explicit Preview
    /// action, so off-call audio starting here is allowed.
    func previewClip(at fileURL: URL, text: String) {
        stop()
        isBusy = true
        activeIsPreview = true

        let generationID = UUID()
        self.generationID = generationID
        generatedAudioURL = fileURL
        generatedAudioIsCached = false
        generatedAudioIsProtectedResource = true
        currentCardID = nil
        currentText = text
        let duration = CaptionAlignmentBuilder.estimatedDurationMs(for: text)
        currentAlignment = CaptionAlignmentBuilder.fallback(text: text, durationMs: duration)
        durationMs = duration
        currentTimeMs = 0
        playbackMaxTimeMs = 0
        activeCardHeardReported = false
        activeWordIndex = nil
        envelope = 0
        renderState.reset()

        beginPreviewPlayback(text: text, audioURL: fileURL)
    }

    private func startPreview(_ text: String, configuration: AttacheSpeechConfiguration?) {
        stop()
        if let configuration {
            let liveConfiguration = speechConfiguration
            applyVoiceConfiguration(configuration)
            previewRestoreConfiguration = liveConfiguration
        }
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
        playbackMaxTimeMs = 0
        activeCardHeardReported = false
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
        if isPlaying {
            playbackSeekCount += 1
            logger.debug("Playback seek targetMs=\(clamped) count=\(self.playbackSeekCount)")
        }
        player?.currentTime = Double(clamped) / 1000.0
        currentTimeMs = clamped
        if currentTimeMs > playbackMaxTimeMs { playbackMaxTimeMs = currentTimeMs }
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

    /// The furthest fraction of the current clip the playhead genuinely reached.
    private var playbackMaxFraction: Double {
        guard durationMs > 0 else { return 0 }
        return min(1, max(0, Double(playbackMaxTimeMs) / Double(durationMs)))
    }

    /// Whether the active card has been listened to past the heard threshold.
    private func currentCardReachedHeardThreshold() -> Bool {
        HeardThreshold.reached(
            maxFraction: playbackMaxFraction,
            durationMs: durationMs,
            seekCount: playbackSeekCount
        )
    }

    /// File the active card heard when it reached the threshold on a non-finish
    /// exit path (stop / preemption / hang-up). Guarded so a preview, an
    /// already-reported card, or a below-threshold listen is left untouched.
    private func reportHeardThresholdIfReached() {
        guard !activeIsPreview,
              !activeCardHeardReported,
              let cardID = currentCardID,
              currentCardReachedHeardThreshold() else { return }
        activeCardHeardReported = true
        onCardReachedHeardThreshold?(cardID)
    }

    func stop() {
        reportHeardThresholdIfReached()
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
        // Never let an engine alignment from a superseded synthesis carry into the
        // next clip (a cache hit skips synthesis and would otherwise consume it).
        pendingEngineAlignment = nil
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
        playbackStartedAt = 0
        playbackStartOffset = 0
        playbackSeekCount = 0
        playbackMaxTimeMs = 0
        activeCardHeardReported = false
        restoreVoiceAfterPreviewIfNeeded()
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        let completion = generationCompletion
        generationCompletion = nil
        if !finishedSpeaking {
            onPlaybackError?("Voice generation failed: the system speech synthesizer stopped before producing audio.")
        } else if let url = generatedAudioURL {
            // Level the just-written system-voice file to the standard loudness so
            // the on-device voice is not quieter than the premium/cloud engines.
            SystemVoiceLoudnessNormalizer.normalizeFileInPlace(at: url)
        }
        completion?(finishedSpeaking)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let cardID = currentCardID
        let wasPreview = activeIsPreview
        let elapsed = playbackStartedAt > 0
            ? ProcessInfo.processInfo.systemUptime - playbackStartedAt
            : 0
        let credibleCardFinish = finishingNormally && PlaybackCompletionValidator.isCredibleFinish(
            flag: flag,
            currentTime: player.currentTime,
            duration: player.duration,
            elapsed: elapsed,
            startOffset: playbackStartOffset,
            seekCount: playbackSeekCount
        )
        logger.info(
            "Playback finished flag=\(flag) position=\(player.currentTime) duration=\(player.duration) elapsed=\(elapsed) seeks=\(self.playbackSeekCount) credible=\(credibleCardFinish)"
        )
        timer?.invalidate()
        timer = nil
        updateClock(forceEnd: wasPreview ? flag : credibleCardFinish)
        isPlaying = false
        isPaused = false
        isBusy = false
        activeWordIndex = nil

        renderState.reset()
        envelope = 0
        timeline = .empty
        cleanupGeneratedAudio()

        // A finish that isn't credible (a decode-early blip, or a seek-storm
        // false positive) can still count as heard when the genuine high-water
        // playhead passed the threshold. The high-water mark guards the blip (its
        // fraction stays tiny) and the seek-count guard rejects the storm, so this
        // never marks a barely-played card heard.
        let heardByThreshold = !wasPreview && currentCardReachedHeardThreshold()
        let markHeard = credibleCardFinish || heardByThreshold
        restoreVoiceAfterPreviewIfNeeded()
        if wasPreview {
            onPreviewFinished?()
        } else if markHeard, let cardID {
            activeCardHeardReported = true
            onFinished?(cardID, true)
        } else if let cardID {
            onPlaybackError?("Playback stopped before the voice message finished. The card remains unread.")
            onFinished?(cardID, false)
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finishWithoutPlayback()
    }

    private func beginPlayback(card: VoicemailCard, audioURL: URL, startTimeMs: Int) {
        if generatedAudioIsCached {
            guard Self.securePrivateAudioFile(at: audioURL) else {
                onPlaybackError?("Playback failed: saved voice audio could not be secured.")
                finishWithoutPlayback()
                return
            }
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

    /// Decode enough to start immediately, then analyze the visualizer timeline
    /// in the background. Long cloud clips used to block on a full-file decode
    /// and FFT before captions or audio appeared.
    private func analyzeAndStart(audioURL: URL, alignmentText: String, startTimeMs: Int, finishingNormally: Bool, failureMessage: @escaping (Error) -> String) {
        let generation = generationID
        Task(priority: .userInitiated) { [weak self] in
            let audioPlayer: AVAudioPlayer
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: audioURL)
                audioPlayer.enableRate = true
                audioPlayer.isMeteringEnabled = true
                audioPlayer.prepareToPlay()
                if Self.uiTestAudioPrepDelayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: Self.uiTestAudioPrepDelayNanoseconds)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.generationID == generation else { return }
                    self.onPlaybackError?(failureMessage(error))
                    self.finishWithoutPlayback()
                }
                return
            }

            let started = await MainActor.run { [weak self] () -> Bool in
                guard let self, self.generationID == generation else { return false }
                audioPlayer.delegate = self
                self.timeline = .empty
                self.player = audioPlayer
                self.durationMs = max(1, Int((audioPlayer.duration * 1000).rounded()))
                self.currentAlignment = self.resolveStartAlignment(text: alignmentText, audioURL: audioURL, durationMs: self.durationMs)
                self.currentTimeMs = min(self.durationMs, max(0, startTimeMs))
                audioPlayer.currentTime = Double(self.currentTimeMs) / 1000.0
                self.activeWordIndex = nil
                self.finishingNormally = finishingNormally
                self.isPlaying = true
                self.isPaused = false
                self.playbackStartedAt = ProcessInfo.processInfo.systemUptime
                self.playbackStartOffset = audioPlayer.currentTime
                self.playbackSeekCount = 0
                self.playbackMaxTimeMs = self.currentTimeMs
                self.activeCardHeardReported = false
                audioPlayer.volume = self.muteAudioOutput ? 0 : 1
                audioPlayer.rate = self.playbackRate
                audioPlayer.play()
                self.logger.info(
                    "Playback started duration=\(audioPlayer.duration) start=\(audioPlayer.currentTime) muted=\(self.muteAudioOutput)"
                )
                self.reanchorClock()
                self.updateClock()
                self.startTimer()
                self.scheduleForcedAlignmentIfNeeded(audioURL: audioURL, alignmentText: alignmentText, generation: generation)
                return true
            }
            guard started else { return }

            do {
                let analyzed = try await Task.detached(priority: .utility) {
                    try AudioFileAnalysis.analyze(url: audioURL)
                }.value
                await MainActor.run { [weak self] in
                    guard let self,
                          self.generationID == generation,
                          self.isBusy else { return }
                    self.timeline = analyzed
                    self.logger.debug("Playback analysis ready durationMs=\(analyzed.durationMs)")
                }
            } catch {
                self?.logger.error("Playback analysis failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The alignment to start playback with: an engine-supplied exact timeline
    /// (ElevenLabs) when the synthesis produced one, a cached exact timeline from
    /// a prior forced-alignment pass when replaying, else the estimated fallback.
    /// Audio never waits on any of this; it is a pure pick from already-available
    /// data.
    private func resolveStartAlignment(text: String, audioURL: URL, durationMs: Int) -> CaptionAlignment {
        if let engine = pendingEngineAlignment {
            pendingEngineAlignment = nil
            return engine
        }
        if generatedAudioIsCached, let cached = loadCachedAlignment(for: audioURL, text: text) {
            return cached
        }
        return CaptionAlignmentBuilder.fallback(text: text, durationMs: durationMs)
    }

    /// Kicks off on-device forced alignment for the clip that just started, when
    /// captions are on, the audio is cached (not an ephemeral preview), the engine
    /// is not ElevenLabs (which already ships exact timing), and the active
    /// timeline is still estimated. Never blocks: playback already started on the
    /// estimated timeline; when alignment completes the live timeline upgrades and
    /// the result is cached next to the audio so replays start exact. A late
    /// completion (after playback ended) still caches.
    private func scheduleForcedAlignmentIfNeeded(audioURL: URL, alignmentText: String, generation: UUID?) {
        guard isCaptioningEnabled else { return }
        // Never spin up speech recognition under UI automation: it would trigger
        // the one-time recognition permission prompt and interrupt the headless
        // smoke run. The smoke harness therefore always sees estimated timing (so
        // karaoke honestly degrades to plain), matching the torture-card contract.
        guard ProcessInfo.processInfo.environment["ATTACHE_UI_TEST"] != "1" else { return }
        guard generatedAudioIsCached else { return }
        guard speechConfiguration.provider != .elevenLabs else { return }
        guard let alignment = currentAlignment, !alignment.provenance.isExact else { return }
        let total = durationMs
        let run = runForcedAlignment ?? { url, text, duration, completion in
            SpeechForcedAligner.shared.align(
                audioURL: url,
                scriptText: text,
                totalDurationMs: duration,
                completion: completion
            )
        }
        run(audioURL, alignmentText, total) { [weak self] aligned in
            guard let aligned else { return }
            DispatchQueue.main.async {
                self?.applyForcedAlignmentResult(aligned, audioURL: audioURL, generation: generation)
            }
        }
    }

    /// Applies a completed forced alignment exactly as the live pipeline does.
    /// The result is cached next to the audio regardless of whether the clip is
    /// still playing (so a late completion still makes the next replay start
    /// exact); the live timeline upgrades only when this is still the active
    /// clip. Internal so the upgrade/late-cache behavior is unit-tested without
    /// driving a real `AVAudioPlayer` (which would require the real audio cache).
    func applyForcedAlignmentResult(_ aligned: CaptionAlignment, audioURL: URL, generation: UUID?) {
        writeCachedAlignment(aligned, for: audioURL)
        if generationID == generation {
            currentAlignment = aligned
            activeWordIndex = aligned.activeWordIndex(at: currentTimeMs)
        }
    }

    /// Sidecar path for a cached clip's forced alignment: `<audio>.alignment.json`,
    /// so it is keyed by the same cache token as the audio and is removed
    /// together with it.
    func alignmentSidecarURL(for audioURL: URL) -> URL {
        audioURL.appendingPathExtension("alignment.json")
    }

    func loadCachedAlignment(for audioURL: URL, text: String) -> CaptionAlignment? {
        let url = alignmentSidecarURL(for: audioURL)
        guard let data = try? Data(contentsOf: url),
              let alignment = try? JSONDecoder().decode(CaptionAlignment.self, from: data),
              alignment.provenance.isExact,
              alignment.text == text else {
            return nil
        }
        return alignment
    }

    func writeCachedAlignment(_ alignment: CaptionAlignment, for audioURL: URL) {
        let url = alignmentSidecarURL(for: audioURL)
        guard let data = try? JSONEncoder().encode(alignment) else { return }
        do {
            try data.write(to: url, options: .atomic)
            // The alignment carries the spoken script, which may be private, so
            // the sidecar is user-only like the audio it sits beside.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            logger.debug("Could not persist forced alignment sidecar: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeAlignmentSidecar(for audioURL: URL) {
        try? FileManager.default.removeItem(at: alignmentSidecarURL(for: audioURL))
    }

    private func synthesizeCurrentVoice(text: String, audioURL: URL, generationID: UUID) {
        if speechConfiguration.provider == .system {
            if !speechFileSynthesizer.startSpeaking(text, to: audioURL) {
                onPlaybackError?("Voice generation failed: the system speech synthesizer did not start.")
                generationCompletion?(false)
            }
            return
        }

        let configuration = speechConfiguration
        Task(priority: .userInitiated) { [configuration, audioURL, generationID, text] in
            do {
                // One retry on a transient synthesis failure so a single flaky
                // request doesn't drop the recap to the plain fallback (INF-157).
                let engineAlignment = try await retrying(attempts: 2) {
                    try await AttacheRemoteVoiceService.synthesize(
                        text: text,
                        configuration: configuration,
                        outputURL: audioURL
                    )
                }
                await MainActor.run { [weak self] in
                    guard let self, self.generationID == generationID else { return }
                    self.pendingEngineAlignment = engineAlignment
                    self.generationCompletion?(true)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.generationID == generationID else { return }
                    // A non-system engine failed after its retries. Rather than
                    // dropping the card to silence, degrade to the on-device
                    // system voice and disclose the switch. `.system` itself has
                    // nowhere to fall back to and keeps the existing error path.
                    if let plan = VoiceSynthesisFallback.plan(
                        afterFailureOf: configuration,
                        systemVoiceIdentifier: self.voiceIdentifier
                    ) {
                        self.fallBackToSystemVoice(
                            plan: plan,
                            text: text,
                            generationID: generationID,
                            underlyingError: error
                        )
                    } else {
                        self.onPlaybackError?("Voice generation failed: \(error.localizedDescription)")
                        self.generationCompletion?(false)
                    }
                }
            }
        }
    }

    /// Re-synthesize `text` with the on-device system voice after a non-system
    /// engine failed, so a persistent failure degrades to audible speech with a
    /// disclosure instead of silence or a crash. Writes to a fresh temp file,
    /// never the failed engine's cache path (which would poison the cache with
    /// audio from the wrong voice).
    private func fallBackToSystemVoice(
        plan: VoiceSynthesisFallback.Plan,
        text: String,
        generationID: UUID,
        underlyingError: Error
    ) {
        guard self.generationID == generationID else { return }
        applyVoiceConfiguration(plan.configuration)
        onVoiceFallbackDisclosure?(plan.disclosure)

        let fallbackURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-voice-fallback-\(generationID.uuidString).aiff")
        generatedAudioURL = fallbackURL
        generatedAudioIsCached = false
        let wasPreview = activeIsPreview
        generationCompletion = { [weak self] success in
            guard let self, self.generationID == generationID else { return }
            guard success else { self.finishWithoutPlayback(); return }
            self.analyzeAndStart(
                audioURL: fallbackURL,
                alignmentText: text,
                startTimeMs: 0,
                finishingNormally: !wasPreview,
                failureMessage: { "Playback failed: on-device voice audio was not readable (\($0.localizedDescription))." }
            )
        }
        if !speechFileSynthesizer.startSpeaking(text, to: fallbackURL) {
            onPlaybackError?("Voice generation failed: \(underlyingError.localizedDescription)")
            generationCompletion?(false)
        }
    }

    private var audioFileExtension: String {
        audioFileExtension(for: speechConfiguration)
    }

    private func audioFileExtension(for configuration: AttacheSpeechConfiguration) -> String {
        switch configuration.provider {
        case .system: return "aiff"
        case .attachePremium: return "wav"
        default: return "mp3"
        }
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
        restoreVoiceAfterPreviewIfNeeded()
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

    private func restoreVoiceAfterPreviewIfNeeded() {
        guard let configuration = previewRestoreConfiguration else { return }
        previewRestoreConfiguration = nil
        applyVoiceConfiguration(configuration)
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
        if currentTimeMs > playbackMaxTimeMs { playbackMaxTimeMs = currentTimeMs }
        activeWordIndex = currentAlignment?.activeWordIndex(at: currentTimeMs)

        var nextState = renderState
        if !timeline.frames.isEmpty {
            nextState.apply(timeline.frame(at: currentTimeMs))
        } else if !isPaused, let player {
            player.updateMeters()
            nextState.apply(Self.meteredFrame(
                averagePowerDB: player.averagePower(forChannel: 0),
                peakPowerDB: player.peakPower(forChannel: 0)
            ))
        }
        renderState = nextState
        envelope = Double(renderState.level)
    }

    private func cleanupGeneratedAudio() {
        if let generatedAudioURL, !generatedAudioIsCached, !generatedAudioIsProtectedResource {
            try? FileManager.default.removeItem(at: generatedAudioURL)
        }
        generatedAudioURL = nil
        generatedAudioIsCached = false
        generatedAudioIsProtectedResource = false
    }

    private func finishAudioCachePreparation(success: Bool, cacheURL: URL, temporaryURL: URL, cachePath: String) {
        preparedAudioPaths.remove(cachePath)
        let completed: Bool
        if !success || !isUsableAudioFile(temporaryURL) {
            failedAudioPreparationAttempts[cachePath] = Date()
            try? FileManager.default.removeItem(at: temporaryURL)
            completed = false
        } else if isUsableAudioFile(cacheURL) {
            touchAudioFile(cacheURL)
            try? FileManager.default.removeItem(at: temporaryURL)
            failedAudioPreparationAttempts[cachePath] = nil
            completed = true
        } else {
            do {
                try FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: temporaryURL, to: cacheURL)
                touchAudioFile(cacheURL)
                failedAudioPreparationAttempts[cachePath] = nil
                completed = true
            } catch {
                failedAudioPreparationAttempts[cachePath] = Date()
                try? FileManager.default.removeItem(at: temporaryURL)
                completed = false
            }
        }

        logger.info("Background voice preparation finished success=\(completed)")
        let waiters = audioPreparationWaiters.removeValue(forKey: cachePath) ?? []
        waiters.forEach { $0(completed) }
    }

    private func cachedAudioURL(for card: VoicemailCard) -> URL? {
        guard audioCacheRetentionSeconds > 0 else { return nil }
        guard let audioCacheDirectory else { return nil }
        let token = Self.stableHash("\(card.id)|\(card.spokenText)|\(voiceSignature())")
        return audioCacheDirectory.appendingPathComponent("recap-\(token).\(audioFileExtension)")
    }

    private func isUsableAudioFile(_ url: URL) -> Bool {
        guard Self.securePrivateAudioFile(at: url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int else {
            return false
        }
        return size > 0
    }

    /// Audio may contain a spoken form of private agent or direct-chat text.
    /// Upgrade legacy caches before reuse and create every new cache directory
    /// as user-only storage.
    static func securePrivateAudioDirectory(at directory: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let attributes = try fileManager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        ) else { return }
        for case let child as URL in enumerator {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            if values.isDirectory == true {
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path)
            } else if values.isRegularFile == true,
                      !securePrivateAudioFile(at: child) {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
    }

    static func securePrivateAudioFile(at url: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            return false
        }
        do {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let secured = try fileManager.attributesOfItem(atPath: url.path)
            return ((secured[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777 == 0o600
        } catch {
            return false
        }
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
            // The system-voice file is loudness-normalized after export, so a
            // loudness version bump must re-render clips cached at the old level.
            raw = "system|\(voiceIdentifier ?? config.systemVoiceIdentifier ?? "default")|loudnessV1"
        case .attachePremium:
            // The flow-integration step count changes synthesis quality, so it
            // is part of the identity: raising it must invalidate cached audio
            // rendered with the old setting, or a frozen bad realization would
            // replay forever (the 2026-07-19 robotic-recap incident).
            // Loudness normalization is applied to the cached WAV before it is
            // stored, so bumping the loudness version must invalidate clips
            // rendered at the old (quiet) level and re-render them normalized.
            raw = "attache-premium|\(AttacheSpeechProvider.attachePremiumVoiceID)|steps\(AttachePremiumVoiceRuntime.flowIntegrationSteps)|loudnessV1"
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

private final class SpeechFileExportJob: NSObject, NSSpeechSynthesizerDelegate {
    private let synthesizer = NSSpeechSynthesizer()
    private let configuration: AttacheSpeechConfiguration
    private let preferredVoiceIdentifier: String?
    private let outputURL: URL
    private let completion: (Bool) -> Void

    init(
        configuration: AttacheSpeechConfiguration,
        preferredVoiceIdentifier: String?,
        outputURL: URL,
        completion: @escaping (Bool) -> Void
    ) {
        self.configuration = configuration
        self.preferredVoiceIdentifier = preferredVoiceIdentifier
        self.outputURL = outputURL
        self.completion = completion
        super.init()
        synthesizer.delegate = self
        synthesizer.rate = 185
    }

    func start(text: String) -> Bool {
        configureVoice()
        return synthesizer.startSpeaking(text, to: outputURL)
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        if finishedSpeaking {
            // Level the exported system-voice file before it is cached, matching the
            // premium path so cached system audio is normalized once.
            SystemVoiceLoudnessNormalizer.normalizeFileInPlace(at: outputURL)
        }
        completion(finishedSpeaking)
    }

    private func configureVoice() {
        let preferred = preferredVoiceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preferred, !preferred.isEmpty,
           synthesizer.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: preferred)) {
            return
        }

        let explicit = configuration.systemVoiceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicit, !explicit.isEmpty,
           synthesizer.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: explicit)) {
            return
        }

        if let fallback = AttacheVoiceCatalog.fileExportFallbackVoiceID() {
            _ = synthesizer.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: fallback))
        }
    }
}
