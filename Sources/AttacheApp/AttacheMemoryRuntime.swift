import AttacheCore
import Foundation

/// Production bridge from the structured SQLite ledger to request compilation
/// and the user-facing memory controls. The legacy Markdown file is migration
/// input only. Once migration is verified, requests select a bounded set from
/// this ledger rather than injecting the entire file.
final class AttacheMemoryRuntime: @unchecked Sendable {
    private let ledger: AttacheMemoryLedger
    private let defaults: UserDefaults
    private let legacyFileURL: URL
    private let legacyBackupURL: URL
    private let lock = NSRecursiveLock()
    private var forgottenByID: [String: AttacheMemoryRecord] = [:]

    init(
        databaseURL: URL,
        legacySnapshot: AttacheMemorySnapshot,
        defaults: UserDefaults = .standard
    ) {
        self.ledger = AttacheMemoryLedger(databaseURL: databaseURL)
        self.defaults = defaults
        self.legacyFileURL = legacySnapshot.fileURL
        self.legacyBackupURL = legacySnapshot.fileURL
            .appendingPathExtension("pre-structured-memory-backup")
        let legacySourceIsSecure = Self.hardenLegacySource(at: legacyFileURL)
        if !ledger.isMigrated {
            // The original Markdown remains untouched. A byte-for-byte,
            // restrictive-permission backup is additionally verified before
            // the ledger can record migration success.
            if legacySourceIsSecure,
               Self.createAndVerifyLegacyBackup(legacySnapshot, at: legacyBackupURL) {
                _ = ledger.migrate(fromMarkdown: legacySnapshot.rawText)
            }
        }
        // Capture is explicit-only now; the retired suggestion review queue is
        // gone, so remove any stale queue file from the earlier contract.
        try? FileManager.default.removeItem(
            at: databaseURL.deletingLastPathComponent()
                .appendingPathComponent("memory-review-queue.json")
        )
        // Rows written before creation times were stamped carry the 1970
        // epoch, which rots recency scoring and date display. Repair once at
        // launch by mapping zero timestamps to now.
        ledger.repairEpochZeroTimestamps()
    }

    var activeRecords: [AttacheMemoryRecord] { ledger.list(activeOnly: true) }

    /// Resolve a topic scope only when the current user turn explicitly names
    /// one of the locally stored topic keys. This is lexical authority, not a
    /// model inference: unrelated or merely similar turns keep topic memory
    /// invisible. Longer matching topic phrases win; equally specific
    /// different topics fail closed as ambiguous.
    func explicitTopic(matching userTurn: String) -> String? {
        let userTokens = Self.normalizedTopicTokens(userTurn)
        guard !userTokens.isEmpty else { return nil }
        let topics = Set(ledger.list(activeOnly: true).compactMap { record -> String? in
            guard case .topic(let topic) = record.scope else { return nil }
            let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })
        let matches = topics.compactMap { topic -> (topic: String, tokens: [String])? in
            let tokens = Self.normalizedTopicTokens(topic)
            guard !tokens.isEmpty,
                  Self.containsPhrase(tokens, in: userTokens) else { return nil }
            return (topic, tokens)
        }.sorted {
            if $0.tokens.count != $1.tokens.count { return $0.tokens.count > $1.tokens.count }
            if $0.tokens.joined().count != $1.tokens.joined().count {
                return $0.tokens.joined().count > $1.tokens.joined().count
            }
            return $0.topic < $1.topic
        }
        guard let best = matches.first else { return nil }
        if matches.dropFirst().contains(where: {
            $0.tokens.count == best.tokens.count
                && $0.tokens.joined().count == best.tokens.joined().count
                && $0.tokens != best.tokens
        }) {
            return nil
        }
        return best.topic
    }

    func exportData() -> Data? { ledger.export() }

    func importData(_ data: Data) -> AttacheMemoryImportResult? {
        ledger.importRecords(from: data)
    }

    /// Selects memory before compilation. Scope, confidence, sensitivity, and
    /// remote-egress policy are filtered before text becomes a context item.
    func contextItems(
        userTurn: String,
        personalityID: String?,
        explicitTopic: String? = nil,
        recentDirectChatContext: String? = nil,
        strategy: AttacheContextStrategy,
        memoryBudgetTokens: Int,
        requestIsRemote: Bool
    ) -> (items: [AttacheContextItem], receipt: [AttacheMemoryReceiptEntry]) {
        let query = AttacheMemorySelectionQuery(
            userTurn: userTurn,
            personalityID: personalityID,
            explicitTopic: explicitTopic,
            recentDirectChatContext: recentDirectChatContext,
            strategy: strategy,
            memoryBudgetTokens: memoryBudgetTokens,
            requestIsRemote: requestIsRemote
        )
        let selection = AttacheMemorySelector.select(
            query: query,
            records: ledger.list(activeOnly: true),
            now: Date()
        )
        _ = ledger.markUsed(selection.candidates.map { $0.record.id })
        return (
            selection.candidates.map(AttacheMemorySelector.renderAsContextItem),
            selection.receipt
        )
    }

