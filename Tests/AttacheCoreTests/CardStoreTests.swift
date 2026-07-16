import AttacheCore
import XCTest

final class CardStoreTests: XCTestCase {
    func testFreshSavedHistoryAndAudioDirectoriesUsePrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-card-permissions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("cards.sqlite")
        let store = try CardStore(databaseURL: databaseURL)
        _ = try store.insertEvent(EventNormalizer.simulatedEvent(projectPath: "/tmp/private"))

        let rootAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual(((rootAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o700)
        let audioAttributes = try FileManager.default.attributesOfItem(atPath: store.audioAssetsPath)
        XCTAssertEqual(((audioAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o700)
        for path in [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"]
            where FileManager.default.fileExists(atPath: path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            XCTAssertEqual(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o600, path)
        }
    }

    func testLegacySavedHistoryAndNarrationArtifactsAreHardenedOnOpen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-card-permissions-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("cards.sqlite")
        XCTAssertTrue(FileManager.default.createFile(atPath: databaseURL.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: databaseURL.path)
        let audioDirectory = root.appendingPathComponent("audio-assets", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let audioURL = audioDirectory.appendingPathComponent("legacy-private-recap.aiff")
        XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("private narration".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: audioURL.path)

        _ = try CardStore(databaseURL: databaseURL)

        for path in [databaseURL.path, audioURL.path] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            XCTAssertEqual(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o600, path)
        }
        let audioDirectoryAttributes = try FileManager.default.attributesOfItem(atPath: audioDirectory.path)
        XCTAssertEqual(
            ((audioDirectoryAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777,
            0o700
        )
    }

    func testInMemoryStoreExposesAnExplicitNonFilesystemIdentity() throws {
        let store = try CardStore.inMemory()
        XCTAssertTrue(store.isInMemory)
        XCTAssertEqual(store.databasePath, ":memory:")
    }

    func testInsertBindsCompiledReceiptToStableCardIDAndPersistsIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-card-receipt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CardStore(databaseURL: root.appendingPathComponent("cards.sqlite"))
        let pending = AttacheContextReceiptView(cardID: "pending-request", attempts: [], noModelContext: true)
        var event = EventNormalizer.simulatedEvent(projectPath: "/tmp/receipt")
        event.metadata[AttacheContextReceiptView.metadataKey] = try XCTUnwrap(pending.encodedMetadataValue())

        let inserted = try store.insertEvent(event)
        let reloaded = try store.fetchCard(id: inserted.id)

        XCTAssertEqual(reloaded.contextReceipt?.cardID, inserted.id)
        XCTAssertEqual(reloaded.contextReceipt?.noModelContext, true)
        XCTAssertNotEqual(reloaded.contextReceipt?.cardID, "pending-request")
    }

    func testConcurrentInstructionReadsAndWritesSerializePreparedStatements() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-card-store-concurrency-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CardStore(databaseURL: root.appendingPathComponent("cards.sqlite"))

        let iterations = 400
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            let instruction = Instruction(
                id: "instruction-\(index % 8)",
                sessionID: "session-\(index % 4)",
                sourceKind: "codex",
                text: "Reply \(index)",
                state: .pending,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                origin: .personalityTool
            )
            try? store.upsertInstruction(instruction)
            _ = try? store.fetchInstruction(id: instruction.id)
            _ = try? store.fetchInstructions(forSessionID: instruction.sessionID)
        }

        XCTAssertFalse(try store.fetchInstructionLog(limit: iterations).isEmpty)
    }

    func testEventCreatesUnreadCardAndPersistsAcrossStoreRestart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttacheTests-\(UUID().uuidString)", isDirectory: true)
        let dbURL = root.appendingPathComponent("cards.sqlite")

        let event = EventNormalizer.simulatedEvent(projectPath: "/tmp/attache")
        let firstStore = try CardStore(databaseURL: dbURL)
        let inserted = try firstStore.insertEvent(event)

        XCTAssertEqual(inserted.status, .unread)
        XCTAssertEqual(inserted.sourceDisplayName, "Codex")
        XCTAssertEqual(inserted.projectPath, "/tmp/attache")
        XCTAssertFalse(inserted.spokenText.isEmpty)
        XCTAssertFalse(inserted.alignment?.words.isEmpty ?? true)

        let secondStore = try CardStore(databaseURL: dbURL)
        let cards = try secondStore.fetchCards()
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].id, inserted.id)
        XCTAssertEqual(cards[0].status, .unread)

        try secondStore.markHeard(cardID: inserted.id)
        let heard = try secondStore.fetchCard(id: inserted.id)
        XCTAssertEqual(heard.status, .heard)
        XCTAssertNotNil(heard.heardAt)
    }

