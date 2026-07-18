import XCTest
import AttacheCore
@testable import AttacheApp

/// The Attaché Premium weights download state machine, driven entirely by a fake
/// fetcher and a fake unpack step so nothing touches the network or shells out.
/// Covers: consent-gated start, progress, checksum mismatch -> failed + cleanup,
/// resume, and remove. Bounded waits fail on expiry rather than hang.
@MainActor
final class PremiumVoiceWeightsManagerTests: XCTestCase {

    // MARK: - Fakes

    /// Emits progress, optionally pauses at a gate so mid-download state is
    /// observable, then either returns a fresh copy of `payload` or throws an
    /// interruption carrying resume data.
    final class FakeFetcher: PremiumVoiceWeightsFetcher {
        var payload: Data = Data("weights".utf8)
        var progressToEmit: [Double] = []
        var interruptionResumeData: Data?
        var failResumeDataOnFirstCallOnly = false

        private(set) var callCount = 0
        private(set) var receivedResumeData: [Data?] = []

        var gateContinuation: CheckedContinuation<Void, Never>?
        private var reachedGate: CheckedContinuation<Void, Never>?
        var useGate = false

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
            receivedResumeData.append(resumeData)
            for value in progressToEmit { progress(value) }

            if useGate {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    gateContinuation = cont
                    reachedGate?.resume()
                    reachedGate = nil
                }
            }