    /// Applies local policy to a proposal. Capture is explicit-only by the
    /// prompt contract: the tool is called only for an explicit ask, and the
    /// statement is trusted as the model's faithful restatement (the ChatGPT
    /// bio-tool design). The validator decides what may never be stored, and
    /// the Memory pane is the user's review backstop. Saves record as
    /// user-confirmed and authoritative: the user asked; the wording is the
    /// model's restatement.
    @discardableResult
    func processProposal(
        statement: String,
        type: AttacheMemoryType,
        scope: AttacheMemoryScope,
        sensitivity: AttacheMemorySensitivity,
        egress: AttacheMemoryEgress,
        sourceLocator: String?,
        mode: AttacheMemoryProposalMode
    ) -> AttacheMemoryProposalDisposition {
        let proposal = AttacheMemoryProposal(
            id: "memory.\(UUID().uuidString)",
            statement: statement.trimmingCharacters(in: .whitespacesAndNewlines),
            type: type,
            scope: scope,
            sourceKind: .userConfirmed,
            sourceLocator: sourceLocator,
            confidence: .authoritative,
            sensitivity: sensitivity,
            // Storage is always local; egress only decides whether the saved
            // text may later be quoted to the model the personality talks to.
            // A low-sensitivity save exists to be USED by that model (the user
            // already said the fact to it in conversation), so the requested
            // egress is honored there. Everything else is forced local-only:
            // a request can narrow, never widen beyond policy, and the native
            // per-record control in Settings can change it later.
            egress: sensitivity == .low ? egress : .localOnly,
            requiresConfirmation: false
        )
        let disposition = AttacheMemoryProposalProcessor.process(
            proposal,
            mode: mode,
            existingRecords: ledger.list(activeOnly: true)
        )
        var finalDisposition = disposition
        lock.lock()
        switch disposition {
        case .saved(let record):
            if !ledger.add(record) {
                // The ledger is the final safety boundary. Never tell the UI or
                // model that a memory was saved if that boundary rejected it or
                // persistence failed.
                let reason = AttacheMemorySecretFilter.containsFinancialAccountData(record.statement)
                    ? AttacheMemoryProposalRejection.financialAccount
                    : .secret
                finalDisposition = .rejected(reason: reason)
            }
        case .rejected, .ignored:
            break
        }
        lock.unlock()
        return finalDisposition
    }

    /// Settings-authored global memory: the user types a statement in the
    /// Memory pane and it applies to every Attaché. This is the ONLY path that
    /// creates a global record; conversation captures are always scoped to one
    /// personality and a model can never create or widen to global. The same
    /// validator, secret filter, and duplicate check as conversation captures
    /// apply.
    func addGlobalMemory(statement: String) -> AttacheMemoryRecord? {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1_000 else { return nil }
        let now = Date()
        let proposal = AttacheMemoryProposal(
            id: "memory.\(UUID().uuidString)",
            statement: trimmed,
            type: .userFact,
            scope: .global,
            sourceKind: .userConfirmed,
            sourceLocator: "settings:memory-pane",
            confidence: .authoritative,
            sensitivity: .low,
            egress: .allowedRemote,
            requiresConfirmation: false
        )
        guard AttacheMemoryProposalValidator.validate(proposal) == nil,
              !AttacheMemoryProposalProcessor.isDuplicate(
                  proposal,
                  existing: ledger.list(activeOnly: true)
              ) else {
            return nil
        }
        let record = AttacheMemoryRecord(
            id: proposal.id,
            statement: proposal.statement,
            type: proposal.type,
            scope: proposal.scope,
            sourceKind: proposal.sourceKind,
            sourceLocator: proposal.sourceLocator,
            confidence: proposal.confidence,
            sensitivity: proposal.sensitivity,
            egress: proposal.egress,
            createdAt: now,
            updatedAt: now
        )
        guard ledger.add(record) else { return nil }
        return record
    }

