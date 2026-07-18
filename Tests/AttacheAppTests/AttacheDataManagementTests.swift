import AttacheCore
import XCTest
@testable import AttacheApp

/// Data management (back up / restore / reset, INF-391) and the audio-replay
/// retention default. Everything runs against temp directories and throwaway
/// UserDefaults suites; the real profile is never touched.
final class AttacheDataManagementTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-data-mgmt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSupportFixture() throws -> URL {
        let support = root.appendingPathComponent("Attache", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: support.appendingPathComponent("Attache.sqlite"))
        let personalities = support.appendingPathComponent("Personalities", isDirectory: true)
        try fm.createDirectory(at: personalities, withIntermediateDirectories: true)
        try Data("p1".utf8).write(to: personalities.appendingPathComponent("p1.json"))
        // Entries that must never make it into the archive.
        try Data("tok".utf8).write(to: support.appendingPathComponent("event-token"))
        let audioCache = support.appendingPathComponent("AudioCache", isDirectory: true)
        try fm.createDirectory(at: audioCache, withIntermediateDirectories: true)
        try Data("wav".utf8).write(to: audioCache.appendingPathComponent("clip.caf"))
        // A public voice cache, excluded by default.
        let premium = support.appendingPathComponent("PremiumVoice", isDirectory: true)
        try fm.createDirectory(at: premium, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: premium.appendingPathComponent("azelma.wav"))
        return support
    }

    // MARK: Pack excludes secrets, cache, and premium voice by default

    func testPackExcludesTokenCacheAndPremiumVoice() throws {
        let support = try makeSupportFixture()
        let destination = root.appendingPathComponent("backup.attachebackup")
        let manifest = try AppModel.packDataArchive(
            supportDirectory: support,
            exportedDefaults: ["attache.theme": "macOS"],
            destination: destination,
            includePremiumVoice: false,
            appVersion: "0.4.0",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertTrue(manifest.contents.contains("Attache.sqlite"))
        XCTAssertTrue(manifest.contents.contains("Personalities"))
        XCTAssertTrue(manifest.contents.contains(AttacheDataArchive.defaultsFileName))
        XCTAssertFalse(manifest.contents.contains("event-token"))
        XCTAssertFalse(manifest.contents.contains("AudioCache"))
        XCTAssertFalse(manifest.contents.contains("PremiumVoice"))

        // Prove it against the extracted bytes, not just the manifest listing.
        let (extracted, extractRoot) = try AppModel.extractDataArchive(destination)
        defer { try? FileManager.default.removeItem(at: extractRoot) }
        XCTAssertEqual(extracted.formatVersion, AttacheDataArchive.currentFormatVersion)
        let supportRoot = extractRoot.appendingPathComponent(AttacheDataArchive.supportDirectoryName)
        let names = try FileManager.default.contentsOfDirectory(atPath: supportRoot.path)
        XCTAssertTrue(names.contains("Attache.sqlite"))
        XCTAssertFalse(names.contains("event-token"))
        XCTAssertFalse(names.contains("AudioCache"))
        XCTAssertFalse(names.contains("PremiumVoice"))
    }

    func testPackIncludesPremiumVoiceWhenOptedIn() throws {
        let support = try makeSupportFixture()
        let destination = root.appendingPathComponent("backup.attachebackup")
        let manifest = try AppModel.packDataArchive(
            supportDirectory: support,
            exportedDefaults: [:],
            destination: destination,
            includePremiumVoice: true,
            appVersion: "0.4.0")
        XCTAssertTrue(manifest.contents.contains("PremiumVoice"))
    }

    // MARK: Round-trip restore into a target directory

    func testBackupRestoreRoundTrip() throws {
        let support = try makeSupportFixture()
        let destination = root.appendingPathComponent("backup.attachebackup")
        try AppModel.packDataArchive(
            supportDirectory: support,
            exportedDefaults: [:],
            destination: destination,
            includePremiumVoice: false,
            appVersion: "0.4.0")

        // Restore into a fresh, previously nonexistent target.
        let target = root.appendingPathComponent("Restored/Attache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AppModel.restoreDataArchive(from: destination, intoSupportDirectory: target)

        let fm = FileManager.default
        XCTAssertEqual(
            try String(contentsOf: target.appendingPathComponent("Attache.sqlite"), encoding: .utf8), "db")
        XCTAssertEqual(
            try String(contentsOf: target.appendingPathComponent("Personalities/p1.json"), encoding: .utf8), "p1")
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("event-token").path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("AudioCache").path))
    }

    func testRestoreReplacesExistingProfile() throws {
        let support = try makeSupportFixture()
        let destination = root.appendingPathComponent("backup.attachebackup")
        try AppModel.packDataArchive(
            supportDirectory: support, exportedDefaults: [:],
            destination: destination, includePremiumVoice: false, appVersion: "0.4.0")

        // A different current profile that should be replaced.
        let target = root.appendingPathComponent("Live", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: target.appendingPathComponent("stale.txt"))

        try AppModel.restoreDataArchive(from: destination, intoSupportDirectory: target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("stale.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("Attache.sqlite").path))
    }

    // MARK: Version refusal on restore

    func testRestoreRefusesFutureFormat() throws {
        // Hand-build an archive whose manifest claims a future format version.
        let staging = root.appendingPathComponent("future-stage", isDirectory: true)
        let supportStage = staging.appendingPathComponent(AttacheDataArchive.supportDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: supportStage, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: supportStage.appendingPathComponent("Attache.sqlite"))
        let future = AttacheDataArchive.Manifest(
            formatVersion: AttacheDataArchive.currentFormatVersion + 1,
            createdAt: Date(), appVersion: "99.0", contents: ["Attache.sqlite"])
        try AttacheDataArchive.encodeManifest(future)
            .write(to: staging.appendingPathComponent(AttacheDataArchive.manifestFileName))
        try Data().write(to: staging.appendingPathComponent(AttacheDataArchive.defaultsFileName))

        let archive = root.appendingPathComponent("future.attachebackup")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, archive.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        let target = root.appendingPathComponent("Target", isDirectory: true)
        XCTAssertThrowsError(try AppModel.restoreDataArchive(from: archive, intoSupportDirectory: target)) { error in
            XCTAssertEqual(
                error as? AttacheDataArchive.ArchiveError,
                .unsupportedFutureFormat(
                    found: AttacheDataArchive.currentFormatVersion + 1,
                    supported: AttacheDataArchive.currentFormatVersion))
        }
        // The refusal must not have created the target profile.
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    // MARK: Reset state machine

    func testResetClearsProfileButKeepsPremiumVoiceByDefault() throws {
        let support = try makeSupportFixture()
        try AppModel.resetSupportDirectory(support, alsoRemovePremiumVoice: false)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("Attache.sqlite").path))
        XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("Personalities").path))
        XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("event-token").path))
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("PremiumVoice").path))
    }

    func testResetCanAlsoRemovePremiumVoice() throws {
        let support = try makeSupportFixture()
        try AppModel.resetSupportDirectory(support, alsoRemovePremiumVoice: true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: support.appendingPathComponent("PremiumVoice").path))
    }

    func testResetDefaultsMarksOnboardingNeeded() {
        let suiteName = "attache-reset-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AttachePreferenceKey.onboardingCompleted)
        defaults.set("macOS", forKey: AttachePreferenceKey.theme)
        XCTAssertTrue(defaults.bool(forKey: AttachePreferenceKey.onboardingCompleted))

        AppModel.resetDefaultsToOnboarding(defaults, domainName: suiteName)

        // Onboarding keys off `onboardingCompleted`; after reset it reads false,
        // so the next launch re-runs onboarding.
        XCTAssertFalse(defaults.bool(forKey: AttachePreferenceKey.onboardingCompleted))
        XCTAssertNil(defaults.object(forKey: AttachePreferenceKey.theme))
    }

    // MARK: Defaults export strips secrets

    func testExportedDefaultsStripSensitiveKeys() {
        let suiteName = "attache-export-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("macOS", forKey: AttachePreferenceKey.theme)
        defaults.set("sk-live-secret", forKey: AttachePreferenceKey.presentationLLMAPIKey)
        defaults.set("op://vault/item", forKey: AttachePreferenceKey.presentationLLMAPIKeySecretRef)

        let exported = AppModel.exportedArchiveDefaults(from: defaults, domainName: suiteName)
        XCTAssertEqual(exported[AttachePreferenceKey.theme] as? String, "macOS")
        XCTAssertNil(exported[AttachePreferenceKey.presentationLLMAPIKey])
        XCTAssertNil(exported[AttachePreferenceKey.presentationLLMAPIKeySecretRef])
    }

    // MARK: Retention default (INF-391)

    func testSevenDaysIsAPresetOption() {
        XCTAssertTrue(AppModel.audioCacheRetentionOptions.contains { $0.minutes == 7 * 24 * 60 })
    }

    func testNearestRetentionOptionSnapsToSevenDays() {
        XCTAssertEqual(AppModel.nearestAudioCacheRetentionOption(to: 7 * 24 * 60).minutes, 7 * 24 * 60)
        XCTAssertEqual(AppModel.nearestAudioCacheRetentionOption(to: 6 * 24 * 60).minutes, 7 * 24 * 60)
    }

    func testNearestRetentionOptionSnapsToClosestPreset() {
        XCTAssertEqual(AppModel.nearestAudioCacheRetentionOption(to: 0).minutes, 0)
        XCTAssertEqual(AppModel.nearestAudioCacheRetentionOption(to: 20).minutes, 15)
        XCTAssertEqual(AppModel.nearestAudioCacheRetentionOption(to: 50).minutes, 60)
    }
}
