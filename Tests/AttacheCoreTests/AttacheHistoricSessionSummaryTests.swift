import AttacheCore
import XCTest
import Foundation

/// INF-370: "Summarize any historic session into a voicemail card". These
/// tests exercise the pure, I/O-free authorization and language rules that
/// back the feature: fail-closed authorization (no grant -> no read) and the
/// incompleteness-honesty contract (a partial review must say so).
final class AttacheHistoricSessionSummaryTests: XCTestCase {

    private func session(
        id: String = "sess-1",
        source: String = "claude_code",
        epoch: AttacheFocusEpoch = AttacheFocusEpoch(1)
    ) -> AttacheFocusedSession {
        AttacheFocusedSession(
            sessionID: id, sourceKind: source, displayTitle: "Fixture session",
            workingDirectory: "/tmp/fixture", authorizationEpoch: epoch
        )
    }

    // MARK: Fail-closed authorization

    func testNoFocusGrantFailsClosed() {
        let result = AttacheHistoricSessionSummaryAuthorizer.authorize(
            requestedSessionID: "sess-1", requestedSourceKind: "claude_code", grant: nil
        )
        switch result {
        case .success: XCTFail("must not authorize with no grant")
        case .failure(let error): XCTAssertEqual(error, .noFocusGrant)
        }
    }

    func testMismatchedSessionIDFailsClosed() {
        let grant = AttacheFocusGrant(session: session(id: "sess-other"), epoch: AttacheFocusEpoch(1))
        let result = AttacheHistoricSessionSummaryAuthorizer.authorize(
            requestedSessionID: "sess-1", requestedSourceKind: "claude_code", grant: grant
        )
        switch result {
        case .success: XCTFail("must not authorize a mismatched session id")
        case .failure(let error): XCTAssertEqual(error, .sessionMismatch)
        }
    }

    func testMismatchedSourceKindFailsClosed() {
        let grant = AttacheFocusGrant(session: session(source: "codex"), epoch: AttacheFocusEpoch(1))
        let result = AttacheHistoricSessionSummaryAuthorizer.authorize(
            requestedSessionID: "sess-1", requestedSourceKind: "claude_code", grant: grant
        )
        switch result {
        case .success: XCTFail("must not authorize a mismatched source kind")
        case .failure(let error): XCTAssertEqual(error, .sessionMismatch)
        }
    }

    func testStaleEpochFailsClosed() {
        // The grant's own session epoch no longer matches the grant's epoch
        // (a later grant superseded it); this must fail closed too.
        let grant = AttacheFocusGrant(session: session(epoch: AttacheFocusEpoch(1)), epoch: AttacheFocusEpoch(2))
        let result = AttacheHistoricSessionSummaryAuthorizer.authorize(
            requestedSessionID: "sess-1", requestedSourceKind: "claude_code", grant: grant
        )
        switch result {
        case .success: XCTFail("must not authorize a stale epoch")
        case .failure(let error): XCTAssertEqual(error, .sessionMismatch)
        }
    }

    func testMatchingGrantAuthorizes() {
        let grant = AttacheFocusGrant(session: session(), epoch: AttacheFocusEpoch(1))
        let result = AttacheHistoricSessionSummaryAuthorizer.authorize(
            requestedSessionID: "sess-1", requestedSourceKind: "claude_code", grant: grant
        )
        switch result {
        case .success(let authorized): XCTAssertEqual(authorized.sessionID, "sess-1")
        case .failure: XCTFail("a matching grant must authorize")
        }
    }

    // MARK: Incompleteness honesty (INF-329's complete/incomplete contract)

    func testCompleteCoverageProducesNoNotice() {
        XCTAssertNil(AttacheSessionSummaryLanguage.incompletenessNotice(status: .complete, coveragePercentage: 1.0))
    }

    func testCanceledCoverageNamesCancellation() {
        let notice = AttacheSessionSummaryLanguage.incompletenessNotice(status: .canceled, coveragePercentage: 0.4)
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice!.lowercased().contains("canceled"))
        XCTAssertTrue(notice!.contains("40 percent"))
    }

    func testStaleCoverageNamesSourceChange() {
        let notice = AttacheSessionSummaryLanguage.incompletenessNotice(status: .stale, coveragePercentage: 0.6)
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice!.lowercased().contains("stale") || notice!.lowercased().contains("changed"))
    }

    func testIncompleteCoverageNamesPercentage() {
        let notice = AttacheSessionSummaryLanguage.incompletenessNotice(status: .incomplete, coveragePercentage: 0.75)
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice!.contains("75 percent"))
    }

    func testAssembledSourceTextNeverDropsIncompletenessNotice() {
        let text = AttacheSessionSummaryLanguage.assembleSourceText(
            stageSummaries: ["Stage one found X.", "Stage two found Y."],
            status: .canceled,
            coveragePercentage: 0.5
        )
        XCTAssertTrue(text.contains("Stage one found X."))
        XCTAssertTrue(text.contains("Stage two found Y."))
        XCTAssertTrue(text.lowercased().contains("canceled"))
    }

    func testAssembledSourceTextForCompleteReviewHasNoNotice() {
        let text = AttacheSessionSummaryLanguage.assembleSourceText(
            stageSummaries: ["Stage one found X."],
            status: .complete,
            coveragePercentage: 1.0
        )
        XCTAssertEqual(text, "Stage one found X.")
    }

    // MARK: Synthesis prompt construction (Core, no model call)

    func testSynthesisPromptCarriesIncompletenessLanguageIntoTheModelInput() {
        let sourceText = AttacheSessionSummaryLanguage.assembleSourceText(
            stageSummaries: ["Fixed the DNS forwarding bug."],
            status: .incomplete,
            coveragePercentage: 0.5
        )
        let prompt = AttachePersonality.sessionSummarySynthesisPrompt(
            sourceText: sourceText,
            sessionTitle: "Router DNS fix",
            sourceKindDisplayName: "Claude Code",
            memoryContext: nil
        )
        let userMessage = prompt.messages.last { $0.role == "user" }
        XCTAssertNotNil(userMessage)
        XCTAssertTrue(userMessage!.content.contains("50 percent"))
        XCTAssertTrue(userMessage!.content.contains("Router DNS fix"))
    }
}
