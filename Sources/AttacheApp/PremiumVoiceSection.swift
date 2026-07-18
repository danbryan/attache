import Combine
import Foundation
import AttacheCore

/// What the Attaché Premium row offers right now, derived purely from the
/// weights state and whether the user has engaged the consent gate. Kept
/// separate from the row's static copy so the download/consent/progress/retry
/// affordance can be exhaustively unit tested without SwiftUI.
enum PremiumVoiceAffordance: Equatable {
    /// A plain selectable row: installed (selecting completes immediately) or
    /// not-yet-engaged (selecting opens the consent gate).
    case selectable
    /// The consent gate: one-time download disclosure plus Download/Cancel.
    case consent(text: String)
    /// A transfer is in flight: inline progress plus Cancel.
    case downloading(progress: Double)
    /// Verifying the downloaded archive's integrity.
    case verifying
    /// The download or install failed: the reason plus Retry/Cancel.
    case failed(reason: String)
}

/// The whole Attaché Premium section of the on-device voice list, as pure data.
/// `make` is the single decision point (task E2/#3): given manifest
/// availability, the weights state, the current selection, and whether the
/// consent gate is engaged, it produces every row/badge/affordance the view
/// renders. Present only when a release descriptor exists.
struct PremiumVoiceSectionDescriptor: Equatable {
    var isPresent: Bool
    var sectionTitle: String
    var voiceName: String
    var caption: String
    /// Suffix appended to the row's caption reflecting the weights state, or nil
    /// when installed (nothing extra).
    var stateSuffix: String?
    var isSelected: Bool
    var affordance: PremiumVoiceAffordance

    static let title = "Attaché Premium"
    static let voice = "Azelma"
    static let rowCaption = "Recommended. Runs entirely on this Mac."

    static func make(
        releaseExists: Bool,
        downloadSizeText: String,
        state: PremiumVoiceWeightsState,
        isSelected: Bool,
        consentEngaged: Bool
    ) -> PremiumVoiceSectionDescriptor {
        var descriptor = PremiumVoiceSectionDescriptor(
            isPresent: releaseExists,
            sectionTitle: title,
            voiceName: voice,
            caption: rowCaption,
            stateSuffix: nil,
            isSelected: isSelected,
            affordance: .selectable
        )
        switch state {
        case .notDownloaded:
            descriptor.stateSuffix = "\(downloadSizeText) download"
            descriptor.affordance = consentEngaged
                ? .consent(text: consentText(downloadSizeText))
                : .selectable
        case .downloading(let progress):
            let percent = Int((min(max(progress, 0), 1) * 100).rounded())
            descriptor.stateSuffix = "Downloading… \(percent)%"
            descriptor.affordance = .downloading(progress: progress)
        case .verifying:
            descriptor.stateSuffix = "Verifying…"
            descriptor.affordance = .verifying
        case .installed:
            descriptor.stateSuffix = nil
            descriptor.affordance = .selectable
        case .failed(let reason):
            descriptor.stateSuffix = reason
            descriptor.affordance = .failed(reason: reason)
        }
        return descriptor
    }

    static func consentText(_ downloadSizeText: String) -> String {
        "Download \(downloadSizeText), one time; then Azelma runs offline on this Mac."
    }
}

/// Drives selecting the Attaché Premium voice: the consent gate, the
/// download/cancel/retry loop, and completing (persisting) the selection only
/// once the weights are actually installed. Selecting Azelma while the weights
/// are missing never silently downloads and never changes the working voice;
/// the personality keeps its previous voice until install finishes.
@MainActor
final class PremiumVoiceSelectionController: ObservableObject {
    let weights: PremiumVoiceWeightsManager

    /// True while the consent gate (or its download/verify/failure follow-ups)
    /// is showing for a selection the user initiated but that is not yet
    /// installed.
    @Published private(set) var engaged = false

    private var onComplete: (() -> Void)?
    private var cancellable: AnyCancellable?

    init(weights: PremiumVoiceWeightsManager) {
        self.weights = weights
        // Completing a selection is gated on the weights becoming installed,
        // which can happen minutes after Download is tapped. Observe the state
        // so the pending selection finalizes on its own.
        cancellable = weights.$state.sink { [weak self] state in
            self?.stateChanged(to: state)
        }
    }

    func descriptor(isSelected: Bool) -> PremiumVoiceSectionDescriptor {
        PremiumVoiceSectionDescriptor.make(
            releaseExists: true,
            downloadSizeText: weights.release.downloadSizeDescription,
            state: weights.state,
            isSelected: isSelected,
            consentEngaged: engaged
        )
    }

