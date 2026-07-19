import AttacheCore
import XCTest
@testable import AttacheApp

final class AttacheMemoryRuntimeTests: XCTestCase {
    private func makeRuntime() throws -> (AttacheMemoryRuntime, URL, UserDefaults) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-memory-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "AttacheMemoryRuntimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let legacyURL = root.appendingPathComponent("AttacheMemory.md")
        try AttachePersonality.defaultMemoryFileText.write(
            to: legacyURL,
            atomically: true,
            encoding: .utf8
        )
        let snapshot = AttacheMemorySnapshot(
            fileURL: legacyURL,
            rawText: AttachePersonality.defaultMemoryFileText,
            context: nil,
            errorDescription: nil
        )
        return (
            AttacheMemoryRuntime(
                databaseURL: root.appendingPathComponent("memory.sqlite"),
                legacySnapshot: snapshot,
                defaults: defaults
            ),
            root,
            defaults
        )
    }

    /// The retired suggestion review queue's persistence file is removed at
    /// launch so no stale pre-explicit-only state lingers beside the ledger.
    func testStaleReviewQueueFileIsRemovedAtLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-memory-stale-queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appendingPathComponent("AttacheMemory.md")
        try AttachePersonality.defaultMemoryFileText.write(to: legacyURL, atomically: true, encoding: .utf8)
        let queueURL = root.appendingPathComponent("memory-review-queue.json")
        try Data("[]".utf8).write(to: queueURL)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "memory-stale-queue.\(UUID().uuidString)"))

        _ = AttacheMemoryRuntime(
            databaseURL: root.appendingPathComponent("memory.sqlite"),
            legacySnapshot: AttacheMemorySnapshot(
                fileURL: legacyURL,
                rawText: AttachePersonality.defaultMemoryFileText,
                context: nil,
                errorDescription: nil
            ),
            defaults: defaults
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL.path))
    }

    /// An explicit low-sensitivity save exists to be used by whatever model
    /// the personality talks to, so the requested allowedRemote egress is
    /// honored. Creation times are stamped at save, never the 1970 epoch.
    func testExplicitLowSensitivitySaveHonorsRequestedRemoteEgressAndStampsDates() throws {
        let (runtime, root, _) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }

        let disposition = runtime.processProposal(
            statement: "I prefer concise answers.",
            type: .preference,
            scope: .global,
            sensitivity: .low,
            egress: .allowedRemote,
            sourceLocator: "call-1:turn-1",
            mode: .on
        )

        guard case .saved = disposition else {
            return XCTFail("Expected the explicit memory to save immediately")
        }
        let record = try XCTUnwrap(runtime.activeRecords.first)
        XCTAssertEqual(record.statement, "I prefer concise answers.")
        XCTAssertEqual(record.egress, .allowedRemote)
        XCTAssertLessThan(abs(record.createdAt.timeIntervalSinceNow), 300)
        XCTAssertLessThan(abs(record.updatedAt.timeIntervalSinceNow), 300)
    }

    /// The egress clamp: a request can narrow to localOnly and be honored, and
    /// anything above low sensitivity is forced local-only regardless of the
    /// requested value.
    func testRequestedLocalOnlyIsHonoredAndAboveLowSensitivityForcesLocalOnly() throws {
        let (runtime, root, _) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = runtime.processProposal(
            statement: "My private nickname is Ultramarine.",
            type: .userFact, scope: .global, sensitivity: .low,
            egress: .localOnly, sourceLocator: "call-1:turn-1",
            mode: .on
        )
        _ = runtime.processProposal(
            statement: "I keep a standing meeting on Fridays.",
            type: .userFact, scope: .global, sensitivity: .medium,
            egress: .allowedRemote, sourceLocator: "call-1:turn-2",
            mode: .on
        )

        let byStatement = Dictionary(uniqueKeysWithValues: runtime.activeRecords.map { ($0.statement, $0) })
        XCTAssertEqual(byStatement["My private nickname is Ultramarine."]?.egress, .localOnly)
        XCTAssertEqual(byStatement["I keep a standing meeting on Fridays."]?.egress, .localOnly)
    }

    /// Regression for Dan's 2026-07-19 recall failure: an explicit save was
    /// forced local-only, his personality model is remote, and the selector
    /// correctly excludes local-only memories from remote requests, so "do you
    /// remember my name" found nothing. The explicit low-sensitivity save is
    /// now usable by the remote model.
    func testDanRecallRegressionExplicitSaveIsSelectableForRemoteRequests() throws {
        let (runtime, root, _) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }

        let disposition = runtime.processProposal(
            statement: "My name is Dan.",
            type: .userFact, scope: .personality("p1"), sensitivity: .low,
            egress: .allowedRemote, sourceLocator: "call-1:turn-1",
            mode: .on
        )
        guard case .saved = disposition else {
            return XCTFail("Expected the explicit name memory to save")
        }

        let remote = runtime.contextItems(
            userTurn: "Do you remember my name?", personalityID: "p1",
            strategy: .automatic, memoryBudgetTokens: 1_000, requestIsRemote: true
        )
        let local = runtime.contextItems(
            userTurn: "Do you remember my name?", personalityID: "p1",
            strategy: .automatic, memoryBudgetTokens: 1_000, requestIsRemote: false
        )

        XCTAssertEqual(remote.items.count, 1, "the saved name must be usable by the remote model")
        XCTAssertTrue(remote.items.first?.content.contains("My name is Dan.") == true)
        XCTAssertEqual(local.items.count, 1)
    }

    /// Rows stamped with the 1970 epoch by the earlier save path are repaired
    /// to a current timestamp once at launch.
    func testEpochZeroTimestampsAreRepairedAtLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-memory-epoch-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appendingPathComponent("AttacheMemory.md")
        try AttachePersonality.defaultMemoryFileText.write(to: legacyURL, atomically: true, encoding: .utf8)
        let databaseURL = root.appendingPathComponent("memory.sqlite")
        let ledger = AttacheMemoryLedger(databaseURL: databaseURL)
        XCTAssertTrue(ledger.add(AttacheMemoryRecord(
            id: "memory.epoch-zero",
            statement: "My name is Dan.",
            type: .userFact
        )))
        XCTAssertEqual(ledger.list(activeOnly: true).first?.createdAt, Date(timeIntervalSince1970: 0))

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "memory-epoch-repair.\(UUID().uuidString)"))
        let runtime = AttacheMemoryRuntime(
            databaseURL: databaseURL,
            legacySnapshot: AttacheMemorySnapshot(
                fileURL: legacyURL,
                rawText: AttachePersonality.defaultMemoryFileText,
                context: nil,
                errorDescription: nil
            ),
            defaults: defaults
        )

        let repaired = try XCTUnwrap(runtime.activeRecords.first { $0.id == "memory.epoch-zero" })
        XCTAssertLessThan(abs(repaired.createdAt.timeIntervalSinceNow), 300)
        XCTAssertLessThan(abs(repaired.updatedAt.timeIntervalSinceNow), 300)
    }

    func testLocalOnlyMemoryNeverEntersRemoteRequest() throws {
        let (runtime, root, _) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = runtime.processProposal(
            statement: "My private nickname is Blue.", type: .userFact, scope: .global,
            sensitivity: .low, egress: .localOnly, sourceLocator: "call-1:turn-1",
            mode: .on
        )

        let local = runtime.contextItems(
            userTurn: "What is my private nickname?", personalityID: "p1",
            strategy: .automatic, memoryBudgetTokens: 1_000, requestIsRemote: false
        )
        let remote = runtime.contextItems(
            userTurn: "What is my private nickname?", personalityID: "p1",
            strategy: .automatic, memoryBudgetTokens: 1_000, requestIsRemote: true
        )

        XCTAssertEqual(local.items.count, 1)
        XCTAssertTrue(remote.items.isEmpty)
        XCTAssertEqual(remote.receipt.first?.omissionReason, "local-only-egress")
    }

    func testSelectedMemoryRecordsLastUseButUnrelatedMemoryDoesNot() throws {
        let (runtime, root, _) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = runtime.processProposal(
            statement: "I prefer concise answers.", type: .preference, scope: .global,
            sensitivity: .low, egress: .localOnly, sourceLocator: "call-1:turn-1",
            mode: .on
        )
        _ = runtime.processProposal(
            statement: "I enjoy hiking on weekends.", type: .preference, scope: .global,
            sensitivity: .low, egress: .localOnly, sourceLocator: "call-1:turn-2",
            mode: .on
        )

        let selected = runtime.contextItems(
            userTurn: "Please give me a concise answer.", personalityID: "p1",
            strategy: .automatic, memoryBudgetTokens: 1_000, requestIsRemote: false
        )

        XCTAssertEqual(selected.items.count, 1)
        let byStatement = Dictionary(uniqueKeysWithValues: runtime.activeRecords.map { ($0.statement, $0) })
        XCTAssertNotNil(byStatement["I prefer concise answers."]?.lastUsedAt)
        XCTAssertNil(byStatement["I enjoy hiking on weekends."]?.lastUsedAt)
    }

    @MainActor
    func testExplicitNativeEgressChangeMakesMemoryAvailableToRemoteModel() throws {
        let (runtime, root, defaults) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AttacheContextUIState(defaults: defaults)
        runtime.bind(to: state)
        let disposition = runtime.processProposal(
            statement: "I prefer concise answers.", type: .preference,
            scope: .global, sensitivity: .low, egress: .localOnly,
            sourceLocator: "call-1:turn-1",
            mode: .on
        )
        guard case .saved(let record) = disposition else {
            return XCTFail("Expected a local memory")
        }
        runtime.publish(to: state)

        XCTAssertTrue(runtime.contextItems(
            userTurn: "I prefer concise answers.", personalityID: "p1",
            strategy: .automatic, memoryBudgetTokens: 1_000,
            requestIsRemote: true
        ).items.isEmpty)

        state.setMemoryEgress(id: record.id, egress: .allowedRemote)
        XCTAssertEqual(state.memoryRecords.first?.egress, .allowedRemote)
        XCTAssertEqual(runtime.activeRecords.first?.egress, .allowedRemote)
        XCTAssertEqual(runtime.contextItems(
            userTurn: "I prefer concise answers.", personalityID: "p1",
            strategy: .automatic, memoryBudgetTokens: 1_000,
            requestIsRemote: true
        ).items.count, 1)

        // The pane control round-trips: narrowing back to local-only excludes
        // the record from remote requests again.
        let widened = try XCTUnwrap(state.memoryRecords.first)
        state.setMemoryEgress(id: widened.id, egress: .localOnly)
        XCTAssertEqual(state.memoryRecords.first?.egress, .localOnly)
        XCTAssertEqual(runtime.activeRecords.first?.egress, .localOnly)
        XCTAssertTrue(runtime.contextItems(
            userTurn: "I prefer concise answers.", personalityID: "p1",
            strategy: .automatic, memoryBudgetTokens: 1_000,
            requestIsRemote: true
        ).items.isEmpty)
    }

    func testTopicScopedMemoryRequiresExactTopic() throws {
        let (runtime, root, _) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = runtime.processProposal(
            statement: "Use the cash method for tax planning.", type: .projectTopic,
            scope: .topic("tax"), sensitivity: .low, egress: .allowedRemote,
            sourceLocator: "call-1:turn-1", mode: .on
        )

        let wrongTopic = runtime.contextItems(
            userTurn: "How should we plan?", personalityID: "p1", explicitTopic: "travel",
            strategy: .automatic, memoryBudgetTokens: 1_000, requestIsRemote: false
        )
        let exactTopic = runtime.contextItems(
            userTurn: "How should we plan taxes?", personalityID: "p1", explicitTopic: "tax",
            strategy: .automatic, memoryBudgetTokens: 1_000, requestIsRemote: false
        )

        XCTAssertTrue(wrongTopic.items.isEmpty)
        XCTAssertEqual(exactTopic.items.count, 1)
    }

    func testTopicScopeIsResolvedOnlyFromAnExplicitUserPhrase() throws {
        let (runtime, root, _) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = runtime.processProposal(
            statement: "Use the cash method for Maryland taxes.", type: .projectTopic,
            scope: .topic("Maryland taxes"), sensitivity: .low, egress: .allowedRemote,
            sourceLocator: "call-1:turn-1", mode: .on
        )
        _ = runtime.processProposal(
            statement: "Keep the packing list short.", type: .projectTopic,
            scope: .topic("travel"), sensitivity: .low, egress: .allowedRemote,
            sourceLocator: "call-1:turn-2", mode: .on
        )

        XCTAssertNil(runtime.explicitTopic(matching: "What should we work on next?"))
        XCTAssertNil(runtime.explicitTopic(matching: "What tax approach should I use?"))
        XCTAssertEqual(
            runtime.explicitTopic(matching: "What should I remember about Maryland taxes?"),
            "Maryland taxes"
        )
        XCTAssertEqual(runtime.explicitTopic(matching: "Let's discuss travel."), "travel")
    }

    func testMemoryProposalParsingBindsPersonalityScopeLocally() throws {
        let arguments = #"{"statement":"I prefer concise answers.","type":"preference","sensitivity":"low","egress":"allowedRemote"}"#
        let decoded = try XCTUnwrap(AppModel.memoryProposalArguments(
            fromToolArguments: arguments,
            personalityID: "personality-colt"
        ))

        XCTAssertEqual(decoded.statement, "I prefer concise answers.")
        XCTAssertEqual(decoded.type, .preference)
        XCTAssertEqual(decoded.scope, .personality("personality-colt"))
        XCTAssertEqual(decoded.egress, .allowedRemote)
    }

    /// The tool exposes no scope. Even if a model still sends scope-like
    /// fields, they are ignored and the save binds to the active personality;
    /// a model can never create a global or topic row.
    func testToolScopeFieldsCannotProduceGlobalOrTopicRows() throws {
        for arguments in [
            #"{"statement":"I prefer concise answers.","type":"preference","scope":"global","scope_value":"global","sensitivity":"low","egress":"allowedRemote"}"#,
            #"{"statement":"I prefer concise answers.","type":"preference","scope":"topic","scope_value":"taxes","sensitivity":"low","egress":"allowedRemote"}"#
        ] {
            let decoded = try XCTUnwrap(AppModel.memoryProposalArguments(
                fromToolArguments: arguments,
                personalityID: "personality-colt"
            ))
            XCTAssertEqual(decoded.scope, .personality("personality-colt"))
        }
    }

    /// (a) A fact saved with Attaché A is selected for A and never for B.
    func testPersonalityScopedMemoryIsInvisibleToOtherAttaches() throws {
        let (runtime, root, _) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }

        let disposition = runtime.processProposal(
            statement: "My name is Dan.",
            type: .userFact, scope: .personality("attache-a"), sensitivity: .low,
            egress: .allowedRemote, sourceLocator: "call-1:turn-1",
            mode: .on
        )
        guard case .saved = disposition else {
            return XCTFail("Expected the explicit name memory to save")
        }

        let forA = runtime.contextItems(
            userTurn: "Do you remember my name?", personalityID: "attache-a",
            strategy: .automatic, memoryBudgetTokens: 1_000, requestIsRemote: true
        )
        let forB = runtime.contextItems(
            userTurn: "Do you remember my name?", personalityID: "attache-b",
            strategy: .automatic, memoryBudgetTokens: 1_000, requestIsRemote: true
        )

        XCTAssertEqual(forA.items.count, 1)
        XCTAssertTrue(forB.items.isEmpty, "another Attaché must not see this memory")
    }

    /// (b) A Settings-authored global is selected for every Attaché, is
    /// validator-gated, and rejects duplicates.
    func testSettingsAuthoredGlobalMemoryIsSharedAndValidatorGated() throws {
        let (runtime, root, _) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }

        let record = try XCTUnwrap(runtime.addGlobalMemory(statement: "I always prefer metric units."))
        XCTAssertEqual(record.scope, .global)
        XCTAssertEqual(record.sourceKind, .userConfirmed)
        XCTAssertEqual(record.confidence, .authoritative)
        XCTAssertEqual(record.egress, .allowedRemote)
        XCTAssertLessThan(abs(record.createdAt.timeIntervalSinceNow), 300)

        for personality in ["attache-a", "attache-b"] {
            let selected = runtime.contextItems(
                userTurn: "Which units do I prefer, metric or imperial?",
                personalityID: personality,
                strategy: .automatic, memoryBudgetTokens: 1_000, requestIsRemote: true
            )
            XCTAssertEqual(selected.items.count, 1, "global memory must reach \(personality)")
        }

        let countBefore = runtime.activeRecords.count
        XCTAssertNil(
            runtime.addGlobalMemory(statement: "The API key is sk-1234567890abcdef"),
            "the authored path runs the same validator"
        )
        XCTAssertNil(
            runtime.addGlobalMemory(statement: "I always prefer metric units."),
            "duplicates are rejected"
        )
        XCTAssertEqual(runtime.activeRecords.count, countBefore)
    }

    /// The deterministic egress policy table: low sensitivity honors the
    /// requested egress in both directions; anything above low is clamped to
    /// local-only no matter what the tool requested.
    func testToolProposalEgressClampFollowsPolicyTable() {
        XCTAssertEqual(
            AppModel.memoryEgressForToolProposal(.allowedRemote, sensitivity: .low),
            .allowedRemote
        )
        XCTAssertEqual(
            AppModel.memoryEgressForToolProposal(.localOnly, sensitivity: .low),
            .localOnly
        )
        for sensitivity in [AttacheMemorySensitivity.medium, .high, .secret] {
            XCTAssertEqual(
                AppModel.memoryEgressForToolProposal(.allowedRemote, sensitivity: sensitivity),
                .localOnly,
                "\(sensitivity) must clamp to local-only"
            )
            XCTAssertEqual(
                AppModel.memoryEgressForToolProposal(.localOnly, sensitivity: sensitivity),
                .localOnly
            )
        }
    }

    @MainActor
    func testForgetAndUndoRestoresThePersistedRowWithoutPhantomState() throws {
        let (runtime, root, defaults) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AttacheContextUIState(defaults: defaults)
        runtime.bind(to: state)

        let disposition = runtime.processProposal(
            statement: "I prefer concise answers.", type: .preference,
            scope: .global, sensitivity: .low, egress: .localOnly,
            sourceLocator: "call-1:turn-1",
            mode: .on
        )
        guard case .saved(let record) = disposition else {
            return XCTFail("Expected a stored memory")
        }
        runtime.publish(to: state)

        state.forgetMemory(id: record.id)
        XCTAssertTrue(runtime.activeRecords.isEmpty)
        XCTAssertTrue(state.memoryRecords.isEmpty)

        state.undoLastForget()
        XCTAssertEqual(runtime.activeRecords.map(\.id), [record.id])
        XCTAssertEqual(state.memoryRecords.map(\.id), [record.id])
        XCTAssertEqual(state.memoryStatusMessage, "Memory restored.")
    }

    @MainActor
    func testSecretEditIsRejectedAndNeverBecomesAPhantomRecord() throws {
        let (runtime, root, defaults) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AttacheContextUIState(defaults: defaults)
        runtime.bind(to: state)

        let stored = runtime.processProposal(
            statement: "I prefer outcome-first answers.",
            type: .preference,
            scope: .global,
            sensitivity: .low,
            egress: .localOnly,
            sourceLocator: "call-1:turn-2",
            mode: .on
        )
        guard case .saved(let record) = stored else {
            return XCTFail("Expected the safe explicit memory to be stored")
        }
        runtime.publish(to: state)

        state.editMemory(id: record.id, statement: "api_key = do-not-save")

        XCTAssertEqual(runtime.activeRecords.map(\.statement), ["I prefer outcome-first answers."])
        XCTAssertEqual(state.memoryRecords.map(\.statement), ["I prefer outcome-first answers."])
        XCTAssertTrue(state.memoryStatusMessage?.contains("not updated") == true)
    }

    @MainActor
    func testMigrationCreatesVerifiedBackupAndDeleteAllCannotResurrectLegacyMemory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-memory-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appendingPathComponent("AttacheMemory.md")
        let markdown = "# Attaché Memory\n- Prefers concise answers\n"
        try markdown.write(to: legacyURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: legacyURL.path
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "memory-delete.\(UUID().uuidString)"))
        let databaseURL = root.appendingPathComponent("memory.sqlite")
        let snapshot = AttacheMemorySnapshot(
            fileURL: legacyURL,
            rawText: markdown,
            context: nil,
            errorDescription: nil
        )
        let runtime = AttacheMemoryRuntime(
            databaseURL: databaseURL,
            legacySnapshot: snapshot,
            defaults: defaults
        )
        XCTAssertEqual(runtime.activeRecords.map(\.statement), ["Prefers concise answers"])
        let migratedSourceAttributes = try FileManager.default.attributesOfItem(atPath: legacyURL.path)
        XCTAssertEqual(
            ((migratedSourceAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777,
            0o600
        )
        let backupURL = legacyURL.appendingPathExtension("pre-structured-memory-backup")
        XCTAssertEqual(try Data(contentsOf: backupURL), Data(markdown.utf8))

        let state = AttacheContextUIState(defaults: defaults)
        runtime.bind(to: state)
        state.deleteAllMemory()
        XCTAssertTrue(runtime.activeRecords.isEmpty)
        XCTAssertTrue(state.memoryRecords.isEmpty)
        XCTAssertEqual(state.memoryStatusMessage, "All structured memory was deleted.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertEqual(try String(contentsOf: legacyURL), AttachePersonality.defaultMemoryFileText)
        let legacyAttributes = try FileManager.default.attributesOfItem(atPath: legacyURL.path)
        XCTAssertEqual(((legacyAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o600)

        let relaunched = AttacheMemoryRuntime(
            databaseURL: databaseURL,
            legacySnapshot: AttacheMemorySnapshot(
                fileURL: legacyURL,
                rawText: try String(contentsOf: legacyURL),
                context: nil,
                errorDescription: nil
            ),
            defaults: defaults
        )
        XCTAssertTrue(relaunched.activeRecords.isEmpty)
    }

    @MainActor
    func testDeleteAllFailureKeepsPublishedRecordsAndBackupVisibleForRetry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-memory-delete-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appendingPathComponent("AttacheMemory.md")
        let markdown = "# Attaché Memory\n- Keep visible until erasure verifies\n"
        try markdown.write(to: legacyURL, atomically: true, encoding: .utf8)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "memory-delete-failure.\(UUID().uuidString)"))
        let runtime = AttacheMemoryRuntime(
            databaseURL: root.appendingPathComponent("memory.sqlite"),
            legacySnapshot: AttacheMemorySnapshot(
                fileURL: legacyURL,
                rawText: markdown,
                context: nil,
                errorDescription: nil
            ),
            defaults: defaults
        )
        let backupURL = legacyURL.appendingPathExtension("pre-structured-memory-backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        let state = AttacheContextUIState(defaults: defaults)
        runtime.bind(to: state)
        let visibleBeforeDelete = state.memoryRecords
        XCTAssertFalse(visibleBeforeDelete.isEmpty)

        // A directory at the legacy file path makes the verified atomic reset
        // fail deterministically after SQLite erasure. The UI must not pretend
        // the entire operation succeeded or hide the record from the user.
        try FileManager.default.removeItem(at: legacyURL)
        try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: false)
        state.deleteAllMemory()

        XCTAssertEqual(state.memoryRecords, visibleBeforeDelete)
        XCTAssertTrue(state.memoryStatusMessage?.contains("could not be fully deleted") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
    }
}
