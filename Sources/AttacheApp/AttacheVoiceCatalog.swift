import AppKit
import AttacheCore
import Foundation

struct AttacheVoiceOption: Identifiable, Equatable, Codable {
    var id: String
    var name: String
    var gender: String
    var localeIdentifier: String

    var title: String {
        let locale = localeIdentifier.replacingOccurrences(of: "_", with: "-")
        return locale.isEmpty ? name : "\(name) (\(locale))"
    }

    var isFemale: Bool {
        gender.lowercased().contains("female")
    }
}

/// The on-disk cache written by `AttacheVoiceCatalog.Catalog`. Versioned so a
/// format change (or a future field) discards any older snapshot instead of
/// misreading it (INF-350).
struct AttacheVoiceCatalogSnapshot: Codable, Equatable {
    var version: Int
    var voices: [AttacheVoiceOption]
}

/// Reads and writes the disk-cached voice catalog. Pure I/O, no enumeration,
/// so it is trivially unit-testable without touching NSSpeechSynthesizer.
enum AttacheVoiceCatalogSnapshotStore {
    static let currentVersion = 1
    static let fileName = "voice-catalog-snapshot.json"

    static func defaultURL() -> URL {
        AttacheAppSupport.supportDirectory().appendingPathComponent(fileName)
    }

