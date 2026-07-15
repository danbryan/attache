import AttacheCore
import XCTest
import Foundation

final class AttacheToolBudgetEnforcerTests: XCTestCase {

    private func makeReserve(total: Int = 10_000, cap: Int = 3_000) -> AttacheToolBudgetReserve {
        AttacheToolBudgetReserve(totalTokens: total, perCallCap: cap)
    }

    // Criterion 1: negative, zero, enormous, nonnumeric, and missing size
    // arguments resolve safely.
    func testNegativeZeroEnormousMissingAllResolveSafely() {
        let policy = AttacheToolBudgetPolicy.from(strategy: .automatic)
        let reserve = makeReserve()
        // nil (missing) -> default
        let nilLimits = AttacheToolBudgetEnforcer.resolveLimits(
            requestedMaxChars: nil, requestedMaxResults: nil,
            requestedStartOffset: nil, requestedQueryLength: nil,
            reserve: reserve, policy: policy
        )
        XCTAssertGreaterThan(nilLimits.maxChars, 0)
        XCTAssertEqual(nilLimits.startOffset, 0)
        // zero -> default
        let zero = AttacheToolBudgetEnforcer.resolveLimits(
            requestedMaxChars: 0, requestedMaxResults: 0,
            requestedStartOffset: 0, requestedQueryLength: nil,
            reserve: reserve, policy: policy
        )
        XCTAssertGreaterThan(zero.maxChars, 0)
        // negative -> default + clamped offset 0
        let neg = AttacheToolBudgetEnforcer.resolveLimits(
            requestedMaxChars: -999, requestedMaxResults: -1,
            requestedStartOffset: -5, requestedQueryLength: nil,
            reserve: reserve, policy: policy
        )
        XCTAssertGreaterThan(neg.maxChars, 0)
        XCTAssertEqual(neg.startOffset, 0)
        // enormous -> clamped to per-call cap / absolute
        let huge = AttacheToolBudgetEnforcer.resolveLimits(
            requestedMaxChars: 100_000_000, requestedMaxResults: 999,
            requestedStartOffset: nil, requestedQueryLength: nil,
            reserve: reserve, policy: policy
        )
        XCTAssertLessThanOrEqual(huge.maxChars, policy.maxCharsAbsolute)
        XCTAssertLessThanOrEqual(huge.maxChars, reserve.perCallCap)
    }

    // Criterion 2: no individual result exceeds the live remaining allowance.
    func testIndividualResultDoesNotExceedRemaining() {
        let policy = AttacheToolBudgetPolicy.from(strategy: .automatic)
        var reserve = makeReserve(total: 5_000, cap: 1_000)
        let bigContent = String(repeating: "x", count: 100_000) // huge
        let limits = AttacheToolCallLimits(
            maxChars: 1_000, maxResults: 10, startOffset: 0,
            maxQueryLength: 200, maxFilePathLength: 1_024
        )
        let (_, decision) = AttacheToolBudgetEnforcer.accountResult(
            content: bigContent, kind: .fileRead, limits: limits, reserve: &reserve
        )
        XCTAssertLessThanOrEqual(decision.includedTokens, 1_000, "individual result within per-call cap")
        XCTAssertLessThanOrEqual(decision.includedTokens, 5_000, "individual result within total reserve")
        XCTAssertEqual(decision.outcome, .excerpt, "huge result is excerpted")
    }

    // Criterion 2: no cumulative result exceeds the live remaining allowance.
    func testCumulativeResultsDoNotExceedReserve() {
        var reserve = makeReserve(total: 400, cap: 100)
        let limits = AttacheToolCallLimits(
            maxChars: 10_000, maxResults: 5, startOffset: 0,
            maxQueryLength: 200, maxFilePathLength: 1_024
        )
        // 8 sequential calls, each trying to consume a lot.
        for _ in 0..<8 {
            let content = String(repeating: "y", count: 10_000)
            let (_, decision) = AttacheToolBudgetEnforcer.accountResult(
                content: content, kind: .transcriptPage, limits: limits, reserve: &reserve
            )
            XCTAssertLessThanOrEqual(decision.includedTokens, 100, "each call within per-call cap")
        }
        XCTAssertLessThanOrEqual(reserve.consumedTokens, 400, "cumulative does not exceed reserve")
        XCTAssertTrue(reserve.isExhausted, "reserve is spent after enough calls")
    }

