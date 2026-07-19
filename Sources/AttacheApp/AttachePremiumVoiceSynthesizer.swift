import Foundation
import AttacheCore

/// Pure gate for the test-only fake premium-voice synthesizer
/// (`ATTACHE_FAKE_PREMIUM_VOICE`). Modeled exactly on
/// `InstructionReplyEngine.expiryWindow(fromEnvironment:)`: the affordance is
/// inert unless `ATTACHE_UI_TEST=1` is ALSO set, so it can never make a real
/// user's premium voice emit fake audio. Kept a pure function of an injected
/// environment so the non-bypass contract is unit-tested without touching the
/// process environment.
enum PremiumVoiceFakeGate {
    /// Turns the `.attachePremium` synthesize path into a deterministic tone,
    /// skipping dlopen/model/weights. Only honored alongside `uiTestFlag`.
    static let fakeFlag = "ATTACHE_FAKE_PREMIUM_VOICE"
    /// The harness-set flag that must ALSO be present; the same gate the
    /// two-way expiry override requires.
    static let uiTestFlag = "ATTACHE_UI_TEST"

    /// True only when BOTH flags are exactly "1". A near-miss value (e.g.
    /// `ATTACHE_UI_TEST=true`) does not count, matching the expiry override.
    static func isActive(environment: [String: String]) -> Bool {
        environment[uiTestFlag] == "1" && environment[fakeFlag] == "1"
    }
}

/// Reports whether the Attaché Premium voice can synthesize right now (native
/// runtime present AND weights installed). Used by
/// `AttacheSpeechConfiguration.playbackUnavailableReason` so an uninstalled or
/// unbuilt premium voice falls back to the on-device system voice through the
/// existing visible-status path instead of failing a card. The probe is
/// overridable so the fallback wiring can be tested without touching disk.
enum AttachePremiumVoiceAvailability {
    static var probeOverride: (() -> Bool)?

    static func isReady() -> Bool {
        isReady(environment: ProcessInfo.processInfo.environment)
    }

    /// Testable form. Under the fake gate the premium voice reports ready so
    /// UI-smoke flows can drive playback with no dylib or weights present.
    static func isReady(environment: [String: String]) -> Bool {
        if PremiumVoiceFakeGate.isActive(environment: environment) { return true }
        if let probeOverride { return probeOverride() }
        return AttachePremiumVoiceRuntime.isRuntimeLibraryAvailable
            && PremiumVoiceWeightsManager.installedWeightsDirectory() != nil
    }

    /// Non-nil reason when the premium voice cannot be used, phrased for the
    /// same "Playback will use an on-device voice." suffix the cloud engines use.
    static func unavailableReason() -> String? {
        isReady() ? nil : "Attaché Premium voice is not installed yet."
    }
}

/// The on-device synthesis entrypoint for the `.attachePremium` provider. Same
/// file contract as the cloud engines (write a playable audio file at
/// `outputURL`), so captions, replay, and another-take work unchanged. Throws a
/// typed `PremiumVoiceRuntimeError`; the playback path surfaces it and falls
/// back to the system voice.
enum AttachePremiumVoiceSynthesizer {
    /// Sample rate the real runtime emits; the fake tone matches it so captions
    /// and energy math behave identically.
    static let sampleRate = 24_000

    /// Test-only override pointing weights resolution at a specific install root
    /// (typically an empty temp dir), so a test can prove the missing-weights
    /// path fails closed regardless of whether the machine has real weights
    /// installed. Ignored when unset (real resolution). Not a security boundary;
    /// it only changes where installed weights are looked for.
    static let weightsInstallRootEnvOverride = "ATTACHE_PREMIUM_VOICE_TEST_WEIGHTS"

    static func synthesize(
        text: String,
        configuration: AttacheSpeechConfiguration,
        outputURL: URL,
        runtime: AttachePremiumVoiceRuntime = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        if PremiumVoiceFakeGate.isActive(environment: environment) {
            let wav = PremiumVoiceWav.encodeFloatPCM(fakeToneSamples(), sampleRate: sampleRate)
            try wav.write(to: outputURL, options: .atomic)
            return
        }
        let installRoot = environment[weightsInstallRootEnvOverride].map { URL(fileURLWithPath: $0) }
        guard let paths = PremiumVoiceWeightsManager.installedRuntimePaths(installRoot: installRoot) else {
            throw PremiumVoiceRuntimeError.weightsUnavailable
        }
        try runtime.synthesize(text: text, paths: paths, outputURL: outputURL)
    }

    /// Deterministic ~1.5s tone (fixed seed via a fixed formula) with nonzero
    /// energy, so f3-style analyzed-energy assertions pass. No RNG, no runtime,
    /// no weights. Pure and independently testable.
    static func fakeToneSamples(durationSeconds: Double = 1.5) -> [Float] {
        let count = Int(Double(sampleRate) * durationSeconds)
        let frequency: Float = 220
        let twoPiOverRate = 2 * Float.pi * frequency / Float(sampleRate)
        return (0..<count).map { i in sinf(twoPiOverRate * Float(i)) * 0.5 }
    }
}