    /// Returns the cached voice list, or nil if there is no snapshot yet or
    /// the stored version does not match `currentVersion` (a stale format is
    /// discarded rather than misread).
    static func read(from url: URL) -> [AttacheVoiceOption]? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(AttacheVoiceCatalogSnapshot.self, from: data),
              snapshot.version == currentVersion else {
            return nil
        }
        return snapshot.voices
    }

    @discardableResult
    static func write(_ voices: [AttacheVoiceOption], to url: URL) -> Bool {
        let snapshot = AttacheVoiceCatalogSnapshot(version: currentVersion, voices: voices)
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

enum AttacheVoiceCatalog {
    // NSSpeechSynthesizer's registry is process-cached but enumerating and
    // reading every voice's attributes can still take several seconds
    // (INF-350: previously the largest single main-thread block in the
    // app). `Catalog` loads a disk-cached snapshot synchronously (a fast
    // JSON read) so `options()` never blocks on enumeration, then
    // re-enumerates on a background queue to catch anything the snapshot
    // missed and rewrites the snapshot for next launch.
    static let catalog = Catalog()

    /// Coordinates the cached snapshot plus background re-enumeration.
    /// Dependency-injectable (`snapshotURL`, `enumerate`) so tests exercise
    /// the round-trip and staleness/backfill behavior without ever calling
    /// into real voice enumeration.
    final class Catalog {
        private let snapshotURL: URL
        private let enumerate: () -> [AttacheVoiceOption]
        private let lock = NSLock()
        private var voices: [AttacheVoiceOption]
        /// True from construction until the first background/foreground scan
        /// publishes a result. Only ever true when there was no usable
        /// snapshot on disk (first-ever launch or a stale/missing one).
        private(set) var isScanning: Bool

        /// Called on the main thread whenever the in-memory voice list
        /// changes (a completed background scan, first-launch scan, or a
        /// diff against the previous snapshot). UI observers (AppModel)
        /// use this to republish `speechVoiceOptions`.
        var onUpdate: (() -> Void)?

        init(
            snapshotURL: URL = AttacheVoiceCatalogSnapshotStore.defaultURL(),
            enumerate: @escaping () -> [AttacheVoiceOption] = {
                NSSpeechSynthesizer.availableVoices.map(AttacheVoiceCatalog.makeOption)
            },
            autoStart: Bool = true
        ) {
            self.snapshotURL = snapshotURL
            self.enumerate = enumerate
            if let cached = AttacheVoiceCatalogSnapshotStore.read(from: snapshotURL) {
                self.voices = cached
                self.isScanning = false
                if autoStart { refreshInBackground() }
            } else {
                self.voices = []
                self.isScanning = true
                if autoStart { scanFirstLaunch() }
            }
        }

        /// Current in-memory catalog: the snapshot if one was loaded, else
        /// whatever the most recent scan produced (possibly still empty
        /// while a first-launch scan is in flight).
        func currentVoices() -> [AttacheVoiceOption] {
            lock.lock()
            defer { lock.unlock() }
            return voices
        }

        func currentlyScanning() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return isScanning
        }

        /// First-ever launch (no usable snapshot): enumerate on a background
        /// queue and publish as soon as it's ready.
        func scanFirstLaunch() {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let fresh = self.enumerate()
                self.apply(fresh, persist: true)
            }
        }

        /// Re-enumerates in the background to refresh a snapshot that was
        /// already loaded synchronously. Lower priority than the
        /// first-launch scan since the UI already has voices to show.
        func refreshInBackground() {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let fresh = self.enumerate()
                self.apply(fresh, persist: true)
            }
        }

        /// Test seam: applies a result synchronously, as if a background
        /// scan just completed, without touching a dispatch queue.
        func simulateScanCompletion(_ fresh: [AttacheVoiceOption], persist: Bool = true) {
            apply(fresh, persist: persist)
        }

        private func apply(_ fresh: [AttacheVoiceOption], persist: Bool) {
            lock.lock()
            let changed = fresh != voices || isScanning
            voices = fresh
            isScanning = false
            lock.unlock()
            if persist {
                AttacheVoiceCatalogSnapshotStore.write(fresh, to: snapshotURL)
            }
            guard changed else { return }
            if Thread.isMainThread {
                onUpdate?()
            } else {
                DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
            }
        }
    }

    static func options() -> [AttacheVoiceOption] {
        options(from: catalog.currentVoices())
    }

    /// QA affordance: render the compact-only experience (onboarding
    /// guidance box, recommendations) without deleting installed voices.
    /// The --print-voices helper inherits the environment, so download
    /// detection stays consistent with the simulated catalog. Exposed on
    /// an explicit voice list so callers (PersonalityStore) can filter and
    /// sort an injected snapshot the same way, without going through the
    /// shared `catalog` singleton.
    static func options(from voices: [AttacheVoiceOption]) -> [AttacheVoiceOption] {
        let hidePremium = ProcessInfo.processInfo.environment["ATTACHE_COMPACT_VOICES_ONLY"] != nil
        return voices
            .filter { !hidePremium || (!$0.id.contains(".premium.") && !$0.id.contains(".enhanced.")) }
            .sorted { lhs, rhs in
                if lhs.localeIdentifier == "en_US", rhs.localeIdentifier != "en_US" { return true }
                if lhs.localeIdentifier != "en_US", rhs.localeIdentifier == "en_US" { return false }
                if lhs.isFemale != rhs.isFemale { return lhs.isFemale }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func option(for identifier: String) -> AttacheVoiceOption? {
        options().first { $0.id == identifier }
    }

    /// Re-enumerates voices in a fresh helper process. The in-process registry
    /// is cached for the process lifetime, so this is the only way a running
    /// app can see voices downloaded after launch. Returns nil on failure.
    static func freshOptions() -> [AttacheVoiceOption]? {
        guard let binary = Bundle.main.executableURL else { return nil }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--print-voices"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return nil
        }
        let parsed = output.split(whereSeparator: \.isNewline).compactMap { line -> AttacheVoiceOption? in
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 4 else { return nil }
            return AttacheVoiceOption(id: parts[0], name: parts[1], gender: parts[2], localeIdentifier: parts[3])
        }
        return parsed.isEmpty ? nil : parsed
    }

    /// The best voice that appeared since the current catalog was read
    /// (i.e. downloaded after launch). Any variant counts; premium beats
    /// enhanced beats compact when several arrived together.
    static func newlyAvailableVoice(fresh: [AttacheVoiceOption],
                                    current: [AttacheVoiceOption]) -> AttacheVoiceOption? {
        let known = Set(current.map(\.id))
        let added = fresh.filter { !known.contains($0.id) }
        return added.first { $0.id.contains(".premium.") }
            ?? added.first { $0.id.contains(".enhanced.") }
            ?? added.first
    }

    static func preferredFemaleVoiceID() -> String? {
        let available = options().filter(\.isFemale)
        let preferredNames = ["Samantha", "Ava", "Zoe", "Allison", "Susan", "Victoria", "Karen", "Serena"]
        for name in preferredNames {
            if let match = available.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                return match.id
            }
        }
        return available.first(where: { $0.localeIdentifier == "en_US" })?.id ?? available.first?.id
    }

    static func fileExportFallbackVoiceID() -> String? {
        fileExportFallbackVoiceID(in: options())
    }

    /// Same fallback logic as `fileExportFallbackVoiceID()`, but against an
    /// explicit voice list rather than the shared `catalog` singleton, so
    /// callers with an already-loaded snapshot (PersonalityStore) never
    /// force a catalog read.
    static func fileExportFallbackVoiceID(in voices: [AttacheVoiceOption]) -> String? {
        let candidates = [
            "com.apple.speech.synthesis.voice.Alex",
            "com.apple.voice.compact.en-GB.Daniel",
            "com.apple.voice.compact.en-US.Samantha",
            "com.apple.voice.compact.en-AU.Karen",
            "com.apple.voice.compact.en-IE.Moira"
        ]
        let availableIDs = Set(voices.map(\.id))
        return candidates.first { availableIDs.contains($0) }
            ?? voices.first(where: { $0.localeIdentifier == "en_US" })?.id
            ?? voices.first?.id
    }

    static func statusText(for identifier: String?) -> String {
        guard let identifier,
              let option = option(for: identifier) else {
            if let fallbackIdentifier = fileExportFallbackVoiceID(),
               let option = option(for: fallbackIdentifier) {
                return "Assistant voice: \(option.title)"
            }
            return "Assistant voice: system default"
        }
        return "Assistant voice: \(option.title)"
    }

    static func makeOption(_ voice: NSSpeechSynthesizer.VoiceName) -> AttacheVoiceOption {
        let attributes = NSSpeechSynthesizer.attributes(forVoice: voice)
        let name = attributes[.name] as? String ?? voice.rawValue
        let gender = attributes[.gender] as? String ?? ""
        let locale = attributes[.localeIdentifier] as? String ?? ""
        return AttacheVoiceOption(
            id: voice.rawValue,
            name: name,
            gender: gender,
            localeIdentifier: locale
        )
    }
}

