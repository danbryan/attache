import XCTest
import AttacheCore
@testable import AttacheApp

/// The pure Attaché Premium section descriptor matrix (E2/#3) and the selection
/// state machine (E2/#2): consent gate, cancel revert, failure retry, and
/// installed-completes. The state machine is driven through a real
/// `PremiumVoiceWeightsManager` backed by a fake fetcher so nothing touches the
/// network or shells out.
@MainActor
final class PremiumVoiceSectionTests: XCTestCase {

    // MARK: - Pure descriptor matrix

    func testAbsentReleaseHidesSection() {
        let d = PremiumVoiceSectionDescriptor.make(
            releaseExists: false, downloadSizeText: "189 MB",
            state: .notDownloaded, isSelected: false, consentEngaged: false
        )
        XCTAssertFalse(d.isPresent)
    }

    func testNotDownloadedShowsSizeSuffixAndSelectableUntilEngaged() {
        let d = PremiumVoiceSectionDescriptor.make(
            releaseExists: true, downloadSizeText: "189 MB",
            state: .notDownloaded, isSelected: false, consentEngaged: false
        )
        XCTAssertTrue(d.isPresent)
        XCTAssertEqual(d.sectionTitle, "Attaché Premium")
        XCTAssertEqual(d.voiceName, "Azelma")
        XCTAssertEqual(d.caption, "Recommended. Runs entirely on this Mac.")
        XCTAssertEqual(d.stateSuffix, "189 MB download")
        XCTAssertEqual(d.affordance, .selectable)
    }

    func testNotDownloadedEngagedShowsConsentGate() {
        let d = PremiumVoiceSectionDescriptor.make(
            releaseExists: true, downloadSizeText: "189 MB",
            state: .notDownloaded, isSelected: false, consentEngaged: true
        )
        XCTAssertEqual(
            d.affordance,
            .consent(text: "Download 189 MB, one time; then Azelma runs offline on this Mac.")
        )
        XCTAssertEqual(d.stateSuffix, "189 MB download")
    }

    func testDownloadingShowsInlineProgress() {
        let d = PremiumVoiceSectionDescriptor.make(
            releaseExists: true, downloadSizeText: "189 MB",
            state: .downloading(progress: 0.42), isSelected: false, consentEngaged: true
        )
        XCTAssertEqual(d.affordance, .downloading(progress: 0.42))
        XCTAssertEqual(d.stateSuffix, "Downloading… 42%")
    }

    func testVerifyingShowsVerifying() {
        let d = PremiumVoiceSectionDescriptor.make(
            releaseExists: true, downloadSizeText: "189 MB",
            state: .verifying, isSelected: false, consentEngaged: true
        )
        XCTAssertEqual(d.affordance, .verifying)
        XCTAssertEqual(d.stateSuffix, "Verifying…")
    }

    func testInstalledIsSelectableWithNoSuffix() {
        let d = PremiumVoiceSectionDescriptor.make(
            releaseExists: true, downloadSizeText: "189 MB",
            state: .installed(version: "v1"), isSelected: true, consentEngaged: false
        )
        XCTAssertEqual(d.affordance, .selectable)
        XCTAssertNil(d.stateSuffix)
        XCTAssertTrue(d.isSelected)
    }

    func testFailedShowsReasonAndFailedAffordance() {
        let d = PremiumVoiceSectionDescriptor.make(
            releaseExists: true, downloadSizeText: "189 MB",
            state: .failed(reason: "Downloaded voice failed its integrity check."),
            isSelected: false, consentEngaged: true
        )
        XCTAssertEqual(d.affordance, .failed(reason: "Downloaded voice failed its integrity check."))
        XCTAssertEqual(d.stateSuffix, "Downloaded voice failed its integrity check.")
    }

    // MARK: - Selection state machine

    func testSelectWhenInstalledCompletesImmediately() async throws {
        let (manager, _) = try await installedManager()
        let controller = PremiumVoiceSelectionController(weights: manager)
        var completed = 0
        controller.select { completed += 1 }
        XCTAssertEqual(completed, 1, "an installed voice completes selection right away")
        XCTAssertFalse(controller.engaged)
    }

    func testSelectWhenNotDownloadedGatesConsentWithoutDownloadingOrCompleting() {
        let fetcher = FakeFetcher()
        let manager = makeManager(fetcher: fetcher, sha: String(repeating: "a", count: 64))
        let controller = PremiumVoiceSelectionController(weights: manager)
        var completed = 0
        controller.select { completed += 1 }
        XCTAssertTrue(controller.engaged, "consent gate must open")
        XCTAssertEqual(completed, 0, "selection must not complete before install")
        XCTAssertEqual(fetcher.callCount, 0, "no silent download")
        XCTAssertEqual(manager.state, .notDownloaded)
    }

