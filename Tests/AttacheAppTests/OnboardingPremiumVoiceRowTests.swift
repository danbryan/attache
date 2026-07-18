import AppKit
import XCTest
import AttacheCore
@testable import AttacheApp

/// The Azelma row that leads the onboarding voice step (E3). It reuses the E2
/// selection controller and section descriptor, so these tests cover the
/// onboarding-specific contract: the leading-row copy and AX identifiers, the
/// row surviving `ATTACHE_COMPACT_VOICES_ONLY` (which only filters SYSTEM
/// voices), the instant bundled-clip preview (no synthesis), declining leaving
/// the current default untouched, and a download started on the voice step
/// still applying the voice after the user pages ahead in onboarding.
@MainActor
final class OnboardingPremiumVoiceRowTests: XCTestCase {

    // MARK: - Copy and presentation contract

    func testLeadingRowCopyAndIdentifiers() {
        XCTAssertEqual(OnboardingPremiumVoiceRow.voiceName, "Azelma")
        XCTAssertEqual(OnboardingPremiumVoiceRow.badge, "Premium · included")
        XCTAssertEqual(
            OnboardingPremiumVoiceRow.caption,
            "Runs entirely on this Mac after a one-time download."
        )
        XCTAssertEqual(OnboardingPremiumVoiceRow.rowIdentifier, "Onboarding Premium Azelma")
        XCTAssertEqual(OnboardingPremiumVoiceRow.previewIdentifier, "Onboarding Premium Preview")
        // No user-facing runtime/vendor strings leak into the row copy.
        for text in [
            OnboardingPremiumVoiceRow.voiceName,
            OnboardingPremiumVoiceRow.badge,
            OnboardingPremiumVoiceRow.caption
        ] {
            XCTAssertFalse(text.lowercased().contains("pocket-tts"))
            XCTAssertFalse(text.lowercased().contains("kyutai"))
            XCTAssertFalse(text.lowercased().contains("openvox"))
        }
    }

    func testRowIsShownRegardlessOfCompactVoicesOnly() {
        // The compact-only affordance filters the SYSTEM voice catalog only; the
        // bundled Azelma row must still lead the step.
        XCTAssertTrue(OnboardingPremiumVoiceRow.isShown(compactVoicesOnly: false))
        XCTAssertTrue(OnboardingPremiumVoiceRow.isShown(compactVoicesOnly: true))
    }

    // MARK: - Preview uses the bundled clip, never synthesis