extension AttacheVoiceCatalog {
    /// 0 = downloaded premium/enhanced, 1 = modern compact, 2 = legacy
    /// MacinTalk and novelty voices, never recommended unless hand-picked.
    static func qualityTier(_ option: AttacheVoiceOption) -> Int {
        if option.id.contains(".premium.") || option.id.contains(".enhanced.") { return 0 }
        if option.id.contains(".compact.") { return 1 }
        return 2
    }

    /// The exact compact recommendations for English systems, in order.
    static let handPickedEnglish = ["Joelle", "Ralph", "Jamie"]

    /// Installed premium and enhanced voices always lead, best-known first.
    static let premiumOrder = ["Ava", "Zoe", "Jamie", "Allison"]

    /// Fine as fallbacks when a hand-picked voice is missing, never ahead of one.
    static let demotedNames = ["Samantha", "Karen", "Daniel", "Susan"]

    static func voiceLanguage(_ option: AttacheVoiceOption) -> String {
        option.localeIdentifier
            .components(separatedBy: CharacterSet(charactersIn: "_-")).first?.lowercased() ?? ""
    }

    /// Onboarding recommendation order. English systems get installed
    /// premiums first, then the hand-picked trio (which may deliberately
    /// surface a legacy voice like Ralph), then neutral fallbacks, with
    /// demoted names last. A non-English primary system language promotes
    /// that language's voices to the front so users hear recommendations
    /// they understand.
    static func recommended(from options: [AttacheVoiceOption],
                            primaryLanguage: String? = nil) -> [AttacheVoiceOption] {
        let primary = primaryLanguage
            ?? Locale.preferredLanguages.first?.components(separatedBy: "-").first?.lowercased()
            ?? "en"

        func score(_ option: AttacheVoiceOption) -> Int {
            let language = voiceLanguage(option)
            let tier = qualityTier(option)
            var score: Int
            if primary != "en", language == primary {
                score = 0
            } else if language == "en" {
                score = 10_000
            } else {
                score = 40_000
            }
            if tier == 0 {
                let rank = premiumOrder.firstIndex { option.name.localizedCaseInsensitiveContains($0) } ?? premiumOrder.count
                return score + rank
            }
            if let index = handPickedEnglish.firstIndex(where: { option.name.localizedCaseInsensitiveContains($0) }) {
                return score + 100 + index
            }
            if demotedNames.contains(where: { option.name.localizedCaseInsensitiveContains($0) }) {
                return score + 3000
            }
            return score + (tier == 1 ? 1000 : 2000)
        }

        return options.enumerated()
            .sorted { ( score($0.element), $0.offset ) < ( score($1.element), $1.offset ) }
            .map(\.element)
    }
}
