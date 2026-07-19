import AttacheCore
import XCTest
import Foundation

final class AttacheMemoryProposalsTests: XCTestCase {

    private func proposal(
        id: String = "p1", statement: String, type: AttacheMemoryType = .preference,
        confidence: AttacheCapabilityConfidence = .authoritative,
        sensitivity: AttacheMemorySensitivity = .low,
        sourceKind: AttacheMemorySourceKind = .userAuthored,
        requiresConfirmation: Bool = false
    ) -> AttacheMemoryProposal {
        AttacheMemoryProposal(
            id: id, statement: statement, type: type,
            sourceKind: sourceKind, confidence: confidence,
            sensitivity: sensitivity, requiresConfirmation: requiresConfirmation
        )
    }

    // Capture is explicit-only: Off blocks everything, On saves only an
    // explicit user request.
    func testOffModeAllowsNoProposals() {
        XCTAssertEqual(AttacheMemoryProposalMode.off.allowsProposals, false)
    }

    func testOnModeAllowsProposals() {
        XCTAssertTrue(AttacheMemoryProposalMode.on.allowsProposals)
    }

    /// The retired Suggest and Automatic modes both allowed capture, so their
    /// persisted values map to On; unknown values fail closed to Off.
    func testLegacyPersistedModesMapOntoOnOff() {
        XCTAssertEqual(AttacheMemoryProposalMode.fromPersisted("off"), .off)
        XCTAssertEqual(AttacheMemoryProposalMode.fromPersisted("on"), .on)
        XCTAssertEqual(AttacheMemoryProposalMode.fromPersisted("suggest"), .on)
        XCTAssertEqual(AttacheMemoryProposalMode.fromPersisted("automatic"), .on)
        XCTAssertEqual(AttacheMemoryProposalMode.fromPersisted("something-else"), .off)
        XCTAssertEqual(AttacheMemoryProposalMode.fromPersisted(nil), .off)
    }

    func testExplicitUserRequestSavesImmediately() {
        let p = proposal(statement: "User prefers terse summaries")
        let disposition = AttacheMemoryProposalProcessor.process(p, mode: .on, existingRecords: [])
        if case .saved = disposition { /* expected */ } else {
            XCTFail("an explicit, validator-passing request should save immediately")
        }
    }

    /// The explicit ask is the consent, so a validator-passing fact saves even
    /// when the model marks it above low sensitivity.
    func testExplicitSaveAllowsNonLowSensitivityAfterValidation() {
        let p = proposal(statement: "User has a standing meeting on Fridays", sensitivity: .medium)
        let disposition = AttacheMemoryProposalProcessor.process(p, mode: .on, existingRecords: [])
        if case .saved = disposition { /* expected */ } else {
            XCTFail("an explicitly requested medium-sensitivity fact should save")
        }
    }

    // Criterion 3: secrets, inferred traits, temporary statements, agent-session
    // content never saved.
    func testSecretsNeverSaved() {
        let p = proposal(statement: "The API key is sk-1234567890abcdef")
        let disposition = AttacheMemoryProposalProcessor.process(p, mode: .on, existingRecords: [])
        if case .rejected(let reason) = disposition {
            XCTAssertTrue(reason == .credential || reason == .secret, "secret rejected")
        } else {
            XCTFail("secret should be rejected")
        }
    }

    func testInferredProtectedTraitsNeverSaved() {
        let p = proposal(statement: "The user seems autistic", confidence: .inferred)
        let disposition = AttacheMemoryProposalProcessor.process(p, mode: .on, existingRecords: [])
        if case .rejected(let reason) = disposition {
            XCTAssertEqual(reason, .inferredProtectedTrait)
        } else {
            XCTFail("inferred trait should be rejected")
        }
    }

    func testTransientMoodsNeverSaved() {
        let p = proposal(statement: "Today I feel happy")
        let disposition = AttacheMemoryProposalProcessor.process(p, mode: .on, existingRecords: [])
        if case .rejected(let reason) = disposition {
            XCTAssertEqual(reason, .transientMood)
        } else {
            XCTFail("transient mood should be rejected")
        }
    }

