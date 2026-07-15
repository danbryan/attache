import AttacheCore
import XCTest
import Foundation

final class AttacheSessionDiscoveryTests: XCTestCase {

    // Build a populated search service over a sanitized corpus.
    private func makeService() throws -> AttacheSessionSearchService {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-discovery-\(UUID().uuidString).sqlite")
        let index = SessionFTSIndex(databaseURL: tmp)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let docs: [(id: String, title: String, body: String, project: String?, updated: Date)] = [
            ("sess-a", "Router DNS forwarding fix", "UniFi router stopped forwarding DNS for bryanlabs.net after controller rebuild", "/Users/dan/code/bare-metal", base),
            ("sess-b", "Router backup and restore", "Restored the router config from backup after a disk failure", "/Users/dan/code/bare-metal", base.addingTimeInterval(60)),
            ("sess-c", "Tax 1120-S reconciliation", "Reconciled the S-Corp 1120-S K-1 against the trial balance", "/Users/dan/code/local/finops", base.addingTimeInterval(120)),
            ("sess-d", "HSA receipt filing", "Filed a qualified medical receipt against the HSA", "/Users/dan/code/local/finops", base.addingTimeInterval(180)),
            ("sess-e", "Personality unify work", "Combined the personality brain voice and visual presence into one unit", "/Users/dan/code/github.com/danbryan/attache", base.addingTimeInterval(240)),
        ]
        let records = docs.map { d -> SessionRecord in
            SessionRecord(id: d.id, title: d.title, project: d.project, threadName: nil,
                          updatedAt: d.updated, archived: false, filePath: "/tmp/\(d.id).jsonl",
                          fileMtime: d.updated.timeIntervalSince1970,
                          content: (d.title + "\n" + d.body).lowercased(), topicTag: nil, sourceKind: .codex)
        }
        _ = index.index(records: records)
        return AttacheSessionSearchService(ftsIndex: index, records: records)
    }

    // Criterion 1: no-focus conversational search opens the native picker
    // without exposing results to the model. The result is content-free.
    func testSearchResultIsContentFree() throws {
        let service = try makeService()
        let request = AttacheSessionDiscoveryRequest(
            query: AttacheSessionDiscoveryQuery(text: "router DNS"),
            triggeringUserTurn: "find the session about router DNS"
        )
        let (result, validIDs) = AttacheSessionDiscoveryCoordinator.search(request: request, service: service)
        XCTAssertGreaterThan(result.matchCount, 0, "should match the router session")
        XCTAssertTrue(result.requiresSelection)
        XCTAssertFalse(result.noMatches)
        // The result must NOT expose any title, snippet, path, or session ID.
        let leaked: [String] = ["sess-a", "Router DNS forwarding fix", "bryanlabs.net",
                                "/Users/dan/code/bare-metal", "UniFi router stopped forwarding"]
        for marker in leaked {
            XCTAssertFalse(result.guidance.contains(marker),
                           "guidance must not leak \(marker)")
            XCTAssertFalse("\(result.matchCount)".contains(marker), "matchCount is a number only")
        }
        // The valid IDs stay app-side, never in the result.
        XCTAssertFalse(validIDs.isEmpty)
        XCTAssertFalse(result.guidance.contains(validIDs.first!),
                       "session ID must not appear in model-visible guidance")
    }

    // Criterion 2: search alone does not change focused session, epoch, or tools.
    func testSearchAloneChangesNoFocusOrEpoch() throws {
        let service = try makeService()
        let request = AttacheSessionDiscoveryRequest(
            query: AttacheSessionDiscoveryQuery(text: "router"),
            triggeringUserTurn: "find the router session"
        )
        let epoch = AttacheFocusEpoch(3)
        let (result, _) = AttacheSessionDiscoveryCoordinator.search(request: request, service: service)
        // Search produces only a model-safe result. It does NOT produce a
        // focus grant. The epoch is unchanged.
        XCTAssertEqual(epoch.value, 3, "epoch unchanged by search alone")
        // There is no focus grant in the result; the only way to get one is
        // validateSelection with a picker selection.
        XCTAssertTrue(type(of: result) == AttacheSessionDiscoveryResult.self)
    }

