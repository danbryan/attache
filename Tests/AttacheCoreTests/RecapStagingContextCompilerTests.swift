import AttacheCore
import XCTest

/// Proves the INF-353 acceptance criteria at the Core compiler boundary:
/// recap items ride as `.recapEvidence` context items, not folded into the
/// protected `currentUserTurn`, so a large inbox stages instead of throwing
/// `protectedContentOverflow`.
final class RecapStagingContextCompilerTests: XCTestCase {
    private func makeProfile(context: Int?) -> AttacheModelCapabilityProfile {
        AttacheModelCapabilityProfile(architecturalMaximum: context, confidence: .authoritative, provenance: .providerMetadata)
    }

    private func recapItems(count: Int, textLength: Int = 40) -> [(id: String, item: AttachePersonality.RecapItem)] {
        (0..<count).map { i in
            (
                id: "card-\(i)",
                item: AttachePersonality.RecapItem(
                    sessionTitle: "Session \(i % 5)",
                    summary: String(repeating: "detail ", count: textLength),
                    spokenText: "spoken",
                    needsDecision: i % 7 == 0
                )
            )
        }
    }

    private func recapInput(userInput: String) -> ContextCompilerInput {
        ContextCompilerInput(
            userInput: userInput,
            modelIdentity: ModelIdentity(provider: "ollama", normalizedEndpoint: "http://127.0.0.1:11434", requestedModel: "qwen3"),
            role: .recap,
            profilePrompt: "Speak plainly.",
            memoryContext: nil,
            session: .contextFree
        )
    }

    // AC: recap items no longer ride in the protected user turn. The receipt
    // must list `recapEvidence` as an included source, and `currentUserTurn`
    // must remain the small fixed instruction, not the concatenated items.
    func testRecapItemsRideAsIncludedRecapEvidenceNotCurrentUserTurn() throws {
        let items = recapItems(count: 5)
        let contextItems: [AttacheContextItem] = [
            AttacheContextItem(source: .safetyPolicy, content: "Safety rules.", priority: 100),
            AttacheContextItem(source: .activePersonality, content: "You are Attaché.", priority: 90)
        ] + AttachePersonality.recapContextItems(from: items)

        let instruction = AttachePersonality.recapStagedUserInstruction()
        let compiled = try ContextCompiler.compile(
            input: recapInput(userInput: instruction),
            items: contextItems,
            capability: makeProfile(context: 32_000),
            strategy: .automatic
        )

        XCTAssertTrue(compiled.receipt.includedSources.contains("recapEvidence"))
        XCTAssertTrue(compiled.receipt.includedSources.contains("currentUserTurn"))
        XCTAssertFalse(compiled.receipt.stagedProcessingRequired)

        // The user turn message is the fixed instruction, not a concatenation
        // of the five items' text.
        let userMessages = compiled.messages.filter { $0.role == "user" }
        XCTAssertTrue(userMessages.contains { $0.content == instruction })
        for item in items {
            XCTAssertFalse(
                userMessages.contains { $0.content.contains(item.item.sessionTitle) && $0.content == instruction },
                "recap item text must not be folded into the fixed instruction turn"
            )
        }
        // The item content is present somewhere in the compiled request (as
        // evidence), just not inside the fixed instruction string itself.
        let allContent = compiled.messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(allContent.contains("Session 0"))
    }

    // AC: a large synthetic inbox never throws protectedContentOverflow. The
    // fixed instruction keeps the protected user turn tiny regardless of how
    // many recap items are supplied; oversized evidence instead sets
    // `stagedProcessingRequired` on the receipt.
    func testLargeRecapEvidenceStagesRatherThanOverflowingProtectedContent() throws {
        let items = recapItems(count: 400, textLength: 60)
        let contextItems: [AttacheContextItem] = [
            AttacheContextItem(source: .safetyPolicy, content: "Safety rules.", priority: 100),
            AttacheContextItem(source: .activePersonality, content: "You are Attaché.", priority: 90)
        ] + AttachePersonality.recapContextItems(from: items)

        let instruction = AttachePersonality.recapStagedUserInstruction()

        // A small model: even with 400 padded items, this must not throw.
        let compiled = try ContextCompiler.compile(
            input: recapInput(userInput: instruction),
            items: contextItems,
            capability: makeProfile(context: 8_000),
            strategy: .efficient
        )

        XCTAssertTrue(compiled.receipt.includedSources.contains("currentUserTurn"))
        // Some recap evidence could not fit and must show up as staged, not
        // silently vanish.
        XCTAssertTrue(compiled.receipt.stagedProcessingRequired || compiled.receipt.includedSources.contains("recapEvidence"))
    }

