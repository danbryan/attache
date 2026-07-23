import AppKit
import AttacheCore
import XCTest
@testable import AttacheApp

/// A watched session lives in `AppModel.attachedTargets` (persisted to
/// `attache.watchedSessions`). If its record is not in the current Command-K
/// search/index (archived with Archived off, aged out of the transcript index,
/// or its files removed), the picker produced no row for it, so the dock still
/// said "Watching N" with no way to unwatch. These tests cover the fix:
/// orphaned watched rows are always injected into Command-K, unwatch is
/// index-independent, and the dock exposes a discoverable watching menu.
@MainActor
final class OrphanedWatchedSessionTests: XCTestCase {
    private static let touchedKeys = [
        AttachePreferenceKey.attachedCodexSessionID,
        AttachePreferenceKey.watchedSessions,
        AttachePreferenceKey.codexSourceEnabled,
        AttachePreferenceKey.claudeCodeSourceEnabled
    ]

    private func restoringDefaults(_ body: () throws -> Void) rethrows {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        var saved: [String: Any] = [:]
        for key in Self.touchedKeys where defaults.object(forKey: key) != nil {
            saved[key] = defaults.object(forKey: key)
        }
        defer {
            for key in Self.touchedKeys {
                if let value = saved[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        try body()
    }

    private func target(
        id: String,
        title: String,
        category: CodexAttachmentCategory = .activeSession
    ) -> CodexSessionTarget {
        CodexSessionTarget(
            id: id,
            title: title,
            updatedAt: Date(),
            category: category,
            status: nil,
            sourceKind: .codex
        )
    }

    /// Seed the watch list through the persisted defaults so `AppModel` loads
    /// it on init, exactly as a real relaunch would.
    private func makeModel(watching targets: [CodexSessionTarget]) throws -> AppModel {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: AttachePreferenceKey.attachedCodexSessionID)
        defaults.set(true, forKey: AttachePreferenceKey.codexSourceEnabled)
        defaults.set(try JSONEncoder().encode(targets), forKey: AttachePreferenceKey.watchedSessions)
        return AppModel(store: try CardStore.inMemory())
    }

    // MARK: - Orphan row injection (pure)

    func testInjectsSyntheticRowForWatchedIDAbsentFromSearchResults() {
        let watched = target(id: "orphan-1", title: "Aged-out session")
        // Empty search results (its transcript aged out of the index).
        let injected = SessionCommandPalette.injectingOrphanWatchedRows(
            into: [],
            watched: [watched],
            sourceFilter: nil
        )
        XCTAssertEqual(injected.map(\.record.id), ["orphan-1"])
        XCTAssertEqual(injected.first?.record.title, "Aged-out session")
        // Synthetic rows carry no transcript, so a content query never matches.
        XCTAssertEqual(injected.first?.record.content, "")
        XCTAssertFalse(injected.first?.matchedContent ?? true)
    }

    func testDoesNotDuplicateWatchedRowAlreadyPresentInSearchResults() {
        let record = SessionRecord(
            id: "present-1", title: "Live session", project: nil, threadName: nil,
            updatedAt: Date(), archived: false, filePath: "/tmp/x.jsonl",
            fileMtime: 0, content: "hello", sourceKind: .codex
        )
        let present = SessionSearchHit(record: record, score: 5, matchedContent: false, snippet: nil)
        let injected = SessionCommandPalette.injectingOrphanWatchedRows(
            into: [present],
            watched: [target(id: "present-1", title: "Live session")],
            sourceFilter: nil
        )
        XCTAssertEqual(injected.count, 1)
        XCTAssertEqual(injected.first?.record.id, "present-1")
    }

    func testArchivedWatchedSessionStillInjectedWithArchivedOff() {
        // The caller passes hits already filtered to hide archived (Archived
        // off), so an archived watched session is absent. It must still appear.
        let watched = target(id: "archived-1", title: "Archived session", category: .archivedSession)
        let injected = SessionCommandPalette.injectingOrphanWatchedRows(
            into: [],
            watched: [watched],
            sourceFilter: nil
        )
        XCTAssertEqual(injected.map(\.record.id), ["archived-1"])
        XCTAssertTrue(injected.first?.record.archived ?? false)
    }

    func testInjectionHonorsActiveSourceFilter() {
        var claudeTarget = target(id: "claude-1", title: "Claude session")
        claudeTarget.sourceKind = .claudeCode
        let codexTarget = target(id: "codex-1", title: "Codex session")
        let injected = SessionCommandPalette.injectingOrphanWatchedRows(
            into: [],
            watched: [claudeTarget, codexTarget],
            sourceFilter: .codex
        )
        XCTAssertEqual(injected.map(\.record.id), ["codex-1"])
    }

    // MARK: - Unwatch is index-independent

    func testUnwatchViaInjectedRowDetachesEvenWhenNotInIndex() throws {
        try restoringDefaults {
            let watched = target(id: "orphan-2", title: "Cannot resolve")
            let model = try makeModel(watching: [watched])
            XCTAssertNotNil(model.attachedTargets["orphan-2"])

            // A synthetic hit whose record is not in the live index: resolving
            // it would fail, but unwatch must still succeed.
            let synthetic = SessionSearchHit(
                record: watched.syntheticSessionRecord(),
                score: 0, matchedContent: false, snippet: nil
            )
            model.toggleWatchSearchHit(synthetic)

            XCTAssertNil(model.attachedTargets["orphan-2"])
            // Persisted: a relaunch would not resurrect it.
            let data = try XCTUnwrap(UserDefaults.standard.data(forKey: AttachePreferenceKey.watchedSessions))
            let stored = try JSONDecoder().decode([CodexSessionTarget].self, from: data)
            XCTAssertFalse(stored.contains { $0.id == "orphan-2" })
        }
    }

    func testDetachCodexSessionRemovesPersistsAndClearsFocus() throws {
        try restoringDefaults {
            let model = try makeModel(watching: [
                target(id: "a", title: "Session A"),
                target(id: "b", title: "Session B")
            ])
            model.focusCodexSession("a")
            XCTAssertEqual(model.attachedCodexSessionID, "a")

            model.detachCodexSession("a")

            XCTAssertNil(model.attachedTargets["a"])
            // Focus moved to the remaining watched session, not left dangling.
            XCTAssertEqual(model.attachedCodexSessionID, "b")
            let data = try XCTUnwrap(UserDefaults.standard.data(forKey: AttachePreferenceKey.watchedSessions))
            let stored = try JSONDecoder().decode([CodexSessionTarget].self, from: data)
            XCTAssertEqual(stored.map(\.id), ["b"])
        }
    }

    // MARK: - Stop watching all

    func testStopWatchingAllEmptiesAttachedTargets() throws {
        try restoringDefaults {
            let model = try makeModel(watching: [
                target(id: "a", title: "Session A"),
                target(id: "b", title: "Session B"),
                target(id: "c", title: "Session C")
            ])
            XCTAssertEqual(model.attachedTargets.count, 3)

            model.stopWatchingAll()

            XCTAssertTrue(model.attachedTargets.isEmpty)
            XCTAssertNil(model.attachedCodexSessionID)
            let data = try XCTUnwrap(UserDefaults.standard.data(forKey: AttachePreferenceKey.watchedSessions))
            let stored = try JSONDecoder().decode([CodexSessionTarget].self, from: data)
            XCTAssertTrue(stored.isEmpty)
        }
    }

    // MARK: - Dock watching menu data source

    func testDockWatchingMenuListsStoredTitles() throws {
        try restoringDefaults {
            let model = try makeModel(watching: [
                target(id: "a", title: "Tax filing session"),
                target(id: "b", title: "Snapshot repair")
            ])
            // The dock's watching menu is built from attachedSessionList; each
            // row's Stop watching label uses the stored displayTitle.
            let titles = Set(model.attachedSessionList.map(\.displayTitle))
            XCTAssertEqual(titles, ["Tax filing session", "Snapshot repair"])
        }
    }
}