            let shouldInterrupt = interruptionResumeData != nil
                && !(failResumeDataOnFirstCallOnly && resumeData != nil)
            if shouldInterrupt {
                throw PremiumVoiceDownloadInterruption(
                    underlying: URLError(.networkConnectionLost),
                    resumeData: interruptionResumeData
                )
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("fake-weights-\(UUID().uuidString).tar.gz")
            try payload.write(to: url)
            return url
        }
    }

    // MARK: - Helpers

    private func makeInstallRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("premium-voice-tests-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    /// Fake unpack: lay down the two files `isInstalled` checks, wrapped in the
    /// single top-level dir the real tarball uses (exercises payload resolution).
    private func fakeUnpack(archive: URL, destination: URL) throws {
        let root = destination.appendingPathComponent("premium-voice-int8", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let voices = root.appendingPathComponent("voices", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: voices, withIntermediateDirectories: true)
        try Data("tok".utf8).write(to: models.appendingPathComponent("tokenizer.model"))
        try Data("wav".utf8).write(to: voices.appendingPathComponent("azelma.wav"))
    }

    private func release(sha: String, url: String = "https://example.com/premium-voice-int8.tar.gz") -> PremiumVoiceRelease {
        PremiumVoiceRelease(
            version: "vtest",
            bundleURL: URL(string: url)!,
            sha256: sha,
            unpackedSizeBytes: 10,
            contents: []
        )
    }

    /// Poll `predicate` up to `timeout`, yielding between checks. Fails on expiry
    /// so a stuck state machine never hangs the suite.
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

    // MARK: - Tests

    func testStartsAtNotDownloadedAndDoesNotAutoStart() {
        let fetcher = FakeFetcher()
        let manager = PremiumVoiceWeightsManager(
            release: release(sha: String(repeating: "a", count: 64)),
            fetcher: fetcher,
            installRoot: makeInstallRoot(),
            unpack: fakeUnpack
        )
        XCTAssertEqual(manager.state, .notDownloaded)
        XCTAssertEqual(fetcher.callCount, 0, "no transfer may start without an explicit beginDownload()")
    }

    func testPlaceholderChecksumRefusesToDownload() {
        let fetcher = FakeFetcher()
        // .pinned now carries the real shipped checksum, so the fail-closed
        // behavior is proven against an explicit placeholder fixture: any
        // future release descriptor that ships un-pinned must refuse to fetch.
        let placeholderRelease = PremiumVoiceRelease(
            version: "v1",
            bundleURL: URL(string: "https://example.com/premium-voice-int8.tar.gz")!,
            sha256: PremiumVoiceRelease.checksumPlaceholder,
            unpackedSizeBytes: 203_011_198,
            downloadSizeBytes: 113_179_974,
            contents: ["models/tokenizer.model"]
        )
        let manager = PremiumVoiceWeightsManager(
            release: placeholderRelease,
            fetcher: fetcher,
            installRoot: makeInstallRoot(),
            unpack: fakeUnpack
        )
        manager.beginDownload()
        guard case .failed = manager.state else {
            return XCTFail("placeholder-checksum release must fail closed, got \(manager.state)")
        }
        XCTAssertEqual(fetcher.callCount, 0, "must not fetch when the checksum is a placeholder")
    }

    func testSuccessfulDownloadVerifiesAndInstalls() async throws {
        let fetcher = FakeFetcher()
        let payload = Data("the-real-weights-bytes".utf8)
        fetcher.payload = payload
        let sha = try sha256(of: payload)
        let manager = PremiumVoiceWeightsManager(
            release: release(sha: sha),
            fetcher: fetcher,
            installRoot: makeInstallRoot(),
            unpack: fakeUnpack
        )

        manager.beginDownload()
        await waitFor({ manager.isInstalled }, "install to complete")
        XCTAssertEqual(manager.state, .installed(version: "vtest"))
        XCTAssertNotNil(PremiumVoiceWeightsManager.isInstalled(
            version: "vtest", installRoot: manager.versionDirectory.deletingLastPathComponent(), fileManager: .default
        ))
        // The downloaded archive is cleaned up after install.
        XCTAssertEqual(fetcher.callCount, 1)
        manager.remove()
    }

    func testProgressIsForwardedToState() async throws {
        let fetcher = FakeFetcher()
        fetcher.useGate = true
        fetcher.progressToEmit = [0.42]
        let payload = Data("bytes".utf8)
        fetcher.payload = payload
        let manager = PremiumVoiceWeightsManager(
            release: release(sha: try sha256(of: payload)),
            fetcher: fetcher,
            installRoot: makeInstallRoot(),
            unpack: fakeUnpack
        )

        manager.beginDownload()
        await fetcher.waitUntilAtGate()
        await waitFor({
            if case .downloading(let p) = manager.state { return p == 0.42 }
            return false
        }, "progress 0.42 to reach state")

        fetcher.openGate()
        await waitFor({ manager.isInstalled }, "install after gate opens")
        manager.remove()
    }

    func testChecksumMismatchFailsAndCleansUp() async throws {
        let fetcher = FakeFetcher()
        fetcher.payload = Data("actual-bytes".utf8)
        // Descriptor advertises a DIFFERENT (valid-form) checksum.
        let wrongSha = String(repeating: "b", count: 64)
        let installRoot = makeInstallRoot()
        let manager = PremiumVoiceWeightsManager(
            release: release(sha: wrongSha),
            fetcher: fetcher,
            installRoot: installRoot,
            unpack: fakeUnpack
        )

        manager.beginDownload()
        await waitFor({
            if case .failed = manager.state { return true }
            return false
        }, "checksum mismatch to fail")
        // Nothing installed; the version dir must not exist.
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.versionDirectory.path))
        XCTAssertFalse(manager.isInstalled)
    }

    func testInterruptionStoresResumeDataAndSecondCallResumes() async throws {
        let fetcher = FakeFetcher()
        let payload = Data("resumable".utf8)
        fetcher.payload = payload
        fetcher.interruptionResumeData = Data("RESUME-TOKEN".utf8)
        fetcher.failResumeDataOnFirstCallOnly = true // succeed once resume data is supplied
        let manager = PremiumVoiceWeightsManager(
            release: release(sha: try sha256(of: payload)),
            fetcher: fetcher,
            installRoot: makeInstallRoot(),
            unpack: fakeUnpack
        )

        manager.beginDownload()
        await waitFor({
            if case .failed = manager.state { return true }
            return false
        }, "first attempt to be interrupted")
        XCTAssertEqual(fetcher.receivedResumeData.first ?? nil, nil, "first call has no resume data")

        // Resume: the manager must hand the stored resume token back to the fetcher.
        manager.beginDownload()
        await waitFor({ manager.isInstalled }, "resumed download to install")
        XCTAssertEqual(fetcher.callCount, 2)
        XCTAssertEqual(fetcher.receivedResumeData.last ?? nil, Data("RESUME-TOKEN".utf8))
        manager.remove()
    }

    func testRemoveDeletesInstallAndResets() async throws {
        let fetcher = FakeFetcher()
        let payload = Data("bytes-to-remove".utf8)
        fetcher.payload = payload
        let manager = PremiumVoiceWeightsManager(
            release: release(sha: try sha256(of: payload)),
            fetcher: fetcher,
            installRoot: makeInstallRoot(),
            unpack: fakeUnpack
        )
        manager.beginDownload()
        await waitFor({ manager.isInstalled }, "install before remove")

        let dir = manager.versionDirectory
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        manager.remove()
        XCTAssertEqual(manager.state, .notDownloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: -

    private func sha256(of data: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sha-\(UUID().uuidString)")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try PremiumVoiceWeightsManager.sha256(ofFileAt: url)
    }
}