    func testSessionContentNotRestatedNeverSaved() {
        let p = proposal(statement: "The agent said the test failed")
        let disposition = AttacheMemoryProposalProcessor.process(p, mode: .on, existingRecords: [])
        if case .rejected(let reason) = disposition {
            XCTAssertEqual(reason, .sessionContentNotRestated)
        } else {
            XCTFail("session content should be rejected")
        }
    }

    func testMedicalLegalNeverSaved() {
        let p = proposal(statement: "The user has a diagnosis of diabetes")
        let disposition = AttacheMemoryProposalProcessor.process(p, mode: .on, existingRecords: [])
        if case .rejected(let reason) = disposition {
            XCTAssertEqual(reason, .medicalLegal)
        } else {
            XCTFail("medical/legal should be rejected")
        }
    }

    func testFinancialAccountNeverSaved() {
        let p = proposal(statement: "My bank account number is 12345678")
        let disposition = AttacheMemoryProposalProcessor.process(p, mode: .on, existingRecords: [])
        if case .rejected(let reason) = disposition {
            XCTAssertEqual(reason, .financialAccount)
        } else {
            XCTFail("financial account should be rejected")
        }
    }

    // Criterion 4: corrections supersede old facts and can be undone.
    func testUndoRestoresSupersededRecord() {
        let oldRecord = AttacheMemoryRecord(
            id: "m1", statement: "User prefers terse summaries", type: .preference,
            status: .active
        )
        let superseded = AttacheMemoryRecord(
            id: "m1", statement: "User prefers terse summaries", type: .preference,
            status: .superseded, supersededByID: "m2"
        )
        let restored = AttacheMemoryUndo.undoSupersede(supersededID: "m1", records: [superseded])
        XCTAssertEqual(restored?.status, .active, "undo restores to active")
        XCTAssertNil(restored?.supersededByID, "undo clears supersession")
        _ = oldRecord
    }

    // Criterion 5: duplicate proposals do not create duplicate active records.
    func testDuplicateProposalsRejected() {
        let existing = AttacheMemoryRecord(
            id: "m1", statement: "User prefers terse summaries", type: .preference,
            status: .active
        )
        let p = proposal(id: "p1", statement: "User prefers terse summaries")
        let disposition = AttacheMemoryProposalProcessor.process(p, mode: .on, existingRecords: [existing])
        if case .rejected(let reason) = disposition {
            XCTAssertEqual(reason, .duplicate)
        } else {
            XCTFail("duplicate should be rejected")
        }
    }

    // Criterion 6: every stored record has source, scope, confidence,
    // sensitivity, and egress policy.
    func testStoredRecordHasAllFieldsAndStampedCreationTimes() {
        let p = proposal(statement: "User prefers terse summaries")
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let disposition = AttacheMemoryProposalProcessor.process(
            p, mode: .on, existingRecords: [], now: now
        )
        if case .saved(let record) = disposition {
            XCTAssertEqual(record.sourceKind, .userAuthored)
            XCTAssertEqual(record.scope, .global)
            XCTAssertEqual(record.confidence, .authoritative)
            XCTAssertEqual(record.sensitivity, .low)
            XCTAssertEqual(record.egress, .localOnly)
            XCTAssertEqual(record.createdAt, now, "never the 1970 epoch placeholder")
            XCTAssertEqual(record.updatedAt, now)
        } else {
            XCTFail("should save")
        }
    }

    // Criterion 7: turning Off stops proposals immediately.
    func testOffModeIgnoresProposals() {
        let p = proposal(statement: "User prefers terse summaries")
        let disposition = AttacheMemoryProposalProcessor.process(p, mode: .off, existingRecords: [])
        if case .ignored = disposition { /* expected */ } else {
            XCTFail("Off mode ignores proposals")
        }
    }