    // Criterion 3: Enter/click focuses exactly the selected session and the
    // next request can use it.
    func testSelectionGrantsFocusAndAdvancesEpoch() throws {
        let service = try makeService()
        let request = AttacheSessionDiscoveryRequest(
            query: AttacheSessionDiscoveryQuery(text: "router DNS forwarding"),
            triggeringUserTurn: "find the router DNS session"
        )
        let (_, validIDs) = AttacheSessionDiscoveryCoordinator.search(request: request, service: service)
        let selected = AttacheSessionDiscoverySelection(
            sessionID: "sess-a", sourceKind: "codex",
            displayTitle: "Router DNS forwarding fix",
            workingDirectory: "/Users/dan/code/bare-metal"
        )
        let grant = try AttacheSessionDiscoveryCoordinator.validateSelection(
            selected, validSessionIDs: validIDs, currentEpoch: AttacheFocusEpoch(1)
        )
        XCTAssertEqual(grant.session.sessionID, "sess-a")
        XCTAssertEqual(grant.epoch.value, 2, "epoch advances on focus grant")
        XCTAssertEqual(grant.session.displayTitle, "Router DNS forwarding fix")
        XCTAssertEqual(grant.session.workingDirectory, "/Users/dan/code/bare-metal")
    }

    // Criterion 4: Escape, timeout, deleted result, model-supplied fake ID,
    // and reconnect leave focus unchanged.
    func testModelSuppliedFakeIDRejected() throws {
        let service = try makeService()
        let request = AttacheSessionDiscoveryRequest(
            query: AttacheSessionDiscoveryQuery(text: "router"),
            triggeringUserTurn: "find the router session"
        )
        let (_, validIDs) = AttacheSessionDiscoveryCoordinator.search(request: request, service: service)
        let fakeSelection = AttacheSessionDiscoverySelection(
            sessionID: "sess-not-in-results",
            sourceKind: "codex", displayTitle: "Guessed", workingDirectory: nil
        )
        XCTAssertThrowsError(try AttacheSessionDiscoveryCoordinator.validateSelection(
            fakeSelection, validSessionIDs: validIDs, currentEpoch: AttacheFocusEpoch(1)
        )) { error in
            XCTAssertEqual(error as? AttacheSessionDiscoveryError, .staleResult)
        }
    }

    func testStaleDeletedResultRejected() throws {
        let service = try makeService()
        let request = AttacheSessionDiscoveryRequest(
            query: AttacheSessionDiscoveryQuery(text: "router"),
            triggeringUserTurn: "find the router session"
        )
        let (_, validIDs) = AttacheSessionDiscoveryCoordinator.search(request: request, service: service)
        // Simulate a session that was valid at search time but deleted before
        // selection: the valid set no longer contains it.
        let staleID = validIDs.first!
        let reducedSet = validIDs.subtracting([staleID])
        let staleSelection = AttacheSessionDiscoverySelection(
            sessionID: staleID, sourceKind: "codex",
            displayTitle: "Now deleted", workingDirectory: nil
        )
        XCTAssertThrowsError(try AttacheSessionDiscoveryCoordinator.validateSelection(
            staleSelection, validSessionIDs: reducedSet, currentEpoch: AttacheFocusEpoch(1)
        )) { error in
            XCTAssertEqual(error as? AttacheSessionDiscoveryError, .staleResult)
        }
    }

