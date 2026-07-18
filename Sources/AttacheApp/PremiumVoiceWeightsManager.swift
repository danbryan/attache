import Foundation
import CryptoKit
import AttacheCore
import os

/// Download failure carrying URLSession resume data when the transfer was
/// interrupted mid-flight, so the next `beginDownload()` can continue rather
/// than restart the ~200 MB transfer.
struct PremiumVoiceDownloadInterruption: Error {
    var underlying: Error
    var resumeData: Data?
}

/// Fetches the weights tarball to a local file. Injectable so tests never touch
/// the network.
protocol PremiumVoiceWeightsFetcher {
    /// Download `release` to a local file, reporting fractional progress. If
    /// `resumeData` is provided, continue a prior interrupted transfer. On an
    /// interruption that produced resume data, throw
    /// `PremiumVoiceDownloadInterruption`.
    func download(
        release: PremiumVoiceRelease,
        resumeData: Data?,
        progress: @escaping (Double) -> Void
    ) async throws -> URL
}

/// Where the Attaché Premium voice stands for the caller (E2/E3 UI). Download
/// only ever starts from an explicit `beginDownload()`.
enum PremiumVoiceWeightsState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case verifying
    case installed(version: String)
    case failed(reason: String)
}

@MainActor
final class PremiumVoiceWeightsManager: ObservableObject {

    @Published private(set) var state: PremiumVoiceWeightsState

    let release: PremiumVoiceRelease
    private let fetcher: PremiumVoiceWeightsFetcher
    private let fileManager: FileManager
    private let installRoot: URL
    private let unpack: (_ archive: URL, _ destination: URL) throws -> Void
    private let logger = Logger(subsystem: "com.bryanlabs.attache", category: "premium-voice-weights")

    private var resumeData: Data?
    private var activeDownload: Task<Void, Never>?

    init(
        release: PremiumVoiceRelease = .pinned,
        fetcher: PremiumVoiceWeightsFetcher = URLSessionPremiumVoiceWeightsFetcher(),
        fileManager: FileManager = .default,
        installRoot: URL? = nil,
        unpack: ((_ archive: URL, _ destination: URL) throws -> Void)? = nil
    ) {
        self.release = release
        self.fetcher = fetcher
        self.fileManager = fileManager
        self.installRoot = installRoot ?? Self.defaultInstallRoot(fileManager: fileManager)
        self.unpack = unpack ?? { archive, destination in
            try PremiumVoiceWeightsManager.untar(archive: archive, destination: destination)
        }
        // Reflect any prior install so a relaunch shows Installed without work.
        if Self.isInstalled(version: release.version, installRoot: self.installRoot, fileManager: fileManager) {
            self.state = .installed(version: release.version)
        } else {
            self.state = .notDownloaded
        }
    }

    /// The versioned install directory for this release.
    var versionDirectory: URL {
        installRoot.appendingPathComponent(release.version, isDirectory: true)
    }

    var isInstalled: Bool {
        if case .installed = state { return true }
        return false
    }

    /// Begin (or resume) the download. This is the ONLY thing that starts a
    /// transfer; consent is the caller's responsibility (E2/E3). No-op when a
    /// download is already running or the weights are installed.
    func beginDownload() {
        switch state {
        case .downloading, .verifying, .installed:
            return
        case .notDownloaded, .failed:
            break
        }
        guard !release.isChecksumPlaceholder else {
            // A build shipped without the real asset checksum must not "install"
            // unverifiable bytes.
            state = .failed(reason: "This build has no verified Attaché Premium voice release yet.")
            return
        }
        state = .downloading(progress: 0)
        let priorResume = resumeData
        activeDownload = Task { [weak self] in
            await self?.runDownload(resumeData: priorResume)
        }
    }

    /// Cancel an in-flight download and return to the prior resting state.
    func cancelDownload() {
        activeDownload?.cancel()
        activeDownload = nil
        if case .downloading = state {
            state = resumeData == nil ? .notDownloaded : .failed(reason: "Download canceled.")
        }
    }

    /// Delete the installed weights and return to notDownloaded.
    func remove() {
        activeDownload?.cancel()
        activeDownload = nil
        try? fileManager.removeItem(at: versionDirectory)
        resumeData = nil
        state = .notDownloaded
    }