    // Criterion 3: a million-character transcript turn returns a bounded
    // labeled excerpt, not the whole turn.
    func testMillionCharTurnReturnsBoundedExcerpt() {
        let policy = AttacheToolBudgetPolicy.from(strategy: .automatic)
        var reserve = makeReserve(total: 10_000, cap: 2_000)
        let limits = AttacheToolCallLimits(
            maxChars: 2_000, maxResults: 10, startOffset: 0,
            maxQueryLength: 200, maxFilePathLength: 1_024
        )
        let million = String(repeating: "a", count: 1_000_000)
        let (excerpt, decision) = AttacheToolBudgetEnforcer.pageTranscriptTurn(
            turnNumber: 42, content: million, limits: limits, reserve: &reserve
        )
        XCTAssertTrue(excerpt.hasPrefix("Turn 42:"), "turn number preserved")
        XCTAssertLessThan(excerpt.count, 1_000_000, "not the whole turn")
        XCTAssertEqual(decision.outcome, .excerpt)
        XCTAssertGreaterThan(decision.omittedTokens, 0, "omission recorded")
        XCTAssertNotNil(decision.continuationHint, "continuation hint provided")
        XCTAssertNotNil(decision.omissionMarker, "omission marker provided")
    }

    // Criterion 4: multiple tool calls in one response share one reserve.
    func testMultipleCallsShareOneReserve() {
        var reserve = makeReserve(total: 6_000, cap: 3_000)
        let limits = AttacheToolCallLimits(
            maxChars: 3_000, maxResults: 10, startOffset: 0,
            maxQueryLength: 200, maxFilePathLength: 1_024
        )
        // Call 1 consumes some.
        let content1 = String(repeating: "x", count: 20_000)
        let (_, d1) = AttacheToolBudgetEnforcer.accountResult(
            content: content1, kind: .fileRead, limits: limits, reserve: &reserve
        )
        let remainingAfter1 = reserve.remainingTokens
        // Call 2 shares the same reserve.
        let content2 = String(repeating: "y", count: 20_000)
        let (_, d2) = AttacheToolBudgetEnforcer.accountResult(
            content: content2, kind: .fileRead, limits: limits, reserve: &reserve
        )
        XCTAssertLessThan(reserve.remainingTokens, remainingAfter1, "second call consumed from same reserve")
        XCTAssertGreaterThan(d1.includedTokens + d2.includedTokens, 0)
        XCTAssertLessThanOrEqual(reserve.consumedTokens, 6_000)
    }

    // Criterion 5: truncated results identify what was omitted and how to
    // request the next range without claiming exhaustive coverage.
    func testTruncatedResultsIdentifyOmissionAndContinuation() {
        var reserve = makeReserve(total: 5_000, cap: 1_000)
        let limits = AttacheToolCallLimits(
            maxChars: 1_000, maxResults: 10, startOffset: 100,
            maxQueryLength: 200, maxFilePathLength: 1_024
        )
        let content = String(repeating: "z", count: 50_000)
        let (_, decision) = AttacheToolBudgetEnforcer.accountResult(
            content: content, kind: .fileRead, limits: limits, reserve: &reserve
        )
        XCTAssertEqual(decision.outcome, .excerpt)
        XCTAssertNotNil(decision.omissionMarker)
        XCTAssertTrue(decision.omissionMarker?.contains("omitted") ?? false, "omission identified")
        XCTAssertNotNil(decision.continuationHint)
        XCTAssertTrue(decision.continuationHint?.contains("start=") ?? false, "continuation tells how to get next range")
        // Must not claim exhaustive coverage.
        XCTAssertFalse(decision.omissionMarker?.contains("complete") ?? false)
        XCTAssertFalse(decision.omissionMarker?.contains("all") ?? false)
    }