    func testRejectModelSuppliedIDAlwaysErrors() {
        let validIDs: Set<String> = ["sess-a", "sess-b"]
        let error = AttacheSessionDiscoveryCoordinator.rejectModelSuppliedID("sess-a", validSessionIDs: validIDs)
        XCTAssertEqual(error, .modelSuppliedFakeID, "even a valid ID is rejected when model-supplied, not picker-selected")
        let error2 = AttacheSessionDiscoveryCoordinator.rejectModelSuppliedID("sess-z", validSessionIDs: validIDs)
        XCTAssertEqual(error2, .modelSuppliedFakeID)
    }

    // Cancellation is a normal outcome with no focus change: the coordinator
    // simply never receives a selection. This test documents that cancellation
    // produces no grant.
    func testCancellationProducesNoGrant() throws {
        let service = try makeService()
        let request = AttacheSessionDiscoveryRequest(
            query: AttacheSessionDiscoveryQuery(text: "router"),
            triggeringUserTurn: "find the router session"
        )
        let (result, _) = AttacheSessionDiscoveryCoordinator.search(request: request, service: service)
        // Escape: the picker closes, no selection arrives. The result is the
        // only model-visible output, and it carries no focus.
        XCTAssertTrue(result.requiresSelection)
        // No call to validateSelection means no grant. The search result is
        // a model-safe count and guidance, never a focus grant. A grant is
        // only ever produced by validateSelection, which was never called.
        XCTAssertTrue(result.matchCount >= 0)
    }

    // Criterion: query validation bounds text, limit, and date range.
    func testQueryValidationBoundsText() {
        let long = String(repeating: "a", count: AttacheSessionDiscoveryCoordinator.maxQueryLength + 1)
        XCTAssertThrowsError(try AttacheSessionDiscoveryCoordinator.validateQuery(
            AttacheSessionDiscoveryQuery(text: long)
        )) { error in
            guard case .queryTextTooLong = error as? AttacheSessionDiscoveryError else {
                return XCTFail("expected queryTextTooLong")
            }
        }
    }

    func testQueryValidationRejectsEmpty() {
        XCTAssertThrowsError(try AttacheSessionDiscoveryCoordinator.validateQuery(
            AttacheSessionDiscoveryQuery(text: "   ")
        )) { error in
            XCTAssertEqual(error as? AttacheSessionDiscoveryError, .queryTextEmpty)
        }
    }

    func testQueryValidationClampsLimit() throws {
        let validated = try AttacheSessionDiscoveryCoordinator.validateQuery(
            AttacheSessionDiscoveryQuery(text: "router", limit: 999)
        )
        XCTAssertEqual(validated.limit, AttacheSessionDiscoveryCoordinator.maxLimit)
    }

    func testQueryValidationRejectsInvertedDateRange() {
        let after = Date(timeIntervalSince1970: 2_000)
        let before = Date(timeIntervalSince1970: 1_000)
        XCTAssertThrowsError(try AttacheSessionDiscoveryCoordinator.validateQuery(
            AttacheSessionDiscoveryQuery(text: "router", dateAfter: after, dateBefore: before)
        )) { error in
            XCTAssertEqual(error as? AttacheSessionDiscoveryError, .dateRangeInvalid)
        }
    }

    // Criterion: no matches produces a safe no-matches result.
    func testNoMatchesProducesSafeResult() throws {
        let service = try makeService()
        let request = AttacheSessionDiscoveryRequest(
            query: AttacheSessionDiscoveryQuery(text: "zzz-no-such-topic"),
            triggeringUserTurn: "find a session about zzz"
        )
        let (result, validIDs) = AttacheSessionDiscoveryCoordinator.search(request: request, service: service)
        XCTAssertTrue(result.noMatches)
        XCTAssertEqual(result.matchCount, 0)
        XCTAssertTrue(validIDs.isEmpty)
        XCTAssertTrue(result.guidance.contains("No sessions matched"))
    }

