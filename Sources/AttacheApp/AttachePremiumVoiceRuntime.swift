import Foundation
import AttacheCore
import os

/// Typed failures the Attaché Premium voice path can raise. All are surfaced as
/// a visible status by the playback layer, never swallowed, and drive the
/// fallback to the on-device system voice.
enum PremiumVoiceRuntimeError: Error, LocalizedError, Equatable {
    /// The native runtime dylib could not be found or dlopen'd (a machine that
    /// never ran scripts/build-premium-voice-runtime.sh, or a bundle missing the
    /// embedded library).
    case runtimeUnavailable
    /// The weights have not been downloaded/installed, or the install directory
    /// is missing required model files.
    case weightsUnavailable
    /// ptt_create / ptt_stream_start returned null.
    case engineInitializationFailed
    /// The stream produced no audio, or the read loop signaled an error.
    case synthesisFailed
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "The Attaché Premium voice engine is not available on this Mac."
        case .weightsUnavailable:
            return "The Attaché Premium voice is not installed yet."
        case .engineInitializationFailed:
            return "The Attaché Premium voice engine could not start."
        case .synthesisFailed:
            return "The Attaché Premium voice could not synthesize this audio."
        case .emptyAudio:
            return "The Attaché Premium voice produced an empty audio file."
        }
    }
}

/// Absolute paths a single synthesis needs. Resolved by the caller from the
/// installed weights directory; kept a plain value so the runtime stays unaware
/// of the app's storage layout.
struct PremiumVoiceRuntimePaths: Equatable {
    var modelsDirectory: URL
    var voicesDirectory: URL
    var tokenizerPath: URL
    var voiceFileName: String
    var precision: String

    init(
        modelsDirectory: URL,
        voicesDirectory: URL,
        tokenizerPath: URL,
        voiceFileName: String = "azelma.wav",
        precision: String = "int8"
    ) {
        self.modelsDirectory = modelsDirectory
        self.voicesDirectory = voicesDirectory
        self.tokenizerPath = tokenizerPath
        self.voiceFileName = voiceFileName
        self.precision = precision
    }
}

/// The C ABI of libpocket_tts.dylib, behind a protocol so the serialization,
/// idle-unload, and WAV-writing logic can be unit tested with a fake and the
/// real dlopen path stays a thin adapter.
protocol PremiumVoiceRuntimeLibrary: AnyObject {
    /// Opaque engine handle (ptt_create). nil on failure.
    func create(
        modelsDir: String,
        voicesDir: String,
        tokenizerPath: String,
        precision: String,
        temperature: Float,
        lsdSteps: Int32,
        numThreads: Int32
    ) -> OpaquePointer?
    func warmup(_ handle: OpaquePointer) -> Double
    func destroy(_ handle: OpaquePointer)
    /// Runs a full synthesis, invoking `onChunk` with each float PCM chunk.
    /// Returns false if the stream signaled an error. The library owns the
    /// stream lifecycle and frees native chunk buffers.
    func stream(handle: OpaquePointer, text: String, voice: String, onChunk: (UnsafePointer<Float>, Int) -> Void) -> Bool
}