    func testPreviewUsesBundledClipNotSynthesis() {
        let source = ensureBundledPreviewClip()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: source.path),
            "the Azelma preview clip ships in the app resources"
        )
        guard let url = PremiumVoicePreviewClip.url() else {
            return XCTFail("bundled Azelma preview clip must resolve for the onboarding preview")
        }
        // A pre-rendered container, not a synthesized .wav from the neural runtime.
        XCTAssertEqual(url.pathExtension, "m4a")
        XCTAssertEqual(url.lastPathComponent, "azelma-preview.m4a")

        let playback = SpeechPlaybackController()
        playback.previewClip(at: url, text: "instant sample")
        XCTAssertEqual(
            playback.currentText, "instant sample",
            "preview routes through the instant bundled-clip path"
        )
        playback.stop()
    }

    func testAppModelPreviewRoutesThroughInstantClip() throws {
        _ = NSApplication.shared
        ensureBundledPreviewClip()
        let model = try AppModel(store: CardStore.inMemory())
        // The neural runtime is not staged in the test process; if preview tried
        // to synthesize it would produce nothing. The clip path sets currentText
        // synchronously off the bundled asset instead.
        model.previewPremiumVoiceSample(sampleText: "onboarding azelma preview")
        XCTAssertEqual(model.playback.currentText, "onboarding azelma preview")
        model.playback.stop()
    }

    // MARK: - Selecting Azelma

    func testSelectWhenInstalledAppliesImmediately() async throws {
        let (manager, _) = try await installedManager()
        let controller = PremiumVoiceSelectionController(weights: manager)
        var applied = 0
        controller.select { applied += 1 }
        XCTAssertEqual(applied, 1, "an installed Azelma applies the voice right away")
        XCTAssertFalse(controller.engaged)
        manager.remove()
    }

    func testDeclineKeepsCurrentDefaultSelected() {
        let fetcher = FakeFetcher()
        let manager = makeManager(fetcher: fetcher, sha: String(repeating: "a", count: 64))
        let controller = PremiumVoiceSelectionController(weights: manager)
        var applied = 0
        // pickPremiumVoice() stand-in: it would switch the voiceRef to Azelma.
        controller.select { applied += 1 }
        XCTAssertTrue(controller.engaged, "picking Azelma opens the consent gate")

        controller.cancel() // decline
        XCTAssertFalse(controller.engaged)
        XCTAssertEqual(applied, 0, "declining never switches away from the system default")
        XCTAssertEqual(fetcher.callCount, 0, "declining never downloads")
        XCTAssertEqual(manager.state, .notDownloaded)
    }

    // MARK: - Mid-onboarding navigation

    func testDownloadStartedOnVoiceStepAppliesAfterNavigatingAway() async throws {
        // The controller is owned by AppModel, not the transient voice-step view,
        // so paging ahead in onboarding (represented here by dropping every
        // reference except the controller itself) must not lose the deferred
        // completion; the voice still applies once the weights install.
        let payload = Data("azelma-weights".utf8)
        let fetcher = FakeFetcher(payload: payload)
        let manager = makeManager(fetcher: fetcher, sha: try sha256(of: payload))
        let controller = PremiumVoiceSelectionController(weights: manager)
        var applied = false
        controller.select { applied = true }
        controller.confirmDownload()

        await waitFor({ manager.isInstalled }, "install to finish after navigating away")
        await waitFor({ applied }, "deferred Azelma selection to apply on install")
        XCTAssertFalse(controller.engaged)
        manager.remove()
    }

    func testFailureSurfacesReasonAndRetryWithoutBlocking() async throws {
        let payload = Data("retry-bytes".utf8)
        let fetcher = FakeFetcher(payload: payload)
        // Wrong advertised checksum so the first attempt fails.
        let manager = makeManager(fetcher: fetcher, sha: String(repeating: "b", count: 64))
        let controller = PremiumVoiceSelectionController(weights: manager)
        var applied = 0
        controller.select { applied += 1 }
        controller.confirmDownload()
        await waitFor({
            if case .failed = manager.state { return true }
            return false
        }, "first attempt to fail")

        // A failure must never apply the voice or block completing onboarding.
        XCTAssertEqual(applied, 0)
        let descriptor = controller.descriptor(isSelected: false)
        if case .failed(let reason) = descriptor.affordance {
            XCTAssertFalse(reason.isEmpty, "the manager's reason is surfaced for retry")
        } else {
            XCTFail("expected a failed affordance with a retry reason")
        }

        let firstCalls = fetcher.callCount
        controller.retry()
        await waitFor({ fetcher.callCount > firstCalls }, "retry to trigger another fetch")
    }

    // MARK: - Controller persistence on AppModel

    func testOnboardingControllerIsStableAcrossAccesses() throws {
        _ = NSApplication.shared
        let model = try AppModel(store: CardStore.inMemory())
        let first = model.onboardingPremiumVoiceController
        let second = model.onboardingPremiumVoiceController
        XCTAssertTrue(first === second, "the controller must persist across step-view rebuilds")
        XCTAssertTrue(first.weights === model.premiumVoiceWeights)
    }

    // MARK: - Helpers

    /// `swift test` intermittently omits the processed `.m4a` from the built
    /// AttacheApp resource bundle (a SwiftPM resource-copy quirk; `swift build`
    /// and the release packaging both include it). Copy the source clip into the
    /// bundle that sits beside the test binary, which is exactly where the app's
    /// `Bundle(for:)`-anchored resolution looks, so preview resolution is
    /// deterministic in CI. Returns the source clip URL.
    @discardableResult
    private func ensureBundledPreviewClip() -> URL {
        let source = URL(fileURLWithPath: #filePath)   // …/Tests/AttacheAppTests/<this>.swift
            .deletingLastPathComponent()               // AttacheAppTests
            .deletingLastPathComponent()               // Tests
            .deletingLastPathComponent()               // repo root
            .appendingPathComponent("Sources/AttacheApp/Resources/azelma-preview.m4a")
        let builtBundle = Bundle(for: AppModel.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Attache_AttacheApp.bundle", isDirectory: true)
        let dest = builtBundle.appendingPathComponent("azelma-preview.m4a")
        let fm = FileManager.default
        if !fm.fileExists(atPath: dest.path), fm.fileExists(atPath: source.path) {
            try? fm.createDirectory(at: builtBundle, withIntermediateDirectories: true)
            try? fm.copyItem(at: source, to: dest)
        }
        return source
    }

    private func makeManager(fetcher: FakeFetcher, sha: String) -> PremiumVoiceWeightsManager {
        PremiumVoiceWeightsManager(
            release: PremiumVoiceRelease(
                version: "vtest",
                bundleURL: URL(string: "https://example.com/premium-voice-int8.tar.gz")!,
                sha256: sha,
                unpackedSizeBytes: 10,
                downloadSizeBytes: 8,
                contents: []
            ),
            fetcher: fetcher,
            installRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("onboarding-premium-tests-\(UUID().uuidString)", isDirectory: true),
            unpack: fakeUnpack
        )
    }

    private func installedManager() async throws -> (PremiumVoiceWeightsManager, FakeFetcher) {
        let payload = Data("installed".utf8)
        let fetcher = FakeFetcher(payload: payload)
        let manager = makeManager(fetcher: fetcher, sha: try sha256(of: payload))
        manager.beginDownload()
        await waitFor({ manager.isInstalled }, "install for installedManager()")
        return (manager, fetcher)
    }

    private func fakeUnpack(archive: URL, destination: URL) throws {
        let root = destination.appendingPathComponent("premium-voice-int8", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let voices = root.appendingPathComponent("voices", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: voices, withIntermediateDirectories: true)
        try Data("tok".utf8).write(to: models.appendingPathComponent("tokenizer.model"))
        try Data("wav".utf8).write(to: voices.appendingPathComponent("azelma.wav"))
    }

    private func sha256(of data: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sha-\(UUID().uuidString)")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try PremiumVoiceWeightsManager.sha256(ofFileAt: url)
    }

    private func waitFor(
        _ predicate: @escaping () -> Bool,
        timeout: TimeInterval = 5,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting: \(message)", file: file, line: line)
    }

    // MARK: - Fake fetcher

    final class FakeFetcher: PremiumVoiceWeightsFetcher {
        var payload: Data
        private(set) var callCount = 0

        init(payload: Data = Data("weights".utf8)) { self.payload = payload }

        func download(
            release: PremiumVoiceRelease,
            resumeData: Data?,
            progress: @escaping (Double) -> Void
        ) async throws -> URL {
            callCount += 1
            progress(0.5)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("fake-onboarding-weights-\(UUID().uuidString).tar.gz")
            try payload.write(to: url)
            return url
        }
    }
}