    private func runDownload(resumeData priorResume: Data?) async {
        do {
            let downloaded = try await fetcher.download(release: release, resumeData: priorResume) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(progress: min(max(fraction, 0), 1))
                }
            }
            if Task.isCancelled {
                try? fileManager.removeItem(at: downloaded)
                return
            }
            resumeData = nil
            await verifyAndInstall(archive: downloaded)
        } catch let interruption as PremiumVoiceDownloadInterruption {
            resumeData = interruption.resumeData
            state = .failed(reason: "Download interrupted. It can be resumed.")
        } catch is CancellationError {
            // Left as-is by cancelDownload().
        } catch {
            state = .failed(reason: error.localizedDescription)
        }
    }

    private func verifyAndInstall(archive: URL) async {
        state = .verifying
        defer { try? fileManager.removeItem(at: archive) }

        guard let expected = release.normalizedSHA256 else {
            state = .failed(reason: "Release checksum is not valid.")
            return
        }
        let actual: String
        do {
            actual = try Self.sha256(ofFileAt: archive)
        } catch {
            state = .failed(reason: "Could not read the downloaded file.")
            return
        }
        guard actual == expected else {
            // Corrupt or tampered download: never install it.
            try? fileManager.removeItem(at: versionDirectory)
            state = .failed(reason: "Downloaded voice failed its integrity check.")
            return
        }

        do {
            // Install atomically: unpack into a scratch dir, then swap in.
            let scratch = installRoot.appendingPathComponent(".installing-\(UUID().uuidString)", isDirectory: true)
            try? fileManager.removeItem(at: scratch)
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
            try unpack(archive, scratch)
            let payload = Self.resolvePayloadDirectory(in: scratch, fileManager: fileManager)
            try? fileManager.removeItem(at: versionDirectory)
            try fileManager.createDirectory(at: installRoot, withIntermediateDirectories: true)
            try fileManager.moveItem(at: payload, to: versionDirectory)
            try? fileManager.removeItem(at: scratch)
        } catch {
            try? fileManager.removeItem(at: versionDirectory)
            state = .failed(reason: "Could not install the Attaché Premium voice.")
            return
        }

        guard Self.isInstalled(version: release.version, installRoot: installRoot, fileManager: fileManager) else {
            try? fileManager.removeItem(at: versionDirectory)
            state = .failed(reason: "Installed Attaché Premium voice is incomplete.")
            return
        }
        state = .installed(version: release.version)
    }

    // MARK: - Static helpers

    nonisolated static func defaultInstallRoot(fileManager: FileManager = .default) -> URL {
        AttacheAppSupport.supportDirectory(fileManager: fileManager)
            .appendingPathComponent("PremiumVoice", isDirectory: true)
    }

    /// The runtime paths for the installed release, or nil if not installed.
    nonisolated static func installedRuntimePaths(
        release: PremiumVoiceRelease = .pinned,
        fileManager: FileManager = .default
    ) -> PremiumVoiceRuntimePaths? {
        let dir = defaultInstallRoot(fileManager: fileManager)
            .appendingPathComponent(release.version, isDirectory: true)
        guard isInstalled(version: release.version, installRoot: defaultInstallRoot(fileManager: fileManager), fileManager: fileManager) else {
            return nil
        }
        return PremiumVoiceRuntimePaths(
            modelsDirectory: dir.appendingPathComponent("models", isDirectory: true),
            voicesDirectory: dir.appendingPathComponent("voices", isDirectory: true),
            tokenizerPath: dir.appendingPathComponent("models/tokenizer.model")
        )
    }

    nonisolated static func installedWeightsDirectory(
        release: PremiumVoiceRelease = .pinned,
        fileManager: FileManager = .default
    ) -> URL? {
        let root = defaultInstallRoot(fileManager: fileManager)
        guard isInstalled(version: release.version, installRoot: root, fileManager: fileManager) else { return nil }
        return root.appendingPathComponent(release.version, isDirectory: true)
    }

    /// An install is valid when the versioned dir has the tokenizer and the
    /// azelma voice prompt (the two files every synthesis needs).
    nonisolated static func isInstalled(version: String, installRoot: URL, fileManager: FileManager) -> Bool {
        let dir = installRoot.appendingPathComponent(version, isDirectory: true)
        let tokenizer = dir.appendingPathComponent("models/tokenizer.model")
        let voice = dir.appendingPathComponent("voices/azelma.wav")
        return fileManager.fileExists(atPath: tokenizer.path)
            && fileManager.fileExists(atPath: voice.path)
    }

    /// Streaming SHA-256 so a ~200 MB file is not loaded into memory at once.
    nonisolated static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// If the archive unpacked into a single top-level dir (our tarball wraps
    /// everything in `premium-voice-int8/`), install that dir's contents.
    nonisolated private static func resolvePayloadDirectory(in scratch: URL, fileManager: FileManager) -> URL {
        let entries = (try? fileManager.contentsOfDirectory(
            at: scratch,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        if entries.count == 1,
           (try? entries[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            return entries[0]
        }
        return scratch
    }

    nonisolated private static func untar(archive: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PremiumVoiceRuntimeError.weightsUnavailable
        }
    }
}

/// Real fetcher: a URLSession download task with progress and resume support.
final class URLSessionPremiumVoiceWeightsFetcher: NSObject, PremiumVoiceWeightsFetcher {
    func download(
        release: PremiumVoiceRelease,
        resumeData: Data?,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (tempURL, _): (URL, URLResponse)
            if let resumeData {
                (tempURL, _) = try await session.download(resumeFrom: resumeData, delegate: delegate)
            } else {
                (tempURL, _) = try await session.download(from: release.bundleURL, delegate: delegate)
            }
            // Move out of the session's temp location before it is reclaimed.
            let staged = FileManager.default.temporaryDirectory
                .appendingPathComponent("premium-voice-\(UUID().uuidString).tar.gz")
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.moveItem(at: tempURL, to: staged)
            return staged
        } catch {
            let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            if let resume {
                throw PremiumVoiceDownloadInterruption(underlying: error, resumeData: resume)
            }
            throw error
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        let progress: (Double) -> Void
        init(progress: @escaping (Double) -> Void) { self.progress = progress }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The async download(...) API handles the file handoff.
        }
    }
}