/// dlopen/dlsym adapter over the real dylib.
final class DlopenPremiumVoiceRuntimeLibrary: PremiumVoiceRuntimeLibrary {
    private typealias CreateFn = @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
        UnsafePointer<CChar>?, Float, Int32, Int32
    ) -> OpaquePointer?
    private typealias WarmupFn = @convention(c) (OpaquePointer?) -> Double
    private typealias DestroyFn = @convention(c) (OpaquePointer?) -> Void
    private typealias FreeAudioFn = @convention(c) (UnsafeMutablePointer<Float>?) -> Void
    private typealias StreamStartFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> OpaquePointer?
    private typealias StreamReadFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?, UnsafeMutablePointer<Int32>?) -> Int32
    private typealias StreamEndFn = @convention(c) (OpaquePointer?) -> Void

    private let dylibHandle: UnsafeMutableRawPointer
    private let createFn: CreateFn
    private let warmupFn: WarmupFn
    private let destroyFn: DestroyFn
    private let freeAudioFn: FreeAudioFn
    private let streamStartFn: StreamStartFn
    private let streamReadFn: StreamReadFn
    private let streamEndFn: StreamEndFn

    init(dylibURL: URL) throws {
        guard let handle = dlopen(dylibURL.path, RTLD_NOW | RTLD_LOCAL) else {
            throw PremiumVoiceRuntimeError.runtimeUnavailable
        }
        func sym<T>(_ name: String, as _: T.Type) throws -> T {
            guard let raw = dlsym(handle, name) else {
                dlclose(handle)
                throw PremiumVoiceRuntimeError.runtimeUnavailable
            }
            return unsafeBitCast(raw, to: T.self)
        }
        do {
            self.createFn = try sym("ptt_create", as: CreateFn.self)
            self.warmupFn = try sym("ptt_warmup", as: WarmupFn.self)
            self.destroyFn = try sym("ptt_destroy", as: DestroyFn.self)
            self.freeAudioFn = try sym("ptt_free_audio", as: FreeAudioFn.self)
            self.streamStartFn = try sym("ptt_stream_start", as: StreamStartFn.self)
            self.streamReadFn = try sym("ptt_stream_read", as: StreamReadFn.self)
            self.streamEndFn = try sym("ptt_stream_end", as: StreamEndFn.self)
        } catch {
            throw error
        }
        self.dylibHandle = handle
    }

    deinit { dlclose(dylibHandle) }

    func create(
        modelsDir: String, voicesDir: String, tokenizerPath: String,
        precision: String, temperature: Float, lsdSteps: Int32, numThreads: Int32
    ) -> OpaquePointer? {
        modelsDir.withCString { m in voicesDir.withCString { v in
            tokenizerPath.withCString { t in precision.withCString { p in
                createFn(m, v, t, p, temperature, lsdSteps, numThreads)
            } }
        } }
    }

    func warmup(_ handle: OpaquePointer) -> Double { warmupFn(handle) }
    func destroy(_ handle: OpaquePointer) { destroyFn(handle) }

    func stream(handle: OpaquePointer, text: String, voice: String, onChunk: (UnsafePointer<Float>, Int) -> Void) -> Bool {
        let ctx: OpaquePointer? = text.withCString { t in voice.withCString { v in streamStartFn(handle, t, v) } }
        guard let stream = ctx else { return false }
        defer { streamEndFn(stream) }
        var samples: UnsafeMutablePointer<Float>?
        var length: Int32 = 0
        while true {
            let r = streamReadFn(stream, &samples, &length)
            if r == 1 {
                if let ptr = samples, length > 0 {
                    onChunk(ptr, Int(length))
                    freeAudioFn(ptr)
                }
                samples = nil
                length = 0
                continue
            }
            // 0 = done, negative = error.
            return r == 0
        }
    }
}

/// Owns the Attaché Premium voice engine lifecycle: lazy load on first
/// synthesis, single-flight synthesis (the native engine is not reentrant), and
/// an idle unload that releases the large ONNX Runtime arena (~1.7 GB) after a
/// quiet period. All native calls happen under `lock`.
final class AttachePremiumVoiceRuntime {

    static let shared = AttachePremiumVoiceRuntime()

    private let logger = Logger(subsystem: "com.bryanlabs.attache", category: "premium-voice")
    private let lock = NSLock()
    private let idleUnloadInterval: TimeInterval
    private let libraryFactory: () throws -> PremiumVoiceRuntimeLibrary

    // Guarded by `lock`.
    private var library: PremiumVoiceRuntimeLibrary?
    private var handle: OpaquePointer?
    private var loadedPaths: PremiumVoiceRuntimePaths?
    private var idleTimer: DispatchSourceTimer?

    /// Flow-matching integration steps per latent frame (the runtime's
    /// `lsd_steps`). The vendored runtime defaults this to 1, a single Euler
    /// step (`dt = 1/steps = 1.0`) tuned for lowest real-time streaming latency.
    /// A single coarse step frequently overshoots the flow ODE into a degenerate
    /// latent, so a large fraction of voiced frames decode as broadband,
    /// metallic "robotic" audio; because Attaché caches each recap's WAV, that
    /// one bad realization is then replayed identically every time (the reported
    /// "same robotic spots on every replay").
    ///
    /// Attaché's recaps are synthesized once and cached, not streamed in real
    /// time, so accuracy matters more than first-frame latency here. Measured on
    /// the licensed v1 weights over 8 independent draws of a reported phrase, the
    /// fraction of voiced frames with unnatural (>7 kHz) broadband energy was
    /// ~24% at 1 step, ~3.9% at 4 steps, and ~1.9% at 8 steps (the sibilant
    /// floor), while per-synthesis wall time was unchanged because the flow net
    /// is tiny next to the main LM and Mimi decoder. Eight steps removes the
    /// artifact at no meaningful cost and preserves Azelma's timbre (more steps
    /// integrate the same target distribution more accurately, they do not change
    /// it). See PremiumVoice robotic-audio investigation (INF-385 follow-up).
    static let flowIntegrationSteps: Int32 = 8

    /// Environment override pointing directly at libpocket_tts.dylib, used by the
    /// guarded integration test and dev runs.
    static let dylibEnvOverride = "ATTACHE_PREMIUM_VOICE_DYLIB"
    /// Environment override pointing at the directory holding both dylibs.
    static let runtimeDirEnvOverride = "ATTACHE_PREMIUM_VOICE_RUNTIME_DIR"

