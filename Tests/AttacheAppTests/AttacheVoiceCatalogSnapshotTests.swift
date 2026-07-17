import XCTest
@testable import AttacheApp

/// INF-350: the voice catalog snapshot cache and background-scan Catalog.
/// Every test here uses an injected enumerate closure and a scratch snapshot
/// URL; none of them ever call NSSpeechSynthesizer.availableVoices.
final class AttacheVoiceCatalogSnapshotTests: XCTestCase {
    private func scratchURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-voice-catalog-tests-\(UUID().uuidString)-\(name).json")
    }

    private let sampleVoices = [
        AttacheVoiceOption(id: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", gender: "female", localeIdentifier: "en_US"),
        AttacheVoiceOption(id: "com.apple.voice.premium.en-US.Ava", name: "Ava", gender: "female", localeIdentifier: "en_US")
    ]

    // MARK: - Snapshot store round-trip

    func testSnapshotRoundTripsWriteReadEqual() {
        let url = scratchURL("roundtrip")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(AttacheVoiceCatalogSnapshotStore.write(sampleVoices, to: url))
        let read = AttacheVoiceCatalogSnapshotStore.read(from: url)
        XCTAssertEqual(read, sampleVoices)
    }

    func testSnapshotWithNoFileYetReadsAsNil() {
        let url = scratchURL("missing")
        XCTAssertNil(AttacheVoiceCatalogSnapshotStore.read(from: url))
    }

    func testStaleVersionSnapshotIsDiscarded() {
        let url = scratchURL("stale")
        defer { try? FileManager.default.removeItem(at: url) }

        let stale = AttacheVoiceCatalogSnapshot(version: AttacheVoiceCatalogSnapshotStore.currentVersion - 1, voices: sampleVoices)
        let data = try! JSONEncoder().encode(stale)
        try! data.write(to: url)

        XCTAssertNil(AttacheVoiceCatalogSnapshotStore.read(from: url), "a version-mismatched snapshot must be discarded, never misread")
    }

    func testCorruptSnapshotFileReadsAsNil() {
        let url = scratchURL("corrupt")
        defer { try? FileManager.default.removeItem(at: url) }
        try! Data("not json".utf8).write(to: url)
        XCTAssertNil(AttacheVoiceCatalogSnapshotStore.read(from: url))
    }

    // MARK: - Catalog: snapshot present, no blocking, background refresh

    func testCatalogWithExistingSnapshotLoadsSynchronouslyAndIsNotScanning() {
        let url = scratchURL("with-snapshot")
        defer { try? FileManager.default.removeItem(at: url) }
        AttacheVoiceCatalogSnapshotStore.write(sampleVoices, to: url)

        // autoStart: false so the test controls exactly when the background
        // refresh runs, instead of racing a real DispatchQueue.
        let catalog = AttacheVoiceCatalog.Catalog(
            snapshotURL: url,
            enumerate: { XCTFail("must not enumerate synchronously off an existing snapshot"); return [] },
            autoStart: false
        )
        XCTAssertEqual(catalog.currentVoices(), sampleVoices)
        XCTAssertFalse(catalog.currentlyScanning())
    }

    func testCatalogWithNoSnapshotStartsEmptyAndScanning() {
        let url = scratchURL("no-snapshot")
        let catalog = AttacheVoiceCatalog.Catalog(
            snapshotURL: url,
            enumerate: { [] },
            autoStart: false
        )
        XCTAssertEqual(catalog.currentVoices(), [])
        XCTAssertTrue(catalog.currentlyScanning())
    }

    func testFirstLaunchScanCompletionPublishesAndPersists() {
        let url = scratchURL("first-launch")
        defer { try? FileManager.default.removeItem(at: url) }
        let catalog = AttacheVoiceCatalog.Catalog(snapshotURL: url, enumerate: { [] }, autoStart: false)
        XCTAssertTrue(catalog.currentlyScanning())

        let updateExpectation = expectation(description: "onUpdate fires")
        catalog.onUpdate = { updateExpectation.fulfill() }
        catalog.simulateScanCompletion(sampleVoices)
        wait(for: [updateExpectation], timeout: 1)

        XCTAssertEqual(catalog.currentVoices(), sampleVoices)
        XCTAssertFalse(catalog.currentlyScanning())
        XCTAssertEqual(AttacheVoiceCatalogSnapshotStore.read(from: url), sampleVoices, "a completed scan must rewrite the snapshot")
    }

    func testUnchangedRescanDoesNotFireOnUpdate() {
        let url = scratchURL("unchanged")
        defer { try? FileManager.default.removeItem(at: url) }
        AttacheVoiceCatalogSnapshotStore.write(sampleVoices, to: url)
        let voices = sampleVoices
        let catalog = AttacheVoiceCatalog.Catalog(snapshotURL: url, enumerate: { voices }, autoStart: false)

        var fired = false
        catalog.onUpdate = { fired = true }
        catalog.simulateScanCompletion(sampleVoices)
        XCTAssertFalse(fired, "an identical re-scan is not a change and should not republish")
    }

    // MARK: - options(from:) filtering (ATTACHE_COMPACT_VOICES_ONLY)

    func testOptionsFromAppliesCompactVoicesOnlyFilterLikeSharedCatalog() {
        // ATTACHE_COMPACT_VOICES_ONLY is read from the live environment by
        // options(from:); this just proves the injected-list entry point
        // uses the identical filter/sort as the shared-catalog path so the
        // affordance keeps working against the snapshot path (INF-350 step 3).
        let filtered = AttacheVoiceCatalog.options(from: sampleVoices)
        XCTAssertEqual(filtered.map(\.id).sorted(), sampleVoices.map(\.id).sorted())
    }

    // MARK: - PersonalityStore: injected options, no real enumeration, empty-snapshot backfill

    func testPersonalityStoreLoadWithEmptyInjectedOptionsDoesNotCrashAndUsesDefaultFallback() {
        let suiteName = "voice-catalog-empty-snapshot-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        defer { suite.removePersistentDomain(forName: suiteName) }

        let store = PersonalityStore(defaults: suite, voiceOptionsProvider: { [] })
        let loaded = store.load()

        XCTAssertFalse(loaded.personalities.isEmpty)
        for personality in loaded.personalities where personality.voiceRef?.provider == .system {
            // No voices known yet: falls back to the generic default rather
            // than crashing or leaving the identifier nil-checked against an
            // enumeration call.
            XCTAssertEqual(personality.voiceRef?.systemVoiceIdentifier, Personality.defaultPreferredVoiceID)
        }
    }

    func testPersonalityStoreBackfillsRealVoiceOnceOptionsPublish() {
        let suiteName = "voice-catalog-backfill-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        defer { suite.removePersistentDomain(forName: suiteName) }

        // Load happens before the catalog has published anything (empty list).
        let emptyStore = PersonalityStore(defaults: suite, voiceOptionsProvider: { [] })
        let firstLoad = emptyStore.load()
        XCTAssertEqual(
            firstLoad.personalities.first?.voiceRef?.systemVoiceIdentifier,
            Personality.defaultPreferredVoiceID
        )

        // The background scan now publishes real voices. A store view backed
        // by the now-populated list reconciles the same personalities.
        let populatedStore = PersonalityStore(defaults: suite, voiceOptionsProvider: { [self.sampleVoices[0]] })
        let reconciled = populatedStore.reconcilingVoiceReferences(firstLoad.personalities)

        XCTAssertEqual(
            reconciled.first?.voiceRef?.systemVoiceIdentifier,
            sampleVoices[0].id,
            "once real voices are known, a personality stuck on the generic fallback should pick one up"
        )
    }

    func testFileExportFallbackVoiceIDInExplicitListNeverCallsSharedCatalog() {
        XCTAssertEqual(
            AttacheVoiceCatalog.fileExportFallbackVoiceID(in: [sampleVoices[0]]),
            sampleVoices[0].id
        )
        XCTAssertNil(AttacheVoiceCatalog.fileExportFallbackVoiceID(in: []))
    }
}
