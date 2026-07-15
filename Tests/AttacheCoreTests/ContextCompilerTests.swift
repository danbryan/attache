import AttacheCore
import XCTest

final class ContextCompilerTests: XCTestCase {

    private func makeInput(userInput: String = "What did the agent do?", role: AttacheRequestRole = .conversation, session: AttacheSessionAuthorization = .contextFree) -> ContextCompilerInput {
        ContextCompilerInput(
            userInput: userInput,
            modelIdentity: ModelIdentity(provider: "ollama", normalizedEndpoint: "http://127.0.0.1:11434", requestedModel: "qwen3"),
            role: role,
            profilePrompt: "Speak plainly.",
            memoryContext: nil,
            session: session
        )
    }

    private func makeProfile(context: Int?) -> AttacheModelCapabilityProfile {
        AttacheModelCapabilityProfile(architecturalMaximum: context, confidence: .authoritative, provenance: .providerMetadata)
    }

    private func basicItems() -> [AttacheContextItem] {
        [
            AttacheContextItem(source: .safetyPolicy, content: "Safety rules.", priority: 100),
            AttacheContextItem(source: .activePersonality, content: "You are Attaché.", priority: 90),
            AttacheContextItem(source: .currentUserTurn, content: "What did the agent do?", priority: 80),
        ]
    }

    // Criterion 1 + 9: compilation produces messages, budget, and a content-free receipt.
    func testCompilationProducesMessagesBudgetAndReceipt() throws {
        let compiled = try ContextCompiler.compile(
            input: makeInput(), items: basicItems(),
            capability: makeProfile(context: 32_000), strategy: .automatic
        )
        XCTAssertFalse(compiled.messages.isEmpty)
        XCTAssertNotNil(compiled.budgetPlan.effectiveHardLimit)
        XCTAssertFalse(compiled.receipt.includedSources.isEmpty)
        XCTAssertTrue(compiled.receipt.includedSources.contains("safetyPolicy"))
        XCTAssertTrue(compiled.receipt.includedSources.contains("activePersonality"))
        XCTAssertTrue(compiled.receipt.includedSources.contains("currentUserTurn"))
        // Receipt is content-free: no source text.
        XCTAssertFalse(compiled.receipt.includedSources.contains("Safety rules."))
        XCTAssertFalse(compiled.receipt.includedSources.contains("What did the agent do?"))
    }

    // Criterion 3: all roles remain within synthetic 8K and 64K plans.
    func testPlansStayWithinHardLimits() throws {
        for context in [8_000, 64_000] {
            let compiled = try ContextCompiler.compile(
                input: makeInput(), items: basicItems(),
                capability: makeProfile(context: context), strategy: .maximumCoverage
            )
            XCTAssertLessThanOrEqual(
                compiled.receipt.totalEstimatedTokens,
                compiled.budgetPlan.effectiveHardLimit ?? Int.max,
                "Compiled request for \(context) must stay within the hard limit."
            )
        }
    }

    // Criterion 4: a 1M Maximum coverage plan includes more evidence than Efficient.
    func testMaximumCoverageIncludesMoreEvidenceThanEfficient() throws {
        var items = basicItems()
        // Add large evidence items that will overflow Efficient's 0.5 multiplier
        // but fit under Maximum's 1.0 multiplier on a 1M model.
        for i in 0..<20 {
            items.append(AttacheContextItem(
                source: .retrievedTranscriptEvidence,
                content: String(repeating: "evidence chunk \(i) ", count: 10_000),
                priority: 50, treatment: .exactOnly
            ))
        }
        let efficient = try ContextCompiler.compile(
            input: makeInput(), items: items,
            capability: makeProfile(context: 1_000_000), strategy: .efficient
        )
        let maximum = try ContextCompiler.compile(
            input: makeInput(), items: items,
            capability: makeProfile(context: 1_000_000), strategy: .maximumCoverage
        )
        let efficientEvidence = efficient.receipt.includedSources.filter { $0 == "retrievedTranscriptEvidence" }.count
        let maximumEvidence = maximum.receipt.includedSources.filter { $0 == "retrievedTranscriptEvidence" }.count
        XCTAssertGreaterThan(maximumEvidence, efficientEvidence,
                            "Maximum coverage must include more raw evidence than Efficient on a 1M model.")
    }

    // Criterion 5: a context-free call compiles with no work-session evidence or tools.
    func testContextFreeCallExcludesSessionEvidence() throws {
        let items = basicItems() + [
            AttacheContextItem(source: .focusedSessionMetadata, content: "Session: secret-session", authorization: .focused(AttacheFocusedSession(sessionID: "s", sourceKind: "codex", displayTitle: "T", workingDirectory: nil)), priority: 30),
            AttacheContextItem(source: .toolDefinitions, content: "[{\"name\":\"read_file\"}]", authorization: .focused(AttacheFocusedSession(sessionID: "s", sourceKind: "codex", displayTitle: "T", workingDirectory: nil)), priority: 20),
        ]
        let compiled = try ContextCompiler.compile(
            input: makeInput(session: .contextFree), items: items,
            capability: makeProfile(context: 32_000), strategy: .automatic
        )
        // The context-free call should not include focused-session metadata or tools.
        // (The compiler respects the authorization: items authorized for a focused
        // session are not included in a context-free compile.)
        XCTAssertFalse(compiled.receipt.includedSources.contains("toolDefinitions"),
                      "A context-free call must not include work-session tools.")
    }