    init(
        idleUnloadInterval: TimeInterval = 300,
        libraryFactory: (() throws -> PremiumVoiceRuntimeLibrary)? = nil
    ) {
        self.idleUnloadInterval = idleUnloadInterval
        self.libraryFactory = libraryFactory ?? {
            guard let url = AttachePremiumVoiceRuntime.locateRuntimeDylib() else {
                throw PremiumVoiceRuntimeError.runtimeUnavailable
            }
            return try DlopenPremiumVoiceRuntimeLibrary(dylibURL: url)
        }
    }

    /// True when the native runtime dylib can be located (does not dlopen).
    static var isRuntimeLibraryAvailable: Bool { locateRuntimeDylib() != nil }

    /// Resolve the runtime dylib: explicit env override, then the app bundle's
    /// Frameworks dir, then the dev staging dir from
    /// scripts/build-premium-voice-runtime.sh.
    static func locateRuntimeDylib(fileManager: FileManager = .default) -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env[dylibEnvOverride], fileManager.fileExists(atPath: explicit) {
            return URL(fileURLWithPath: explicit)
        }
        var candidates: [URL] = []
        if let dir = env[runtimeDirEnvOverride] {
            candidates.append(URL(fileURLWithPath: dir).appendingPathComponent("libpocket_tts.dylib"))
        }
        if let frameworks = Bundle.main.privateFrameworksURL {
            candidates.append(frameworks.appendingPathComponent("libpocket_tts.dylib"))
        }
        candidates.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Frameworks/libpocket_tts.dylib")
        )
        // Dev fallback: repo-relative staging next to the current working dir.
        candidates.append(
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent(".build/premium-voice/libpocket_tts.dylib")
        )
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    /// Synthesize `text` to a correctly headered WAV at `outputURL`. Serialized:
    /// one synthesis at a time. Throws a typed `PremiumVoiceRuntimeError`.
    func synthesize(text: String, paths: PremiumVoiceRuntimePaths, outputURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }

        try validate(paths: paths)
        try ensureLoaded(paths: paths)
        guard let handle else { throw PremiumVoiceRuntimeError.engineInitializationFailed }

        var samples: [Float] = []
        let ok = library!.stream(handle: handle, text: text, voice: paths.voiceFileName) { ptr, count in
            samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
        }
        guard ok else { throw PremiumVoiceRuntimeError.synthesisFailed }
        guard !samples.isEmpty else { throw PremiumVoiceRuntimeError.emptyAudio }

        let wav = PremiumVoiceWav.encodeFloatPCM(samples, sampleRate: 24_000)
        try wav.write(to: outputURL, options: .atomic)
        scheduleIdleUnloadLocked()
    }

    /// Release the engine and its ONNX Runtime arena. Safe to call repeatedly.
    func unload() {
        lock.lock()
        defer { lock.unlock() }
        unloadLocked()
    }

    // MARK: - Private (all callers hold `lock`)

    private func validate(paths: PremiumVoiceRuntimePaths) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.tokenizerPath.path),
              fm.fileExists(atPath: paths.modelsDirectory.path),
              fm.fileExists(atPath: paths.voicesDirectory.appendingPathComponent(paths.voiceFileName).path) else {
            throw PremiumVoiceRuntimeError.weightsUnavailable
        }
    }

    private func ensureLoaded(paths: PremiumVoiceRuntimePaths) throws {
        if handle != nil, loadedPaths == paths { return }
        // Paths changed (e.g. a new installed version): tear down first.
        unloadLocked()

        let lib: PremiumVoiceRuntimeLibrary
        do {
            lib = try libraryFactory()
        } catch {
            throw PremiumVoiceRuntimeError.runtimeUnavailable
        }
        guard let newHandle = lib.create(
            modelsDir: paths.modelsDirectory.path,
            voicesDir: paths.voicesDirectory.path,
            tokenizerPath: paths.tokenizerPath.path,
            precision: paths.precision,
            temperature: 0.7,
            lsdSteps: Self.flowIntegrationSteps,
            // 0 = the runtime auto-selects thread count. The C API does not
            // expose the ONNX Runtime arena knobs; the runtime already disables
            // the arena on the encoder/decoder sessions (see vendored source).
            numThreads: 0
        ) else {
            throw PremiumVoiceRuntimeError.engineInitializationFailed
        }
        _ = lib.warmup(newHandle)
        self.library = lib
        self.handle = newHandle
        self.loadedPaths = paths
        logger.info("Premium voice engine loaded")
    }

    private func unloadLocked() {
        idleTimer?.cancel()
        idleTimer = nil
        if let handle, let library {
            library.destroy(handle)
            logger.info("Premium voice engine unloaded")
        }
        handle = nil
        library = nil
        loadedPaths = nil
    }

    private func scheduleIdleUnloadLocked() {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + idleUnloadInterval)
        timer.setEventHandler { [weak self] in
            self?.unload()
        }
        idleTimer = timer
        timer.resume()
    }
}