    // Criterion 6: budget exhaustion stops further reads and allows a final
    // answer that discloses the limit.
    func testBudgetExhaustionStopsReadsAndDiscloses() {
        var reserve = makeReserve(total: 50, cap: 50)
        let limits = AttacheToolCallLimits(
            maxChars: 10_000, maxResults: 10, startOffset: 0,
            maxQueryLength: 200, maxFilePathLength: 1_024
        )
        // Spend the reserve with one huge call.
        let big = String(repeating: "x", count: 100_000)
        _ = AttacheToolBudgetEnforcer.accountResult(
            content: big, kind: .transcriptPage, limits: limits, reserve: &reserve
        )
        XCTAssertTrue(reserve.isExhausted, "reserve exhausted after huge call")
        // Next call returns budget-exhausted, not data.
        let (content, decision) = AttacheToolBudgetEnforcer.accountResult(
            content: "more data", kind: .fileRead, limits: limits, reserve: &reserve
        )
        XCTAssertEqual(decision.outcome, .budgetExhausted)
        XCTAssertEqual(content, "", "no data returned when exhausted")
        // The structured exhaustion result discloses the limit.
        let (exhaustedContent, _) = AttacheToolBudgetEnforcer.budgetExhaustedResult()
        XCTAssertTrue(exhaustedContent.contains("budget exhausted"), "discloses the limit")
        XCTAssertTrue(exhaustedContent.contains("disclose"), "tells the model to disclose to the user")
    }

    // Criterion 7: Efficient, Automatic, and Maximum receive distinct dynamic
    // allowances, not one low cap.
    func testStrategiesReceiveDistinctAllowances() {
        let efficient = AttacheToolBudgetPolicy.from(strategy: .efficient)
        let automatic = AttacheToolBudgetPolicy.from(strategy: .automatic)
        let maximum = AttacheToolBudgetPolicy.from(strategy: .maximumCoverage)
        XCTAssertLessThan(efficient.perCallFraction, automatic.perCallFraction)
        XCTAssertLessThan(automatic.perCallFraction, maximum.perCallFraction)
        XCTAssertLessThan(efficient.defaultMaxChars, automatic.defaultMaxChars)
        XCTAssertLessThan(automatic.defaultMaxChars, maximum.defaultMaxChars)
        // Distinct reserves from the same tool budget.
        let toolBudget = 10_000
        let rEff = efficient.reserve(toolReserveTokens: toolBudget)
        let rAuto = automatic.reserve(toolReserveTokens: toolBudget)
        let rMax = maximum.reserve(toolReserveTokens: toolBudget)
        XCTAssertLessThan(rEff.perCallCap, rAuto.perCallCap)
        XCTAssertLessThan(rAuto.perCallCap, rMax.perCallCap)
    }

    // Criterion 8: a malicious provider-manufactured call receives no
    // unauthorized session/file data. The enforcer clamps before any data is
    // read; a refused or exhausted call returns no content.
    func testMaliciousCallReceivesNoUnauthorizedData() {
        var reserve = makeReserve(total: 50, cap: 50)
        // Exhaust it.
        let limits = AttacheToolCallLimits(
            maxChars: 10_000, maxResults: 10, startOffset: 0,
            maxQueryLength: 200, maxFilePathLength: 1_024
        )
        _ = AttacheToolBudgetEnforcer.accountResult(
            content: String(repeating: "x", count: 100_000),
            kind: .transcriptPage, limits: limits, reserve: &reserve
        )
        // A malicious call asking for a huge page gets nothing.
        let (content, decision) = AttacheToolBudgetEnforcer.accountResult(
            content: "secret session data", kind: .fileRead,
            limits: limits, reserve: &reserve
        )
        XCTAssertEqual(content, "", "no unauthorized data returned")
        XCTAssertEqual(decision.outcome, .budgetExhausted)
    }