    /// The user picked the Azelma row. Installed completes immediately;
    /// otherwise the consent gate opens and `complete` is deferred until the
    /// weights install.
    func select(complete: @escaping () -> Void) {
        switch weights.state {
        case .installed:
            engaged = false
            onComplete = nil
            complete()
        case .notDownloaded, .failed, .downloading, .verifying:
            onComplete = complete
            engaged = true
        }
    }

    /// Consent granted: start (or resume) the one-time download.
    func confirmDownload() {
        weights.beginDownload()
    }

    /// Retry after a failure.
    func retry() {
        weights.beginDownload()
    }

    /// Back out of the consent gate. Cancels any in-flight transfer and reverts
    /// to whatever voice was selected before, since the selection was never
    /// persisted.
    func cancel() {
        if case .downloading = weights.state {
            weights.cancelDownload()
        }
        engaged = false
        onComplete = nil
    }

    private func stateChanged(to state: PremiumVoiceWeightsState) {
        guard engaged, case .installed = state else { return }
        let complete = onComplete
        onComplete = nil
        engaged = false
        complete?()
    }
}

/// The pure copy and presentation contract for the Azelma row that leads the
/// onboarding voice step (E3). The selection, consent gate, download progress,
/// retry, and deferred-completion behavior all reuse
/// `PremiumVoiceSelectionController` and `PremiumVoiceSectionDescriptor`; only
/// this leading-row copy and the onboarding AX identifiers differ from the
/// Settings voice list.
enum OnboardingPremiumVoiceRow {
    static let voiceName = "Azelma"
    static let badge = "Premium · included"
    static let caption = "Runs entirely on this Mac after a one-time download."
    static let rowIdentifier = "Onboarding Premium Azelma"
    static let previewIdentifier = "Onboarding Premium Preview"

    /// The row always leads the onboarding voice step. It is independent of the
    /// macOS system voice catalog, so `ATTACHE_COMPACT_VOICES_ONLY` (which only
    /// filters SYSTEM voices) never hides it.
    static func isShown(compactVoicesOnly: Bool) -> Bool { true }
}

/// Locates the bundled Azelma preview clip WITHOUT `Bundle.module` (whose
/// generated accessor `fatalError`s on a clean quarantined install, see the
/// AGENTS.md gotcha and `SourceBadge`). Returns nil (no preview) rather than
/// crashing when the asset cannot be found.
enum PremiumVoicePreviewClip {
    static let resourceName = "azelma-preview"
    // A raw 24 kHz PCM wav rendered by the real on-device engine, not a lossy
    // AAC transcode: the earlier ~34 kbps .m4a sounded robotic and warbly next
    // to the system voices it is meant to A/B against (INF-387).
    static let resourceExtension = "wav"

    /// Anchors `Bundle(for:)` to the AttacheApp module: in the packaged app this
    /// resolves to the main bundle, and under `swift test` to the xctest bundle
    /// that statically links AttacheApp. Either way the resource bundle sits
    /// beside it, so resolution never depends on the process working directory.
    private final class BundleMarker {}

    static func url(fileManager: FileManager = .default) -> URL? {
        if let url = Bundle.main.url(forResource: resourceName, withExtension: resourceExtension) {
            return url
        }
        // Hand-packaged app: the SwiftPM resource bundle is nested, unsigned,
        // under Contents/Resources. It also sits beside the built product (the
        // executable, or the xctest bundle under `swift test`), so probe each
        // candidate bundle's own directory and its parent. Anchoring on
        // `Bundle(for:)` as well as `Bundle.main` keeps this cwd-independent:
        // on macOS `Bundle.main` under xctest is the test runner tool, not the
        // test bundle, so only the marker bundle finds the sibling resources.
        let markerBundle = Bundle(for: BundleMarker.self)
        if let url = markerBundle.url(forResource: resourceName, withExtension: resourceExtension) {
            return url
        }
        let siblingBases = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.bundleURL.deletingLastPathComponent(),
            markerBundle.resourceURL,
            markerBundle.bundleURL,
            markerBundle.bundleURL.deletingLastPathComponent()
        ].compactMap { $0 }
        for base in siblingBases {
            let url = base
                .appendingPathComponent("Attache_AttacheApp.bundle", isDirectory: true)
                .appendingPathComponent("\(resourceName).\(resourceExtension)")
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        // Dev fallback: the resource bundle next to the built product, resolved
        // from the working directory.
        let devBundle = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(".build/debug/Attache_AttacheApp.bundle")
            .appendingPathComponent("\(resourceName).\(resourceExtension)")
        if fileManager.fileExists(atPath: devBundle.path) {
            return devBundle
        }
        return nil
    }
}