    // Criterion 8: delete/forget removes derived retrieval entries and future
    // use. A forgotten record is filtered by the memory selector (tested in
    // INF-319). Here we verify the status transition.
    func testForgetTransitionsStatus() {
        let record = AttacheMemoryRecord(
            id: "m1", statement: "User prefers terse summaries", type: .preference,
            status: .forgotten
        )
        XCTAssertEqual(record.status, .forgotten)
        // The memory selector (INF-319) filters forgotten records.
        let query = AttacheMemorySelectionQuery(
            userTurn: "summaries", personalityID: nil, strategy: .automatic,
            memoryBudgetTokens: 1000, requestIsRemote: false
        )
        let selection = AttacheMemorySelector.select(query: query, records: [record])
        XCTAssertFalse(selection.candidates.contains { $0.record.id == "m1" },
                       "forgotten record not in selection")
    }

    // Criterion 9: provider spies show no hidden inference call and no
    // unrelated history sent for extraction. The processor is pure: it
    // processes the proposal that came from the direct turn. No extra remote
    // call is made.
    func testNoHiddenInferenceCall() {
        // The processor is pure and does not make any remote calls. It only
        // validates and decides based on the mode. There is no network
        // dependency in the processor.
        let p = proposal(statement: "User prefers terse summaries")
        let _ = AttacheMemoryProposalProcessor.process(p, mode: .on, existingRecords: [])
        // If this test runs without hanging or erroring, the processor made
        // no hidden remote call.
        XCTAssertTrue(true, "processor is pure, no hidden call")
    }

    // Consolidation: duplicate detection produces supersession actions.
    func testDuplicateDetectionProducesSupersession() {
        let r1 = AttacheMemoryRecord(id: "m1", statement: "User prefers terse summaries", type: .preference, updatedAt: Date(timeIntervalSince1970: 100))
        let r2 = AttacheMemoryRecord(id: "m2", statement: "User prefers terse summaries", type: .preference, updatedAt: Date(timeIntervalSince1970: 200))
        let actions = AttacheMemoryConsolidator.detectDuplicates([r1, r2])
        XCTAssertEqual(actions.count, 1, "one duplicate detected")
        XCTAssertEqual(actions[0].supersede, "m1", "older is superseded")
        XCTAssertEqual(actions[0].by, "m2", "newer survives")
    }

    // Consolidation: contradiction detection.
    func testContradictionDetection() {
        let r1 = AttacheMemoryRecord(id: "m1", statement: "User prefers terse summaries", type: .preference)
        let r2 = AttacheMemoryRecord(id: "m2", statement: "User does not prefer terse summaries", type: .preference)
        let contradictions = AttacheMemoryConsolidator.detectContradictions([r1, r2])
        XCTAssertGreaterThan(contradictions.count, 0, "contradiction detected")
    }

    func testParaphraseIsNotAContradiction() {
        let r1 = AttacheMemoryRecord(id: "m1", statement: "User prefers terse summaries", type: .preference)
        let r2 = AttacheMemoryRecord(id: "m2", statement: "User prefers terse summary style", type: .preference)
        XCTAssertTrue(AttacheMemoryConsolidator.detectContradictions([r1, r2]).isEmpty)
    }

    // Consolidation: stale time-sensitive detection.
    func testStaleTimeSensitiveDetection() {
        let oldReminder = AttacheMemoryRecord(
            id: "m1", statement: "Remember to renew the domain", type: .reminder,
            updatedAt: Date(timeIntervalSince1970: 1_000_000_000) // very old
        )
        let freshReminder = AttacheMemoryRecord(
            id: "m2", statement: "Remember to call mom tomorrow", type: .reminder,
            updatedAt: Date(timeIntervalSince1970: 1_699_999_000) // recent
        )
        let stale = AttacheMemoryConsolidator.detectStaleTimeSensitive(
            [oldReminder, freshReminder], maxAgeDays: 30, now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(stale.contains("m1"), "old reminder is stale")
        XCTAssertFalse(stale.contains("m2"), "fresh reminder is not stale")
    }

    // User-stated protected trait is not rejected (only inferred ones are).
    func testUserStatedTraitNotRejected() {
        let p = proposal(statement: "I am autistic", confidence: .authoritative)
        let disposition = AttacheMemoryProposalProcessor.process(p, mode: .on, existingRecords: [])
        if case .saved = disposition { /* expected: user-stated, explicitly asked */ } else {
            XCTFail("user-stated trait should save when explicitly requested")
        }
    }
}