    @MainActor
    func bind(to state: AttacheContextUIState) {
        state.onMemoryModeChange = { [weak self] _ in self?.publish(to: state) }
        state.onAddGlobalMemory = { [weak self] statement in
            guard let self, let record = self.addGlobalMemory(statement: statement) else {
                return nil
            }
            self.publish(to: state)
            return record
        }
        state.onEditMemory = { [weak self] record, statement in
            guard let self else { return nil }
            let replaced = self.replace(record: record, statement: statement)
            self.publish(to: state)
            return replaced
        }
        state.onSetMemoryEgress = { [weak self] record, egress in
            guard let self else { return nil }
            let replaced = self.replace(
                record: record,
                statement: record.statement,
                egress: egress
            )
            self.publish(to: state)
            return replaced
        }
        state.onForgetMemory = { [weak self] record in
            guard let self, self.forget(record) else { return false }
            self.publish(to: state)
            return true
        }
        state.onUndoForgetMemory = { [weak self] record in
            guard let self, self.restore(record) else { return false }
            self.publish(to: state)
            return true
        }
        state.onDeleteAllMemory = { [weak self] in
            guard let self, self.deleteAll() else { return false }
            self.publish(to: state)
            return true
        }
        publish(to: state)
    }

    @MainActor
    func publish(to state: AttacheContextUIState, status: String? = nil) {
        state.publishMemorySnapshot(
            records: ledger.list(activeOnly: true),
            status: status
        )
    }

    private static func normalizedTopicTokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func containsPhrase(_ phrase: [String], in tokens: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= tokens.count else { return false }
        for start in 0...(tokens.count - phrase.count) {
            if Array(tokens[start..<(start + phrase.count)]) == phrase { return true }
        }
        return false
    }

    @discardableResult
    private func replace(
        record: AttacheMemoryRecord,
        statement: String,
        egress: AttacheMemoryEgress? = nil
    ) -> AttacheMemoryRecord? {
        let replacement = AttacheMemoryRecord(
            id: "memory.\(UUID().uuidString)",
            statement: statement,
            type: record.type,
            scope: record.scope,
            sourceKind: .userConfirmed,
            sourceLocator: record.sourceLocator,
            confidence: .authoritative,
            sensitivity: record.sensitivity,
            egress: egress ?? record.egress,
            createdAt: record.createdAt,
            updatedAt: Date(),
            lastUsedAt: record.lastUsedAt,
            status: .active,
            supersededByID: nil
        )
        guard ledger.supersede(oldID: record.id, with: replacement) else { return nil }
        return replacement
    }

    @discardableResult
    private func forget(_ record: AttacheMemoryRecord) -> Bool {
        guard ledger.forget(record.id) else { return false }
        lock.lock()
        forgottenByID[record.id] = record
        lock.unlock()
        return true
    }

    @discardableResult
    private func restore(_ record: AttacheMemoryRecord) -> Bool {
        guard ledger.restore(record.id) else { return false }
        lock.lock()
        forgottenByID.removeValue(forKey: record.id)
        lock.unlock()
        return true
    }

    @discardableResult
    private func deleteAll() -> Bool {
        guard ledger.deleteAll(),
              clearLegacyArtifacts(),
              ledger.list(activeOnly: false).isEmpty,
              ledger.isMigrated else {
            return false
        }
        lock.lock()
        forgottenByID.removeAll()
        lock.unlock()
        return true
    }

    private static func createAndVerifyLegacyBackup(
        _ snapshot: AttacheMemorySnapshot,
        at backupURL: URL
    ) -> Bool {
        guard snapshot.errorDescription == nil else { return false }
        let expected = Data(snapshot.rawText.utf8)
        guard let source = try? Data(contentsOf: snapshot.fileURL), source == expected else {
            return false
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: backupURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fm.fileExists(atPath: backupURL.path) {
                guard try Data(contentsOf: backupURL) == expected else { return false }
            } else {
                try expected.write(to: backupURL, options: .atomic)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
            return try Data(contentsOf: backupURL) == expected
        } catch {
            return false
        }
    }

    private static func hardenLegacySource(at fileURL: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return false }
        do {
            if try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                return false
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            let attributes = try fm.attributesOfItem(atPath: fileURL.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            return permissions & 0o777 == 0o600
        } catch {
            return false
        }
    }

    /// Reset and verify every legacy artifact before Delete All may report
    /// success. A failure keeps the UI snapshot intact so the user can retry
    /// instead of receiving a false erasure confirmation.
    private func clearLegacyArtifacts() -> Bool {
        let fm = FileManager.default
        let expected = Data(AttachePersonality.defaultMemoryFileText.utf8)
        do {
            if fm.fileExists(atPath: legacyFileURL.path),
               try legacyFileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                return false
            }
            try fm.createDirectory(
                at: legacyFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try expected.write(to: legacyFileURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacyFileURL.path)
            let attributes = try fm.attributesOfItem(atPath: legacyFileURL.path)
            guard try Data(contentsOf: legacyFileURL) == expected,
                  let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
                  permissions & 0o777 == 0o600 else {
                return false
            }
            if fm.fileExists(atPath: legacyBackupURL.path) {
                try fm.removeItem(at: legacyBackupURL)
            }
            return !fm.fileExists(atPath: legacyBackupURL.path)
        } catch {
            return false
        }
    }
}