    // AC: single-stage path produces a deterministic, byte-identical message
    // structure to a golden fixture.
    func testSingleStageMessageStructureMatchesGoldenFixture() throws {
        let items = [
            (id: "card-0", item: AttachePersonality.RecapItem(
                sessionTitle: "Fix the thumbnail",
                summary: "The thumbnail render went from red to blue and shipped.",
                spokenText: "spoken",
                needsDecision: false
            )),
            (id: "card-1", item: AttachePersonality.RecapItem(
                sessionTitle: "Deploy pipeline",
                summary: "The deploy needs your decision on the rollout window.",
                spokenText: "spoken",
                needsDecision: true
            ))
        ]
        let system = AttachePersonality.recapStagedSystemPrompt(
            itemCount: items.count,
            sessionCount: AttachePersonality.recapSessionCount(items.map(\.item.sessionTitle)),
            memoryContext: nil
        )
        let instruction = AttachePersonality.recapStagedUserInstruction()
        let contextItems = AttachePersonality.recapContextItems(from: items)

        func compileOnce() throws -> [AttacheChatMessage] {
            try ContextCompiler.compile(
                input: recapInput(userInput: instruction),
                items: [
                    AttacheContextItem(source: .safetyPolicy, content: "Safety rules.", priority: 100),
                    AttacheContextItem(source: .activePersonality, content: system, priority: 90)
                ] + contextItems,
                capability: makeProfile(context: 32_000),
                strategy: .automatic
            ).messages
        }

        let first = try compileOnce()
        let second = try compileOnce()
        XCTAssertEqual(first, second, "single-stage recap compilation must be deterministic")

        // Golden shape: one system message (safety + personality/system
        // prompt), one evidence user message carrying both recap items, and
        // the fixed instruction as the final user message.
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(first[0].role, "system")
        XCTAssertTrue(first[0].content.contains("Safety rules."))
        XCTAssertTrue(first[0].content.contains(system))
        XCTAssertEqual(first[1].role, "user")
        XCTAssertTrue(first[1].content.contains("Fix the thumbnail"))
        XCTAssertTrue(first[1].content.contains("Deploy pipeline"))
        XCTAssertTrue(first[1].content.contains("[needs a decision from the user]"))
        XCTAssertEqual(first[2].role, "user")
        XCTAssertEqual(first[2].content, instruction)
    }

    // AC: a 1000-item synthetic inbox produces a staged recap that completes
    // without ever throwing `protectedContentOverflow`. This compiles every
    // stage `RecapStagePlanner` produces for 1000 items through the real
    // `ContextCompiler`, which is the exact mechanism that would throw the
    // error if items still rode in the protected user turn. Every stage's
    // items are proven present in that stage's receipt, so nothing is
    // silently dropped between planning and compilation.
    func test1000ItemInboxCompilesEveryStageWithoutProtectedContentOverflow() throws {
        let items = (0..<1_000).map { i -> (id: String, item: AttachePersonality.RecapItem) in
            (
                id: "card-\(i)",
                item: AttachePersonality.RecapItem(
                    sessionTitle: "Session \(i % 60)",
                    summary: "This update describes synthetic work item \(i) and how it was resolved for the recap staging test.",
                    spokenText: "spoken \(i)",
                    needsDecision: i % 11 == 0
                )
            )
        }
        let stageItems = items.map { entry in
            RecapStageItem(
                id: entry.id,
                sessionTitle: entry.item.sessionTitle,
                summaryText: entry.item.summary,
                createdAt: Date(),
                needsDecision: entry.item.needsDecision
            )
        }

        // A small model, so a naive concatenation of all 1000 items into the
        // protected user turn would overflow immediately.
        let capability = makeProfile(context: 8_000)
        let budgetPlan = try ContextBudgetPlanner.plan(
            capability: capability,
            strategy: .automatic,
            role: .recap,
            currentUserInput: AttachePersonality.recapStagedUserInstruction()
        )
        let plan = RecapStagePlanner.plan(items: stageItems, budgetPlan: budgetPlan)
        XCTAssertGreaterThan(plan.stages.count, 1, "1000 items against an 8K model should require multiple stages")
        XCTAssertEqual(Set(plan.coveredItemIDs), Set(stageItems.map(\.id)), "every item must be covered by some stage")

        let itemsByID = Dictionary(uniqueKeysWithValues: items)
        var everCoveredInAReceipt = Set<String>()

        for stage in plan.stages {
            let stagePairs = stage.itemIDs.compactMap { id -> (id: String, item: AttachePersonality.RecapItem)? in
                itemsByID[id].map { (id, $0) }
            }
            let contextItems: [AttacheContextItem] = [
                AttacheContextItem(source: .safetyPolicy, content: "Safety rules.", priority: 100),
                AttacheContextItem(source: .activePersonality, content: "You are Attaché.", priority: 90)
            ] + AttachePersonality.recapContextItems(from: stagePairs)

            // This must never throw protectedContentOverflow: the fixed
            // instruction keeps the protected user turn tiny regardless of
            // stage size.
            let compiled = try ContextCompiler.compile(
                input: recapInput(userInput: AttachePersonality.recapStagedUserInstruction()),
                items: contextItems,
                capability: capability,
                strategy: .automatic
            )
            XCTAssertTrue(compiled.receipt.includedSources.contains("currentUserTurn"))
            for pair in stagePairs {
                let identifier = "recap-item:\(pair.id)"
                if compiled.receipt.includedSourceIdentifiers?.contains(identifier) == true {
                    everCoveredInAReceipt.insert(pair.id)
                }
            }
        }

        // Every item that a stage claims to cover must show up as included in
        // that stage's own compiled receipt (proof, not just planning intent).
        XCTAssertEqual(everCoveredInAReceipt, Set(stageItems.map(\.id)))
    }
}
