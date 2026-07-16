import AttacheCore
@testable import AttacheApp
import Foundation
import XCTest

final class AttacheExhaustiveReviewRuntimeTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let sessionRuntime: SessionContextRuntime
        let source: SessionContextRuntime.FrozenReviewSource
        let snapshot: AttacheRequestSnapshot
    }

    private func makeFixture(turnPairs: Int = 3, charactersPerTurn: Int = 0) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-exhaustive-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transcript = root.appendingPathComponent("review.jsonl")
        var lines: [String] = []
        for index in 0..<(turnPairs * 2) {
            let role = index.isMultiple(of: 2) ? "user" : "assistant"
            let object: [String: Any] = [
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": role,
                    "content": [[
                        "type": "input_text",
                        "text": charactersPerTurn > 0
                            ? "range \(index + 1) " + String(repeating: "e", count: charactersPerTurn)
                            : "range \(index + 1) evidence"
                    ]]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            lines.append(try XCTUnwrap(String(data: data, encoding: .utf8)))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let record = SessionRecord(
            id: "review-session",
            title: "Review session",
            project: root.path,
            threadName: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            archived: false,
            filePath: transcript.path,
            fileMtime: 1_000,
            content: "range evidence",
            sourceKind: .codex
        )
        let sessionRuntime = SessionContextRuntime(databaseURL: root.appendingPathComponent("fts.sqlite"))
        sessionRuntime.reconcile(records: [record])
        let grant = try XCTUnwrap(sessionRuntime.grantAppOwnedFocus(
            sessionID: record.id,
            sourceKind: record.sourceKind.rawValue,
            displayTitle: record.title,
            workingDirectory: record.project
        ))
        let source = try sessionRuntime.freezeReviewSource(focusedSession: grant.session)
        let snapshot = AttacheRequestSnapshot(
            role: .recap,
            personality: Personality.builtIns[0],
            profilePrompt: Personality.builtIns[0].prompt,
            userInput: "Review the entire session.",
            session: .focused(grant.session),
            modelSettings: nil,
            contextItems: [],
            contextStrategy: .maximumCoverage
        )
        return Fixture(root: root, sessionRuntime: sessionRuntime, source: source, snapshot: snapshot)
    }

    private func receipt(
        for snapshot: AttacheRequestSnapshot,
        disposition: AttacheReceiptSourceDisposition = .included,
        text: String? = nil
    ) -> AttacheCompletionResult {
        let evidence = snapshot.contextItems.filter { $0.source == .retrievedTranscriptEvidence }
        let summaries = evidence.map { item in
            AttacheReceiptSourceSummary(
                source: item.provenance ?? AttacheContextItemSource.retrievedTranscriptEvidence.rawValue,
                count: 1,
                disposition: disposition,
                omissionReason: disposition == .included ? nil : "budget"
            )
        }
        let attempt = AttacheReceiptAttemptSummary(
            attemptNumber: 1,
            isFallback: false,
            modelSummary: AttacheReceiptModelSummary(
                provider: "test",
                model: "test-model",
                reasoningLevel: nil,
                strategyKind: snapshot.contextStrategy.kind.rawValue,
                estimatedInputTokens: 100,
                effectiveBudget: 4_096,
                outputReserve: 512,
                toolReserve: 512,
                capabilityProvenance: "providerMetadata",
                capabilityFreshness: nil
            ),
            sourceSummaries: summaries,
            totalEstimatedTokens: 100,
            stagedProcessingRequired: disposition != .included,
            focusedSessionDisplay: nil,
            recompiledForFallback: false
        )
        let view = AttacheContextReceiptView(cardID: snapshot.requestID, attempts: [attempt])
        return AttacheCompletionResult(
            text: text ?? citedOutput(for: snapshot),
            inference: AttacheInferenceMetadata(
                requestID: snapshot.requestID,
                contextReceipt: nil,
                receiptView: view,
                usage: AttacheParsedTokenUsage(
                    inputTokens: 100,
                    outputTokens: 20,
                    cachedTokens: nil,
                    totalTokens: 120
                ),
                modelIdentity: nil,
                containsLocalOnlyContext: false
            )
        )
    }

    private func citedOutput(for snapshot: AttacheRequestSnapshot) -> String {
        let prefix = "exhaustive-review:"
        let citations: [[String: Any]] = snapshot.contextItems.compactMap { item in
            guard item.source == .retrievedTranscriptEvidence,
                  let provenance = item.provenance,
                  provenance.hasPrefix(prefix),
                  let header = item.content.split(separator: "\n", maxSplits: 1).first else {
                return nil
            }
            let value = String(header)
            guard let rangeStart = value.range(of: "range ")?.upperBound,
                  let hashMarker = value.range(of: "; source hash ", range: rangeStart..<value.endIndex),
                  let close = value[hashMarker.upperBound...].firstIndex(of: "]") else {
                return nil
            }
            let ordinals = value[rangeStart..<hashMarker.lowerBound]
                .split(separator: ".", omittingEmptySubsequences: true)
            guard ordinals.count == 2,
                  let start = Int(ordinals[0]),
                  let end = Int(ordinals[1]) else { return nil }
            return [
                "episode_id": String(provenance.dropFirst(prefix.count)),
                "start_turn": start,
                "end_turn": end,
                "source_hash": String(value[hashMarker.upperBound..<close])
            ]
        }
        let object: [String: Any] = [
            "summary": "Covered \(citations.count) frozen ranges with exact citations.",
            "citations": citations
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func testCompleteRequiresActualIncludedReceiptForEveryRange() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = AttacheExhaustiveReviewRuntime()
        let prepared = runtime.prepare(
            source: fixture.source,
            baseSnapshot: fixture.snapshot,
            capability: AttacheModelCapabilityProfile(
                architecturalMaximum: 8_192,
                confidence: .authoritative,
                provenance: .providerMetadata
            ),
            egressClass: "on-device"
        )

        let outcome = try await runtime.runPreparedReview(
            id: prepared.id,
            sourceIsCurrent: { fixture.sessionRuntime.reviewSourceIsCurrent(fixture.source) },
            runStage: { snapshot, _, _ in
                XCTAssertEqual(snapshot.role, .recap)
                XCTAssertTrue(snapshot.session.exactlyMatches(fixture.snapshot.session))
                XCTAssertTrue(snapshot.contextItems.allSatisfy {
                    $0.source == .retrievedTranscriptEvidence
                        && $0.treatment == .requiresStagedProcessing
                })
                return self.receipt(for: snapshot)
            },
            progress: { _ in }
        )

        XCTAssertEqual(outcome.result.status, .complete)
        XCTAssertEqual(outcome.result.coveragePercentage, 1)
        XCTAssertEqual(outcome.progress.coveredRanges, prepared.eligibleRanges)
        XCTAssertTrue(outcome.responseText.contains("All eligible ranges were covered"))
        XCTAssertEqual(
            outcome.inference?.receiptView.attempts.count,
            outcome.result.callCount,
            "The final staged answer must disclose every model call, not only the last stage."
        )
        XCTAssertEqual(outcome.inference?.usage.inputTokens, outcome.result.callCount * 100)
    }

    func testOmittedEvidenceCanNeverBecomeComplete() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = AttacheExhaustiveReviewRuntime()
        let prepared = runtime.prepare(
            source: fixture.source,
            baseSnapshot: fixture.snapshot,
            capability: .unknown,
            egressClass: "unknown"
        )
        let outcome = try await runtime.runPreparedReview(
            id: prepared.id,
            sourceIsCurrent: { true },
            runStage: { snapshot, _, _ in self.receipt(for: snapshot, disposition: .truncated) },
            progress: { _ in }
        )

        XCTAssertEqual(outcome.result.status, .incomplete)
        XCTAssertLessThan(outcome.result.coveragePercentage, 1)
        XCTAssertFalse(outcome.responseText.contains("All eligible ranges were covered"))
    }

    func testOversizedExactRangeFailsClosedWithoutAProviderCall() async throws {
        let fixture = try makeFixture(turnPairs: 1, charactersPerTurn: 20_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = AttacheExhaustiveReviewRuntime()
        let prepared = runtime.prepare(
            source: fixture.source,
            baseSnapshot: fixture.snapshot,
            capability: AttacheModelCapabilityProfile(architecturalMaximum: 1_024),
            egressClass: "on-device"
        )
        var providerCalls = 0

        let outcome = try await runtime.runPreparedReview(
            id: prepared.id,
            sourceIsCurrent: { true },
            runStage: { snapshot, _, _ in
                providerCalls += 1
                return self.receipt(for: snapshot)
            },
            progress: { _ in }
        )

        XCTAssertEqual(providerCalls, 0)
        XCTAssertEqual(outcome.result.status, .incomplete)
        XCTAssertEqual(outcome.result.callCount, 0)
        XCTAssertEqual(outcome.progress.coveredRanges, 0)
    }

    func testSameEvidenceCountWithWrongEpisodeIDsCannotBecomeComplete() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = AttacheExhaustiveReviewRuntime()
        let prepared = runtime.prepare(
            source: fixture.source,
            baseSnapshot: fixture.snapshot,
            capability: .unknown,
            egressClass: "loopback"
        )
        let outcome = try await runtime.runPreparedReview(
            id: prepared.id,
            sourceIsCurrent: { true },
            runStage: { snapshot, _, _ in
                var completion = self.receipt(for: snapshot)
                let original = try XCTUnwrap(completion.inference.receiptView.attempts.first)
                let forged = original.sourceSummaries.enumerated().map { index, summary in
                    AttacheReceiptSourceSummary(
                        source: "exhaustive-review:forged-\(index)",
                        count: summary.count,
                        disposition: summary.disposition,
                        omissionReason: summary.omissionReason
                    )
                }
                let forgedAttempt = AttacheReceiptAttemptSummary(
                    attemptNumber: original.attemptNumber,
                    isFallback: original.isFallback,
                    modelSummary: original.modelSummary,
                    sourceSummaries: forged,
                    totalEstimatedTokens: original.totalEstimatedTokens,
                    stagedProcessingRequired: false,
                    focusedSessionDisplay: original.focusedSessionDisplay,
                    recompiledForFallback: original.recompiledForFallback
                )
                completion.inference = AttacheInferenceMetadata(
                    requestID: completion.inference.requestID,
                    contextReceipt: nil,
                    receiptView: AttacheContextReceiptView(
                        cardID: snapshot.requestID,
                        attempts: [forgedAttempt]
                    ),
                    usage: completion.inference.usage,
                    modelIdentity: completion.inference.modelIdentity,
                    containsLocalOnlyContext: completion.inference.containsLocalOnlyContext
                )
                return completion
            },
            progress: { _ in }
        )

        XCTAssertEqual(outcome.result.status, .incomplete)
        XCTAssertEqual(outcome.progress.coveredRanges, 0)
    }

    func testExactReceiptWithoutExactStructuredCitationsCannotBecomeComplete() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = AttacheExhaustiveReviewRuntime()
        let prepared = runtime.prepare(
            source: fixture.source,
            baseSnapshot: fixture.snapshot,
            capability: .unknown,
            egressClass: "loopback"
        )
        let outcome = try await runtime.runPreparedReview(
            id: prepared.id,
            sourceIsCurrent: { true },
            runStage: { snapshot, _, _ in
                self.receipt(
                    for: snapshot,
                    text: #"{"summary":"I looked at it.","citations":[]}"#
                )
            },
            progress: { _ in }
        )

        XCTAssertEqual(outcome.result.status, .incomplete)
        XCTAssertEqual(outcome.progress.coveredRanges, 0)
    }

    func testStructuredCitationMustMatchExactFrozenHashAndRange() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = AttacheExhaustiveReviewRuntime()
        let prepared = runtime.prepare(
            source: fixture.source,
            baseSnapshot: fixture.snapshot,
            capability: .unknown,
            egressClass: "loopback"
        )
        let outcome = try await runtime.runPreparedReview(
            id: prepared.id,
            sourceIsCurrent: { true },
            runStage: { snapshot, _, _ in
                let valid = self.citedOutput(for: snapshot)
                let forged = valid.replacingOccurrences(
                    of: #""source_hash":"#,
                    with: #""source_hash":"forged-"#
                )
                return self.receipt(for: snapshot, text: forged)
            },
            progress: { _ in }
        )

        XCTAssertEqual(outcome.result.status, .incomplete)
        XCTAssertEqual(outcome.progress.coveredRanges, 0)
    }

    func testNoModelResultDoesNotClaimAProviderCall() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = AttacheExhaustiveReviewRuntime()
        let prepared = runtime.prepare(
            source: fixture.source,
            baseSnapshot: fixture.snapshot,
            capability: .unknown,
            egressClass: "disabled"
        )
        let outcome = try await runtime.runPreparedReview(
            id: prepared.id,
            sourceIsCurrent: { true },
            runStage: { snapshot, _, _ in
                AttacheCompletionResult(
                    text: nil,
                    inference: .noModel(snapshot: snapshot)
                )
            },
            progress: { _ in }
        )

        XCTAssertEqual(outcome.result.status, .incomplete)
        XCTAssertEqual(outcome.result.callCount, 0)
        XCTAssertTrue(outcome.inference?.receiptView.noModelContext == true)
    }

    func testCancelStopsNewCallsAndExplicitResumeContinuesCheckpoints() async throws {
        let fixture = try makeFixture(turnPairs: 6)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = AttacheExhaustiveReviewRuntime()
        let prepared = runtime.prepare(
            source: fixture.source,
            baseSnapshot: fixture.snapshot,
            capability: AttacheModelCapabilityProfile(architecturalMaximum: 1_024),
            egressClass: "on-device"
        )
        var firstRunCalls = 0
        let canceled = try await runtime.runPreparedReview(
            id: prepared.id,
            sourceIsCurrent: { true },
            runStage: { snapshot, _, _ in
                firstRunCalls += 1
                runtime.cancel(id: prepared.id)
                return self.receipt(for: snapshot)
            },
            progress: { _ in }
        )
        XCTAssertEqual(firstRunCalls, 1)
        XCTAssertEqual(canceled.result.status, .canceled)

        var resumeCalls = 0
        let resumed = try await runtime.runPreparedReview(
            id: prepared.id,
            sourceIsCurrent: { true },
            runStage: { snapshot, _, _ in
                resumeCalls += 1
                return self.receipt(for: snapshot)
            },
            progress: { _ in }
        )
        XCTAssertGreaterThan(resumeCalls, 0)
        XCTAssertEqual(resumed.result.status, .complete)
    }

    func testSourceMutationMarksReviewStaleBeforeAnyProviderCall() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = AttacheExhaustiveReviewRuntime()
        let prepared = runtime.prepare(
            source: fixture.source,
            baseSnapshot: fixture.snapshot,
            capability: .unknown,
            egressClass: "on-device"
        )
        var calls = 0
        let outcome = try await runtime.runPreparedReview(
            id: prepared.id,
            sourceIsCurrent: { false },
            runStage: { snapshot, _, _ in
                calls += 1
                return self.receipt(for: snapshot)
            },
            progress: { _ in }
        )
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(outcome.result.status, .stale)
    }
}
