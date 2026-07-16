import AttacheCore
@testable import AttacheApp
import XCTest

final class ModelCallSafetyTests: XCTestCase {
    func testAnotherTakeAuthorizationBindsExactCardContent() {
        let card = makeCard(id: "card-1", sessionID: "session-a", rawText: "private result")
        let authorization = AnotherTakeRequestAuthorization.explicit(card: card)

        XCTAssertTrue(authorization.authorizes(card))

        var changed = card
        changed.rawText = "different session content"
        XCTAssertFalse(authorization.authorizes(changed))
    }

    func testLiveAnotherTakeAuthorizationRequiresFrozenSession() {
        let card = makeCard(id: "card-1", sessionID: "session-b", rawText: "B result")
        let authorization = AnotherTakeRequestAuthorization.live(
            card: card,
            callID: UUID(),
            focusedSessionID: "session-a"
        )

        XCTAssertFalse(authorization.authorizes(card))
    }

    func testEffectLedgerClaimsEachEffectOnlyOnce() {
        let ledger = ConversationTurnEffectLedger()

        XCTAssertTrue(ledger.claim(.renameSession))
        XCTAssertFalse(ledger.claim(.renameSession))
        XCTAssertTrue(ledger.claim(.agentInstruction))
        XCTAssertFalse(ledger.claim(.agentInstruction))
        XCTAssertTrue(ledger.claim(.memoryProposal))
        XCTAssertFalse(ledger.claim(.memoryProposal))
        XCTAssertTrue(ledger.claim(.sessionDiscovery))
        XCTAssertFalse(ledger.claim(.sessionDiscovery))
        XCTAssertTrue(ledger.hasEffects)
    }

    func testConsentScopeNormalizesEquivalentEndpoints() {
        let first = PresentationConsentScope(
            provider: .custom,
            endpoint: "HTTPS://Example.COM:443/v1/"
        )
        let equivalent = PresentationConsentScope(
            provider: .custom,
            endpoint: "https://example.com/v1"
        )

        XCTAssertEqual(first.normalizedEndpoint, "https://example.com/v1")
        XCTAssertEqual(first, equivalent)
        XCTAssertEqual(first.storageKey, equivalent.storageKey)
    }

    func testConsentScopeChangesWithEndpointOrEgressClass() {
        let remoteA = PresentationConsentScope(provider: .custom, endpoint: "https://a.example/v1")
        let remoteB = PresentationConsentScope(provider: .custom, endpoint: "https://b.example/v1")
        let local = PresentationConsentScope(provider: .custom, endpoint: "http://127.0.0.1:8080/v1")

        XCTAssertNotEqual(remoteA.storageKey, remoteB.storageKey)
        XCTAssertNotEqual(remoteA.storageKey, local.storageKey)
        XCTAssertEqual(remoteA.egress, .unknownCustom)
        XCTAssertEqual(local.egress, .loopback)
    }

    func testContextAndAuthenticationFailuresAreNeverFallbackEligible() {
        let context = AttachePresentationError.httpStatus(
            503,
            "maximum context length exceeded"
        )
        let auth = AttachePresentationError.httpStatus(401, "")

        XCTAssertEqual(AppModel.fallbackFailureCategory(for: context), .contextLimitOverflow)
        XCTAssertEqual(AppModel.fallbackFailureCategory(for: auth), .authenticationFailure)
        XCTAssertFalse(
            AttacheFallbackRecompiler.shouldFallback(
                for: AppModel.fallbackFailureCategory(for: context)
            ).shouldFallback
        )
        XCTAssertFalse(
            AttacheFallbackRecompiler.shouldFallback(
                for: AppModel.fallbackFailureCategory(for: auth)
            ).shouldFallback
        )
    }

    func testGenericServerFailureRemainsFallbackEligible() {
        let error = AttachePresentationError.httpStatus(500, "temporary upstream failure")
        let category = AppModel.fallbackFailureCategory(for: error)

        XCTAssertEqual(category, .transientTransport)
        XCTAssertTrue(AttacheFallbackRecompiler.shouldFallback(for: category).shouldFallback)
    }

    func testTypedCompilerOverflowsAreNeverFallbackEligible() {
        let direct = AttacheContextCompilerError.preEgressOverflow(
            userDraft: "preserve me",
            requestedTokens: 9_000,
            hardLimit: 8_000
        )
        let planned = AttacheContextCompilerError.budgetPlanningFailure(
            .protectedContentOverflow(
                userDraft: "preserve me",
                requestedTokens: 9_000,
                hardLimit: 8_000
            )
        )

        for error in [direct, planned] {
            let category = AppModel.fallbackFailureCategory(for: error)
            XCTAssertEqual(category, .contextLimitOverflow)
            XCTAssertFalse(AttacheFallbackRecompiler.shouldFallback(for: category).shouldFallback)
        }
    }

    func testUnknownFailureIsNeverFallbackEligible() {
        struct UnclassifiedFailure: LocalizedError {
            var errorDescription: String? { "an unclassified failure" }
        }

        let category = AppModel.fallbackFailureCategory(for: UnclassifiedFailure())

        XCTAssertEqual(category, .unknown)
        XCTAssertFalse(AttacheFallbackRecompiler.shouldFallback(for: category).shouldFallback)
    }

    private func makeCard(id: String, sessionID: String?, rawText: String) -> VoicemailCard {
        VoicemailCard(
            id: id,
            sourceID: "source",
            sourceKind: SourceKind.codex.rawValue,
            sourceDisplayName: "Codex",
            sessionID: sessionID,
            externalSessionID: sessionID,
            projectPath: "/tmp/project",
            sessionTitle: "Test",
            kind: .update,
            rawText: rawText,
            summary: "summary",
            spokenText: rawText,
            status: .unread,
            createdAt: Date(),
            heardAt: nil,
            metadataJSON: "{}",
            durationMs: 0,
            alignment: nil
        )
    }
}