    func testDownloadThenInstallCompletesTheDeferredSelection() async throws {
        let payload = Data("azelma-weights".utf8)
        let fetcher = FakeFetcher(payload: payload)
        let manager = makeManager(fetcher: fetcher, sha: try sha256(of: payload))
        let controller = PremiumVoiceSelectionController(weights: manager)
        var completed = 0
        controller.select { completed += 1 }
        controller.confirmDownload()
        await waitFor({ manager.isInstalled }, "install to finish")
        await waitFor({ completed == 1 }, "deferred selection to complete on install")
        XCTAssertFalse(controller.engaged)
        manager.remove()
    }

    func testCancelWhileDownloadingRevertsWithoutCompleting() async throws {
        let payload = Data("bytes".utf8)
        let fetcher = FakeFetcher(payload: payload)
        fetcher.useGate = true
        let manager = makeManager(fetcher: fetcher, sha: try sha256(of: payload))
        let controller = PremiumVoiceSelectionController(weights: manager)
        var completed = 0
        controller.select { completed += 1 }
        controller.confirmDownload()
        await fetcher.waitUntilAtGate()
        await waitFor({
            if case .downloading = manager.state { return true }
            return false
        }, "download to be in flight")

        controller.cancel()
        XCTAssertFalse(controller.engaged, "cancel closes the gate")
        XCTAssertEqual(completed, 0, "cancel never completes the selection")
        fetcher.openGate()
    }

    func testRetryAfterFailureStartsAnotherDownload() async throws {
        let payload = Data("retry-bytes".utf8)
        let fetcher = FakeFetcher(payload: payload)
        // Advertise a wrong checksum so the first attempt fails.
        let manager = makeManager(fetcher: fetcher, sha: String(repeating: "b", count: 64))
        let controller = PremiumVoiceSelectionController(weights: manager)
        controller.select { }
        controller.confirmDownload()
        await waitFor({
            if case .failed = manager.state { return true }
            return false
        }, "first attempt to fail")
        let firstCalls = fetcher.callCount
        controller.retry()
        await waitFor({ fetcher.callCount > firstCalls }, "retry to trigger another fetch")
    }

    // MARK: - Remove falls back to system voice

    func testRemovedPremiumVoiceFallsBackToSystemForPlayback() {
        let previous = AttachePremiumVoiceAvailability.probeOverride
        defer { AttachePremiumVoiceAvailability.probeOverride = previous }
        // Weights removed / not installed: the premium voice is not ready.
        AttachePremiumVoiceAvailability.probeOverride = { false }

        var config = AttacheSpeechConfiguration.systemDefault
        config.provider = .attachePremium
        XCTAssertNotNil(config.playbackUnavailableReason)
        let resolved = config.resolvedForPlayback(systemVoiceIdentifier: "com.apple.voice.x")
        XCTAssertEqual(resolved.provider, .system)
        XCTAssertEqual(resolved.systemVoiceIdentifier, "com.apple.voice.x")
    }

    func testInstalledPremiumVoiceStaysSelectedForPlayback() {
        let previous = AttachePremiumVoiceAvailability.probeOverride
        defer { AttachePremiumVoiceAvailability.probeOverride = previous }
        AttachePremiumVoiceAvailability.probeOverride = { true }

        var config = AttacheSpeechConfiguration.systemDefault
        config.provider = .attachePremium
        XCTAssertNil(config.playbackUnavailableReason)
        XCTAssertEqual(config.resolvedForPlayback(systemVoiceIdentifier: "x").provider, .attachePremium)
    }

    // MARK: - Helpers

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
                .appendingPathComponent("premium-section-tests-\(UUID().uuidString)", isDirectory: true),
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
        var useGate = false
        private(set) var callCount = 0

        private var gateContinuation: CheckedContinuation<Void, Never>?
        private var reachedGate: CheckedContinuation<Void, Never>?

        init(payload: Data = Data("weights".utf8)) { self.payload = payload }

        func waitUntilAtGate() async {
            await withCheckedContinuation { cont in
                if gateContinuation != nil { cont.resume(); return }
                reachedGate = cont
            }
        }

        func openGate() {
            gateContinuation?.resume()
            gateContinuation = nil
        }

        func download(
            release: PremiumVoiceRelease,
            resumeData: Data?,
            progress: @escaping (Double) -> Void
        ) async throws -> URL {
            callCount += 1
            progress(0.5)
            if useGate {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    gateContinuation = cont
                    reachedGate?.resume()
                    reachedGate = nil
                }
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("fake-section-weights-\(UUID().uuidString).tar.gz")
            try payload.write(to: url)
            return url
        }
    }
}