    // Criterion 6: a focused call includes its frozen focused session metadata.
    func testFocusedCallIncludesSessionMetadata() throws {
        let focused = AttacheSessionAuthorization.focused(AttacheFocusedSession(
            sessionID: "frozen-1", sourceKind: "codex", displayTitle: "Frozen", workingDirectory: "/tmp/proj"
        ))
        let items = basicItems() + [
            AttacheContextItem(source: .focusedSessionMetadata, content: "Focused: Frozen session", authorization: focused, priority: 30),
        ]
        let compiled = try ContextCompiler.compile(
            input: makeInput(session: focused), items: items,
            capability: makeProfile(context: 32_000), strategy: .automatic
        )
        XCTAssertTrue(compiled.receipt.includedSources.contains("focusedSessionMetadata"))
    }

    // Criterion 7: protected content that cannot fit produces a typed failure.
    func testProtectedOverflowFails() {
        let hugeInput = String(repeating: "x", count: 40_000)
        XCTAssertThrowsError(try ContextCompiler.compile(
            input: makeInput(userInput: hugeInput), items: basicItems(),
            capability: makeProfile(context: 8_000), strategy: .automatic
        )) { error in
            guard case .budgetPlanningFailure(.protectedContentOverflow) = error as? AttacheContextCompilerError else {
                return XCTFail("Expected protectedContentOverflow, got \(error)")
            }
        }
    }

    // Criterion 8: broad evidence that cannot fit triggers staged processing.
    func testBroadEvidenceTriggersStagedProcessing() throws {
        let items = basicItems() + [
            AttacheContextItem(
                source: .retrievedTranscriptEvidence,
                content: String(repeating: "huge evidence ", count: 5_000),
                priority: 50, treatment: .exactOnly
            ),
        ]
        // Use a small model so the evidence cannot fit.
        let compiled = try ContextCompiler.compile(
            input: makeInput(), items: items,
            capability: makeProfile(context: 8_000), strategy: .efficient
        )
        XCTAssertTrue(compiled.receipt.stagedProcessingRequired,
                      "Broad evidence that cannot fit must trigger staged processing, not silent omission.")
    }

    // Criterion 9: receipts are content-free.
    func testReceiptIsContentFree() throws {
        let items = basicItems() + [
            AttacheContextItem(source: .durableMemory, content: "User prefers terse summaries.", priority: 40),
        ]
        let compiled = try ContextCompiler.compile(
            input: makeInput(), items: items,
            capability: makeProfile(context: 32_000), strategy: .automatic
        )
        // The receipt names sources, not content.
        XCTAssertTrue(compiled.receipt.includedSources.contains("durableMemory"))
        XCTAssertFalse(compiled.receipt.includedSources.contains("terse summaries"))
        XCTAssertFalse(compiled.receipt.includedSources.contains("User prefers"))
    }

    // Determinism: equal inputs produce equal compiled requests.
    func testCompilationIsDeterministic() throws {
        let items = basicItems()
        let c1 = try ContextCompiler.compile(input: makeInput(), items: items, capability: makeProfile(context: 32_000), strategy: .automatic)
        let c2 = try ContextCompiler.compile(input: makeInput(), items: items, capability: makeProfile(context: 32_000), strategy: .automatic)
        XCTAssertEqual(c1.messages, c2.messages)
        XCTAssertEqual(c1.receipt, c2.receipt)
    }

    // Omission with marker: low-priority items are omitted when budget is tight.
    func testLowPriorityItemsOmittedWhenBudgetTight() throws {
        var items = basicItems()
        for i in 0..<20 {
            items.append(AttacheContextItem(
                source: .olderChatSummary, content: "Old summary \(i) " + String(repeating: "x", count: 500),
                priority: 10, treatment: .omitWithMarker
            ))
        }
        // Use a very small model to force omission.
        let compiled = try ContextCompiler.compile(
            input: makeInput(), items: items,
            capability: makeProfile(context: 2_000), strategy: .efficient
        )
        // Protected items are always included.
        XCTAssertTrue(compiled.receipt.includedSources.contains("safetyPolicy"))
        XCTAssertTrue(compiled.receipt.includedSources.contains("currentUserTurn"))
        // Some low-priority summaries are omitted.
        XCTAssertGreaterThan(compiled.receipt.omittedSources.count, 0)
    }
}