    // Criterion 9: existing 5 MB file refusal and containment rules remain at
    // least as strict.
    func testFiveMBFileRefusalStillStrict() {
        XCTAssertTrue(AttacheFileContainmentGuard.shouldRefuse(
            filePath: "/tmp/inside.txt", workingDirectory: "/tmp/",
            fileSizeBytes: 6 * 1024 * 1024
        ), "over 5 MB is refused")
        XCTAssertFalse(AttacheFileContainmentGuard.shouldRefuse(
            filePath: "/tmp/inside.txt", workingDirectory: "/tmp/",
            fileSizeBytes: 1_000
        ), "under 5 MB and inside is allowed")
    }

    func testContainmentRejectsEscapingPaths() {
        XCTAssertTrue(AttacheFileContainmentGuard.shouldRefuse(
            filePath: "/etc/passwd", workingDirectory: "/Users/dan/proj",
            fileSizeBytes: 100
        ), "absolute path outside working directory refused")
        XCTAssertTrue(AttacheFileContainmentGuard.shouldRefuse(
            filePath: "../../../etc/passwd", workingDirectory: "/Users/dan/proj",
            fileSizeBytes: 100
        ), "parent traversal refused")
        XCTAssertTrue(AttacheFileContainmentGuard.shouldRefuse(
            filePath: "/Users/dan/proj/file.txt", workingDirectory: "/Users/dan/proj",
            fileSizeBytes: 100, resolvesOutsideWorkingDirectory: true
        ), "symlink escaping working directory refused")
    }

    // Effectful tool tracker: fallback cannot replay effectful calls.
    func testEffectfulTrackerProhibitsReplay() {
        var tracker = AttacheToolEffectTracker()
        XCTAssertFalse(tracker.hasEffectfulCalls)
        XCTAssertFalse(tracker.prohibitsReplay())
        tracker.recordEffect(toolName: "send_message", callID: "call-1")
        XCTAssertTrue(tracker.hasEffectfulCalls)
        XCTAssertTrue(tracker.prohibitsReplay(), "fallback cannot replay effectful calls")
        XCTAssertTrue(tracker.wasRecorded(toolName: "send_message", callID: "call-1"))
        XCTAssertFalse(tracker.wasRecorded(toolName: "send_message", callID: "call-2"))
    }

    // Reserve consume clamps to remaining.
    func testReserveConsumeClampsToRemaining() {
        var reserve = makeReserve(total: 1_000, cap: 500)
        let consumed = reserve.consume(2_000)
        XCTAssertEqual(consumed, 1_000, "cannot consume more than total")
        XCTAssertTrue(reserve.isExhausted)
        let extra = reserve.consume(500)
        XCTAssertEqual(extra, 0, "nothing left to consume")
    }

    // Full result (within budget) is included without truncation.
    func testFullResultIncludedWhenWithinBudget() {
        var reserve = makeReserve(total: 10_000, cap: 5_000)
        let limits = AttacheToolCallLimits(
            maxChars: 5_000, maxResults: 10, startOffset: 0,
            maxQueryLength: 200, maxFilePathLength: 1_024
        )
        let content = "small result"
        let (clamped, decision) = AttacheToolBudgetEnforcer.accountResult(
            content: content, kind: .searchResult, limits: limits, reserve: &reserve
        )
        XCTAssertEqual(clamped, content, "full content included when within budget")
        XCTAssertEqual(decision.outcome, .full)
        XCTAssertEqual(decision.omittedTokens, 0)
    }

    // Continuation hint varies by tool kind.
    func testContinuationHintVariesByKind() {
        let transcript = AttacheToolBudgetEnforcer.continuationHint(
            kind: .transcriptPage, startOffset: 0, includedChars: 100, totalChars: 1000
        )
        XCTAssertTrue(transcript.contains("turn"))
        let file = AttacheToolBudgetEnforcer.continuationHint(
            kind: .fileRead, startOffset: 0, includedChars: 100, totalChars: 1000
        )
        XCTAssertTrue(file.contains("file"))
        XCTAssertTrue(file.contains("start=100"))
    }
}