    func testCardStoreUsesPresentationTextInsteadOfFirstSentenceSummaryForSpeech() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttacheTests-\(UUID().uuidString)", isDirectory: true)
        let dbURL = root.appendingPathComponent("cards.sqlite")
        let store = try CardStore(databaseURL: dbURL)
        let event = NormalizedEvent(
            source: "codex",
            eventType: "assistant.completed",
            externalSessionID: "session-1",
            projectPath: "/tmp/demo",
            title: "Attached Codex response",
            text: "Technically yes, but I would not make that my first test path. The cleaner test is to use a secondary account, then verify the connection lands correctly.",
            metadata: [
                "companion_summary": "Safer test path recommended",
                "companion_spoken_text": "Use a secondary account as the cleaner test path. Verify the connection lands correctly before touching the main account."
            ]
        )

        let card = try store.insertEvent(event)

        XCTAssertEqual(card.summary, "Safer test path recommended")
        XCTAssertEqual(
            card.spokenText,
            "Use a secondary account as the cleaner test path. Verify the connection lands correctly before touching the main account."
        )
        XCTAssertFalse(card.spokenText.hasPrefix("Attached Codex response"))
    }

    func testSameTurnFromTwoPathsDedupesToOneCard() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttacheTests-\(UUID().uuidString)", isDirectory: true)
        let dbURL = root.appendingPathComponent("cards.sqlite")
        let store = try CardStore(databaseURL: dbURL)

        // The same agent turn (same session, source time, and content) arriving via
        // the watcher and again via the HTTP hook must produce one card.
        func turnEvent() -> NormalizedEvent {
            NormalizedEvent(
                source: "codex",
                eventType: "assistant.completed",
                externalSessionID: "session-x",
                projectPath: "/tmp/proj",
                title: "Codex",
                text: "The task finished successfully.",
                metadata: ["source_time": "2026-07-02T10:00:01.000Z"]
            )
        }

        let first = try store.insertEvent(turnEvent())
        let second = try store.insertEvent(turnEvent())

        XCTAssertEqual(first.id, second.id, "same turn should collapse to one id")
        XCTAssertEqual(try store.fetchCards().count, 1)
    }

    func testCreatedAtUsesSourceTimeNotInsertTime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttacheTests-\(UUID().uuidString)", isDirectory: true)
        let dbURL = root.appendingPathComponent("cards.sqlite")
        let store = try CardStore(databaseURL: dbURL)

        let card = try store.insertEvent(NormalizedEvent(
            source: "codex",
            eventType: "assistant.completed",
            externalSessionID: "session-y",
            projectPath: "/tmp/proj",
            title: "Codex",
            text: "Older turn.",
            metadata: ["source_time": "2020-01-01T00:00:00.000Z"]
        ))
        // created_at reflects the source time (2020), not now.
        XCTAssertLessThan(card.createdAt.timeIntervalSince1970, 1_600_000_000)
    }

    func testFetchCardsRespectsLimit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttacheTests-\(UUID().uuidString)", isDirectory: true)
        let store = try CardStore(databaseURL: root.appendingPathComponent("cards.sqlite"))
        for i in 0..<10 {
            _ = try store.insertEvent(NormalizedEvent(
                source: "codex", eventType: "assistant.completed", externalSessionID: "s",
                projectPath: "/p", title: "Codex", text: "turn \(i)",
                metadata: ["source_time": "2026-07-02T10:00:\(i < 10 ? "0\(i)" : "\(i)").000Z"]
            ))
        }
        XCTAssertEqual(try store.fetchCards(limit: 3).count, 3)
        XCTAssertEqual(try store.fetchCards().count, 10)
    }

    func testPruneRemovesOldArchivedCardsOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttacheTests-\(UUID().uuidString)", isDirectory: true)
        let store = try CardStore(databaseURL: root.appendingPathComponent("cards.sqlite"))

        // Old + archived (source_time years ago) -> pruned.
        let old = try store.insertEvent(NormalizedEvent(
            source: "codex", eventType: "assistant.completed", externalSessionID: "s1",
            projectPath: "/p", title: "Codex", text: "old", metadata: ["source_time": "2020-01-01T00:00:00.000Z"]))
        try store.markHeard(cardID: old.id)
        try store.archiveAll()   // archives everything so far

        // Recent unread -> kept.
        let recent = try store.insertEvent(EventNormalizer.simulatedEvent(projectPath: "/p2"))

        let removed = try store.pruneArchivedCards(olderThan: 90)
        XCTAssertEqual(removed, 1)
        let remaining = try store.fetchCards(includeArchived: true)
        XCTAssertEqual(remaining.map(\.id), [recent.id])
    }

    func testMetadataDoesNotDuplicateRawText() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttacheTests-\(UUID().uuidString)", isDirectory: true)
        let store = try CardStore(databaseURL: root.appendingPathComponent("cards.sqlite"))
        let card = try store.insertEvent(NormalizedEvent(
            source: "codex", eventType: "assistant.completed", externalSessionID: "s",
            projectPath: "/p", title: "Codex", text: "UNIQUE_TRANSCRIPT_BODY"))
        // raw_text holds the body; metadata must not embed a second copy.
        XCTAssertEqual(card.rawText, "UNIQUE_TRANSCRIPT_BODY")
        XCTAssertFalse(card.metadataJSON.contains("normalized_event_json"))
        XCTAssertFalse(card.metadataJSON.contains("UNIQUE_TRANSCRIPT_BODY"))
    }

    func testInsertEventCanCreateHeardSessionHistoryCard() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttacheTests-\(UUID().uuidString)", isDirectory: true)
        let store = try CardStore(databaseURL: root.appendingPathComponent("cards.sqlite"))
        let event = NormalizedEvent(
            source: "codex",
            eventType: "companion.conversation.reply",
            externalSessionID: "session-a",
            projectPath: "/tmp/session-a",
            title: "Attache reply",
            text: "The issue is probably scoped to the local app settings.",
            metadata: [
                "companion_history_kind": "direct_reply",
                "companion_summary": "Local app settings likely matter",
                "companion_spoken_text": "The issue is probably scoped to the local app settings.",
                "companion_direct_reply": "true"
            ]
        )

        let card = try store.insertEvent(event, status: .heard)

        XCTAssertEqual(card.status, .heard)
        XCTAssertNotNil(card.heardAt)
        XCTAssertEqual(card.summary, "Local app settings likely matter")
        XCTAssertEqual(card.externalSessionID, "session-a")
        XCTAssertTrue(try store.fetchCards().filter { $0.status == .unread }.isEmpty)

        let history = try store.recentCards(forExternalSessionID: "session-a")
        XCTAssertEqual(history.map(\.id), [card.id])
        XCTAssertEqual(history.first?.status, .heard)
    }

    func testArchiveAllHidesReadAndUnreadCards() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttacheTests-\(UUID().uuidString)", isDirectory: true)
        let dbURL = root.appendingPathComponent("cards.sqlite")
        let store = try CardStore(databaseURL: dbURL)

        var firstEvent = EventNormalizer.simulatedEvent(projectPath: "/tmp/one")
        firstEvent.metadata["source_time"] = "2026-07-09T19:00:00.000Z"
        var secondEvent = EventNormalizer.simulatedEvent(projectPath: "/tmp/two")
        secondEvent.metadata["source_time"] = "2026-07-09T19:00:01.000Z"
        let first = try store.insertEvent(firstEvent)
        _ = try store.insertEvent(secondEvent)
        try store.markHeard(cardID: first.id)

        XCTAssertEqual(try store.fetchCards().count, 2)

        try store.archiveAll()

        XCTAssertTrue(try store.fetchCards().isEmpty)
        XCTAssertEqual(try store.fetchCards(includeArchived: true).count, 2)
    }

    func testRecentCardsForExternalSessionIDFiltersOrdersAndHandlesArchivedCards() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttacheTests-\(UUID().uuidString)", isDirectory: true)
        let dbURL = root.appendingPathComponent("cards.sqlite")
        let store = try CardStore(databaseURL: dbURL)

        let firstSessionCard = try store.insertEvent(historyEvent(
            sessionID: "session-a",
            summary: "First session A recap"
        ))
        try store.markHeard(cardID: firstSessionCard.id)
        Thread.sleep(forTimeInterval: 0.01)

        _ = try store.insertEvent(historyEvent(
            sessionID: "session-b",
            summary: "Session B recap"
        ))
        Thread.sleep(forTimeInterval: 0.01)

        let secondSessionCard = try store.insertEvent(historyEvent(
            sessionID: "session-a",
            summary: "Second session A recap"
        ))

        var sessionHistory = try store.recentCards(forExternalSessionID: "session-a")
        XCTAssertEqual(sessionHistory.map(\.id), [secondSessionCard.id, firstSessionCard.id])
        XCTAssertEqual(sessionHistory.first?.summary, "Second session A recap")
        XCTAssertTrue(sessionHistory.contains { $0.status == .heard })
        XCTAssertFalse(sessionHistory.contains { $0.externalSessionID == "session-b" })

        try store.archive(cardID: secondSessionCard.id)
        sessionHistory = try store.recentCards(forExternalSessionID: "session-a")
        XCTAssertEqual(sessionHistory.map(\.id), [firstSessionCard.id])

        let includingArchived = try store.recentCards(
            forExternalSessionID: "session-a",
            includeArchived: true
        )
        XCTAssertEqual(includingArchived.map(\.id), [secondSessionCard.id, firstSessionCard.id])
    }

    func testPermanentDeleteRemovesOnlyRequestedCards() throws {
        let store = try CardStore.inMemory()
        var firstEvent = historyEvent(sessionID: "private-a", summary: "First private reply")
        firstEvent.metadata["source_time"] = "2026-07-16T10:00:00.000Z"
        var secondEvent = historyEvent(sessionID: "private-a", summary: "Second private reply")
        secondEvent.metadata["source_time"] = "2026-07-16T10:00:01.000Z"
        var keepEvent = historyEvent(sessionID: "keep", summary: "Keep this reply")
        keepEvent.metadata["source_time"] = "2026-07-16T10:00:02.000Z"
        let first = try store.insertEvent(firstEvent)
        let second = try store.insertEvent(secondEvent)
        let keep = try store.insertEvent(keepEvent)

        XCTAssertEqual(try store.deleteCards(ids: [first.id, second.id]), 2)
        XCTAssertEqual(try store.fetchCards(includeArchived: true).map(\.id), [keep.id])
        XCTAssertFalse(try store.deleteCard(id: first.id))
    }

    private func historyEvent(sessionID: String, summary: String) -> NormalizedEvent {
        NormalizedEvent(
            source: "codex",
            eventType: "assistant.completed",
            externalSessionID: sessionID,
            projectPath: "/tmp/\(sessionID)",
            title: "History \(sessionID)",
            text: "\(summary). Full Codex response is preserved for the card.",
            metadata: [
                "companion_summary": summary,
                "companion_spoken_text": "\(summary). This is the personalized spoken recap."
            ]
        )
    }
}
