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

    /// Capture is explicit-only: a statement the user did not say this turn is
    /// rejected outright. There is no suggestion queue to fall back to.
    func testModelOnlyStatementCannotAuthorizeAWrite() throws {
        let (runtime, root, _) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }

        let disposition = runtime.processProposal(
            statement: "The user prefers concise answers.",
            type: .preference,
            scope: .global,
            sensitivity: .low,
            egress: .allowedRemote,
            sourceLocator: "call-1:turn-2",
            explicitlyUserRequested: false,
            mode: .on
        )

        XCTAssertEqual(disposition, .rejected(reason: .notExplicitlyRequested))
        XCTAssertTrue(runtime.activeRecords.isEmpty)
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

    func testExplicitMemorySavesImmediatelyAndStaysLocalOnly() throws {
        let (runtime, root, _) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }

        let disposition = runtime.processProposal(
            statement: "I prefer concise answers.",
            type: .preference,
            scope: .global,
            sensitivity: .low,
            egress: .allowedRemote,
            sourceLocator: "call-1:turn-1",
            explicitlyUserRequested: true,
            mode: .on
        )

        guard case .saved = disposition else {
            return XCTFail("Expected the explicit memory to save immediately")
        }
        XCTAssertEqual(runtime.activeRecords.map(\.statement), ["I prefer concise answers."])
        XCTAssertEqual(runtime.activeRecords.first?.egress, .localOnly)
    }

    func testLocalOnlyMemoryNeverEntersRemoteRequest() throws {
        let (runtime, root, _) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = runtime.processProposal(
            statement: "My private nickname is Blue.", type: .userFact, scope: .global,
            sensitivity: .low, egress: .localOnly, sourceLocator: "call-1:turn-1",
            explicitlyUserRequested: true, mode: .on
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
            explicitlyUserRequested: true, mode: .on
        )
        _ = runtime.processProposal(
            statement: "I enjoy hiking on weekends.", type: .preference, scope: .global,
            sensitivity: .low, egress: .localOnly, sourceLocator: "call-1:turn-2",
            explicitlyUserRequested: true, mode: .on
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
            sourceLocator: "call-1:turn-1", explicitlyUserRequested: true,
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
    }

    func testTopicScopedMemoryRequiresExactTopic() throws {
        let (runtime, root, _) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = runtime.processProposal(
            statement: "Use the cash method for tax planning.", type: .projectTopic,
            scope: .topic("tax"), sensitivity: .low, egress: .allowedRemote,
            sourceLocator: "call-1:turn-1", explicitlyUserRequested: true, mode: .on
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
            sourceLocator: "call-1:turn-1", explicitlyUserRequested: true, mode: .on
        )
        _ = runtime.processProposal(
            statement: "Keep the packing list short.", type: .projectTopic,
            scope: .topic("travel"), sensitivity: .low, egress: .allowedRemote,
            sourceLocator: "call-1:turn-2", explicitlyUserRequested: true, mode: .on
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
        let arguments = #"{"statement":"I prefer concise answers.","type":"preference","scope":"personality","sensitivity":"low","egress":"allowedRemote"}"#
        let decoded = try XCTUnwrap(AppModel.memoryProposalArguments(
            fromToolArguments: arguments,
            personalityID: "personality-colt"
        ))

        XCTAssertEqual(decoded.statement, "I prefer concise answers.")
        XCTAssertEqual(decoded.type, .preference)
        XCTAssertEqual(decoded.scope, .personality("personality-colt"))
        XCTAssertEqual(decoded.egress, .allowedRemote)
    }

    func testTopicMemoryRequiresBoundedScopeValue() {
        let arguments = #"{"statement":"Use the cash method.","type":"projectTopic","scope":"topic","sensitivity":"low","egress":"localOnly"}"#
        XCTAssertNil(AppModel.memoryProposalArguments(
            fromToolArguments: arguments,
            personalityID: "p1"
        ))
    }

    func testExplicitAskSupportRejectsModelOnlyAdditions() {
        XCTAssertTrue(AppModel.memoryStatement(
            "I prefer concise answers.",
            isSupportedBy: "I prefer concise answers."
        ))
        XCTAssertFalse(AppModel.memoryStatement(
            "I prefer concise answers and live in Baltimore.",
            isSupportedBy: "I prefer concise answers."
        ))
        XCTAssertFalse(AppModel.memoryStatement(
            "I like cats.",
            isSupportedBy: "I do not like cats."
        ))
        XCTAssertTrue(AppModel.memoryStatement(
            "I prefer concise answers.",
            isSupportedBy: "Please remember that I prefer concise answers."
        ))
    }

    /// Regression for Dan's 2026-07-19 session: the assistant offered to
    /// remember, Dan affirmed, and the guard rejected because the fact lived
    /// two turns earlier and the final restatement led with "That". Support is
    /// now explicit-in-context: contiguous containment inside a clause of any
    /// recent user turn of the active conversation.
    func testDanSessionAffirmationAndFillerFramingAreSupported() {
        let turns = [
            "Yeah, my name's Dan",
            "Yes, I want you to"
        ]
        // The fact was stated two turns before the affirmation; the window,
        // with the statement in the words Dan used, supports it.
        XCTAssertTrue(AppModel.memoryStatement(
            "my name's Dan",
            isSupportedByAny: turns
        ))
        // Leading filler "That" no longer breaks the match.
        XCTAssertTrue(AppModel.memoryStatement(
            "my name is Dan",
            isSupportedBy: "the one we were just talking about. That my name is Dan."
        ))
        // Negation still rejects: "not" breaks contiguity.
        XCTAssertFalse(AppModel.memoryStatement(
            "my name is Dan",
            isSupportedBy: "my name is not Dan"
        ))
        XCTAssertFalse(AppModel.memoryStatement(
            "my name is Dan",
            isSupportedByAny: ["my name is not Dan"]
        ))
        // A fact the user never said anywhere in the conversation rejects.
        XCTAssertFalse(AppModel.memoryStatement(
            "Dan lives in Baltimore",
            isSupportedByAny: turns
        ))
        // Containment never crosses clause boundaries.
        XCTAssertFalse(AppModel.memoryStatement(
            "my name is Dan",
            isSupportedBy: "my name is. Dan asked about that."
        ))
    }

    /// The support window is the current utterance plus the last 10 user turns
    /// of the active conversation; assistant turns never count as support.
    func testMemorySupportWindowCapsUserTurnsAndExcludesAssistantTurns() {
        var turns: [ConversationTurn] = (0..<12).map { index in
            ConversationTurn(
                id: "user-\(index)",
                role: .user,
                text: "user turn number \(index)",
                createdAt: Date()
            )
        }
        turns.append(ConversationTurn(
            id: "assistant-1",
            role: .assistant,
            text: "assistant turn that must not count",
            createdAt: Date()
        ))

        let window = AppModel.memorySupportWindow(
            currentUtterance: "yes, save it",
            turns: turns
        )

        XCTAssertEqual(window.first, "yes, save it")
        XCTAssertEqual(window.count, 11, "current utterance plus the last 10 user turns")
        XCTAssertFalse(window.contains("user turn number 0"))
        XCTAssertFalse(window.contains("user turn number 1"))
        XCTAssertTrue(window.contains("user turn number 11"))
        XCTAssertFalse(window.contains("assistant turn that must not count"))
    }

    func testToolProposalCannotGrantItsOwnRemoteMemoryEgress() {
        XCTAssertEqual(
            AppModel.memoryEgressForToolProposal(.allowedRemote),
            .localOnly
        )
        XCTAssertEqual(
            AppModel.memoryEgressForToolProposal(.localOnly),
            .localOnly
        )
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
            sourceLocator: "call-1:turn-1", explicitlyUserRequested: true,
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
            explicitlyUserRequested: true,
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