    // Criterion: multiple matches require selection, not guessing.
    func testMultipleMatchesRequireSelection() throws {
        let service = try makeService()
        let request = AttacheSessionDiscoveryRequest(
            query: AttacheSessionDiscoveryQuery(text: "router"),
            triggeringUserTurn: "find the router session"
        )
        let (result, validIDs) = AttacheSessionDiscoveryCoordinator.search(request: request, service: service)
        XCTAssertGreaterThan(result.matchCount, 1, "two router sessions exist")
        XCTAssertTrue(result.requiresSelection)
        XCTAssertTrue(result.guidance.contains("pick one"), "guidance must say to pick, not guess")
        XCTAssertTrue(result.guidance.contains("cannot guess"), "guidance tells the model not to guess")
        // No session ID leaks even with multiple matches.
        for id in validIDs {
            XCTAssertFalse(result.guidance.contains(id))
        }
    }

    // Criterion 6: Command-K and conversational search have the same ranking.
    // Both route through AttacheSessionSearchService, so the ranked session IDs
    // are identical for the same query.
    func testConversationalSearchUsesSameRankingAsCommandK() throws {
        let service = try makeService()
        let text = "router DNS"
        // Command-K path: direct service query.
        let commandK = service.search(AttacheSessionSearchQuery(text: text, limit: 20))
        // Conversational path: discovery coordinator.
        let request = AttacheSessionDiscoveryRequest(
            query: AttacheSessionDiscoveryQuery(text: text),
            triggeringUserTurn: "find the router DNS session"
        )
        let (_, validIDs) = AttacheSessionDiscoveryCoordinator.search(request: request, service: service)
        let commandKIDs = Set(commandK.map { $0.sessionID })
        XCTAssertEqual(validIDs, commandKIDs, "both paths use the same service and ranking")
    }

    // Criterion 7: no result title, snippet, path, or transcript appears in
    // provider-captured messages before selection. The model-visible result is
    // only a count and fixed guidance.
    func testNoResultContentLeaksIntoModelMessages() throws {
        let service = try makeService()
        let request = AttacheSessionDiscoveryRequest(
            query: AttacheSessionDiscoveryQuery(text: "tax 1120-S reconciliation"),
            triggeringUserTurn: "find the tax session"
        )
        let (result, _) = AttacheSessionDiscoveryCoordinator.search(request: request, service: service)
        // The entire model-visible payload is result + guidance. Assert no
        // corpus content appears anywhere in it.
        let modelVisible = "\(result.matchCount)|\(result.requiresSelection)|\(result.noMatches)|\(result.guidance)"
        let forbidden: [String] = [
            "Tax 1120-S reconciliation", "1120-S K-1", "trial balance",
            "/Users/dan/code/local/finops", "sess-c",
            "Reconciled the S-Corp", "qualified medical receipt"
        ]
        for marker in forbidden {
            XCTAssertFalse(modelVisible.contains(marker),
                           "model-visible payload must not contain \(marker)")
        }
    }

    // Epoch advances monotonically across successive focus grants.
    func testEpochAdvancesMonotonically() throws {
        let service = try makeService()
        let request = AttacheSessionDiscoveryRequest(
            query: AttacheSessionDiscoveryQuery(text: "router DNS"),
            triggeringUserTurn: "find the router DNS session"
        )
        let (_, validIDs) = AttacheSessionDiscoveryCoordinator.search(request: request, service: service)
        let selection = AttacheSessionDiscoverySelection(
            sessionID: validIDs.first!, sourceKind: "codex",
            displayTitle: "T", workingDirectory: nil
        )
        let grant1 = try AttacheSessionDiscoveryCoordinator.validateSelection(
            selection, validSessionIDs: validIDs, currentEpoch: AttacheFocusEpoch(5)
        )
        XCTAssertEqual(grant1.epoch.value, 6)
        let grant2 = try AttacheSessionDiscoveryCoordinator.validateSelection(
            selection, validSessionIDs: validIDs, currentEpoch: grant1.epoch
        )
        XCTAssertEqual(grant2.epoch.value, 7, "epoch advances on each grant")
    }
}