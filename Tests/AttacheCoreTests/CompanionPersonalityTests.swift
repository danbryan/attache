import AttacheCore
import XCTest

final class CompanionPersonalityTests: XCTestCase {
    func testMemoryContextUsesDurablePreferenceLines() {
        let memory = """
        # ignored heading
        - [preference, importance 0.90] The user wants concise spoken updates.
        - [routing, importance 0.85] Treat agent output as source material, not the companion voice.
        """

        let context = CompanionPersonality.memoryContext(from: memory)

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("Companion durable memory:") == true)
        XCTAssertTrue(context?.contains("The user wants concise spoken updates") == true)
        XCTAssertTrue(context?.contains("not proof that project files or tools were checked") == true)
        XCTAssertFalse(context?.contains("ignored heading") == true)
    }

    func testMemoryContextStartsEmptyWithoutSavedEntries() {
        let context = CompanionPersonality.memoryContext(from: "")

        XCTAssertNil(context)
    }

    func testPresentationPromptSeparatesSystemPersonaFromCodexOutput() {
        let event = NormalizedEvent(
            source: "codex",
            eventType: "assistant.completed",
            externalSessionID: "session-123",
            projectPath: "/tmp/example",
            title: "QBO update",
            text: "I posted 25 clear transactions and left 7 pending for the user to decide."
        )
        let memory = CompanionPersonality.memoryContext(from: "- [preference] Keep spoken updates brief.")

        let prompt = CompanionPersonality.presentationPrompt(
            for: event,
            memoryContext: memory
        )

        XCTAssertEqual(prompt.messages.count, 2)
        XCTAssertEqual(prompt.messages[0].role, "system")
        XCTAssertEqual(prompt.messages[1].role, "user")
        XCTAssertTrue(prompt.messages[0].content.contains("Keep spoken updates brief"))
        XCTAssertTrue(prompt.messages[0].content.contains("Do not read the agent response verbatim"))
        XCTAssertFalse(prompt.messages[0].content.contains("I posted 25 clear transactions"))
        XCTAssertTrue(prompt.messages[1].content.contains("I posted 25 clear transactions"))
        XCTAssertTrue(prompt.messages[1].content.contains("personalized"))
    }

    func testIdentityScaffoldingIsHiddenFromEditableDefaultProfile() {
        XCTAssertFalse(CompanionPersonality.defaultProfilePrompt.contains("You are Attaché"))

        let event = NormalizedEvent(
            source: "codex",
            eventType: "assistant.completed",
            title: "Short update",
            text: "Done."
        )

        let prompt = CompanionPersonality.presentationPrompt(
            for: event,
            profilePrompt: "Keep it calm and concise.",
            memoryContext: nil
        )

        XCTAssertTrue(prompt.messages[0].content.contains("You are Attaché"))
        XCTAssertTrue(prompt.messages[0].content.contains("Keep it calm and concise."))
    }

    func testPresentationPromptClipsLargeCodexOutput() {
        let event = NormalizedEvent(
            source: "codex",
            eventType: "assistant.completed",
            title: "Long update",
            text: String(repeating: "a", count: 40)
        )

        let prompt = CompanionPersonality.presentationPrompt(
            for: event,
            memoryContext: nil,
            maxCodexOutputCharacters: 10
        )

        XCTAssertEqual(prompt.rawOutputCharacterCount, 40)
        XCTAssertTrue(prompt.truncatedRawOutput)
        XCTAssertTrue(prompt.messages[1].content.contains("[Agent output truncated.]"))
    }

    func testFollowUpPromptAnswersUserWithSeparateContext() {
        let card = VoicemailCard(
            id: "card-1",
            sourceID: "source-1",
            sourceKind: SourceKind.codex.rawValue,
            sourceDisplayName: "Codex",
            sessionID: "session-row-1",
            externalSessionID: "session-123",
            projectPath: "/tmp/example",
            sessionTitle: "Build update",
            kind: .update,
            rawText: "I changed AppModel.swift and verified swift test.",
            summary: "Build update complete",
            spokenText: "The build update is in and tests passed.",
            status: .unread,
            createdAt: Date(),
            heardAt: nil,
            metadataJSON: "{}",
            durationMs: 0,
            alignment: nil
        )

        let prompt = CompanionPersonality.followUpPrompt(
            for: card,
            danQuestion: "What matters about the new flow?",
            memoryContext: CompanionPersonality.memoryContext(from: "- [preference] The user wants concise companion answers.")
        )

        XCTAssertEqual(prompt.messages.count, 2)
        XCTAssertEqual(prompt.messages[0].role, "system")
        XCTAssertEqual(prompt.messages[1].role, "user")
        XCTAssertTrue(prompt.messages[0].content.contains("Answer the user directly as Attaché"))
        XCTAssertTrue(prompt.messages[0].content.contains("Do not write to the agent"))
        XCTAssertTrue(prompt.messages[0].content.contains("Never imply that you sent"))
        XCTAssertFalse(prompt.messages[0].content.contains("I changed AppModel.swift"))
        XCTAssertTrue(prompt.messages[1].content.contains("What matters about the new flow?"))
        XCTAssertTrue(prompt.messages[1].content.contains("Treat the user's phrase as a question"))
        XCTAssertTrue(prompt.messages[1].content.contains("Do not send or draft a message to the agent"))
        XCTAssertTrue(prompt.messages[1].content.contains("I changed AppModel.swift"))
        XCTAssertTrue(prompt.messages[1].content.contains("Observed session: session-123"))
    }

    func testRecapPromptKeepsPersonaVoiceButMakesBrevityOverride() {
        let items = [
            CompanionPersonality.RecapItem(
                sessionTitle: "QBO cleanup",
                summary: "Posted 25 transactions, 7 need review",
                spokenText: "The books are mostly caught up.",
                needsDecision: true
            ),
            CompanionPersonality.RecapItem(
                sessionTitle: "Web build",
                summary: "CI is red on the web app",
                spokenText: "The web build failed in CI.",
                needsDecision: false
            )
        ]

        let prompt = CompanionPersonality.recapPrompt(
            items: items,
            profilePrompt: "Be extremely chatty and tell long stories.",
            memoryContext: CompanionPersonality.memoryContext(from: "- [preference] The user wants concise updates.")
        )

        XCTAssertEqual(prompt.messages.count, 2)
        XCTAssertEqual(prompt.messages[0].role, "system")
        XCTAssertEqual(prompt.messages[1].role, "user")
        // Persona voice is kept in the system prompt.
        XCTAssertTrue(prompt.messages[0].content.contains("Be extremely chatty and tell long stories."))
        XCTAssertTrue(prompt.messages[0].content.contains("The user wants concise updates"))
        // Length is dynamic (a scaled ceiling), not a fixed 2 to 4 sentences,
        // and brevity is written to override the personality's verbosity.
        XCTAssertFalse(prompt.messages[0].content.contains("2 to 4 sentences"))
        XCTAssertTrue(prompt.messages[0].content.contains("override any verbosity"))
        XCTAssertTrue(prompt.messages[0].content.contains("Cluster updates about the same thing"))
        XCTAssertTrue(prompt.messages[0].content.contains("save the user time without losing anything"))
        XCTAssertTrue(prompt.messages[0].content.contains("at most \(CompanionPersonality.recapSentenceCeiling(itemCount: items.count)) sentences"))
        // The already-condensed items feed the user prompt, decision flagged.
        XCTAssertTrue(prompt.messages[1].content.contains("QBO cleanup"))
        XCTAssertTrue(prompt.messages[1].content.contains("Posted 25 transactions, 7 need review"))
        XCTAssertTrue(prompt.messages[1].content.contains("needs a decision from the user"))
        XCTAssertTrue(prompt.messages[1].content.contains("Web build"))
    }

    func testRecapPromptFallsBackToSpokenTextWhenSummaryEmpty() {
        let items = [
            CompanionPersonality.RecapItem(
                sessionTitle: "Migration",
                summary: "   ",
                spokenText: "The database migration finished cleanly.",
                needsDecision: false
            )
        ]

        let prompt = CompanionPersonality.recapPrompt(items: items, memoryContext: nil)

        XCTAssertTrue(prompt.messages[1].content.contains("The database migration finished cleanly."))
        XCTAssertFalse(prompt.messages[1].content.contains("needs a decision"))
    }

    func testRecapSentenceCeilingScalesWithVolume() {
        // A couple of items stays terse; a big inbox earns a short paragraph
        // but never an essay, and the ceiling never shrinks as volume grows.
        XCTAssertEqual(CompanionPersonality.recapSentenceCeiling(itemCount: 1), 2)
        XCTAssertEqual(CompanionPersonality.recapSentenceCeiling(itemCount: 5), 3)
        XCTAssertEqual(CompanionPersonality.recapSentenceCeiling(itemCount: 27), 9)
        XCTAssertLessThanOrEqual(CompanionPersonality.recapSentenceCeiling(itemCount: 500), 9)
        let ceilings = [1, 3, 6, 12, 24, 50].map { CompanionPersonality.recapSentenceCeiling(itemCount: $0) }
        XCTAssertEqual(ceilings, ceilings.sorted())
    }

    func testRecapPromptScalesCeilingAndNamesSessionSpread() {
        let items = (0..<27).map { i in
            CompanionPersonality.RecapItem(
                sessionTitle: i < 20 ? "Launch readiness" : "Shell smoke",
                summary: "Update \(i)",
                spokenText: "Spoken \(i)",
                needsDecision: i == 0
            )
        }
        let system = CompanionPersonality.recapPrompt(items: items, memoryContext: nil).messages[0].content
        XCTAssertTrue(system.contains("27 waiting updates across 2 sessions"))
        XCTAssertTrue(system.contains("at most 9 sentences"))
    }

    func testStripDashesReplacesEmAndEnDashesWithCommas() {
        // The model sometimes ignores the no-em-dash instruction; the code strips
        // them deterministically so captions and speech never show the dash.
        XCTAssertEqual(CompanionPersonality.stripDashes("brew upgrade — verified end to end"), "brew upgrade, verified end to end")
        XCTAssertEqual(CompanionPersonality.stripDashes("red–blue"), "red, blue")
        XCTAssertEqual(CompanionPersonality.stripDashes("no dashes here"), "no dashes here")
        XCTAssertFalse(CompanionPersonality.stripDashes("a — b — c").contains("—"))
    }

    func testFollowUpPromptHandlesEllipticalSessionQuestions() {
        let card = VoicemailCard(
            id: "card-1",
            sourceID: "source-1",
            sourceKind: SourceKind.codex.rawValue,
            sourceDisplayName: "Codex",
            sessionID: "session-row-1",
            externalSessionID: "session-123",
            projectPath: "/tmp/books",
            sessionTitle: "e-books MCP server",
            kind: .update,
            rawText: "The session has been summarizing chapters in sequence.",
            summary: "Chapter summary complete",
            spokenText: "Recent companion history says the last response completed chapter 13.",
            status: .heard,
            createdAt: Date(),
            heardAt: nil,
            metadataJSON: "{}",
            durationMs: 0,
            alignment: nil
        )

        let prompt = CompanionPersonality.followUpPrompt(
            for: card,
            danQuestion: "what chapter is next?",
            memoryContext: nil
        )

        XCTAssertTrue(prompt.messages[0].content.contains("For short references like"))
        XCTAssertTrue(prompt.messages[0].content.contains("resolve the reference"))
        XCTAssertTrue(prompt.messages[1].content.contains("what chapter is next?"))
        XCTAssertTrue(prompt.messages[1].content.contains("summarizing chapters in sequence"))
        XCTAssertTrue(prompt.messages[1].content.contains("completed chapter 13"))
    }

    func testConversationPromptRoutesAgentInstructionThroughSendPolicy() {
        let prompt = CompanionPersonality.conversationSystemPrompt(
            memoryContext: nil,
            sessionTitle: "Codex smoke",
            sessionSourceName: "Codex",
            workingDirectory: "/tmp/smoke",
            latestSummary: "Ready",
            latestAgentReply: "Three improvements were made.",
            canStageAgentInstruction: true
        )

        XCTAssertTrue(prompt.contains("stage_agent_instruction"))
        XCTAssertTrue(prompt.contains("\"What did Codex say?\" is a question for you"))
        XCTAssertTrue(prompt.contains("\"Ask Codex what it changed\" is an explicit delegation"))
        XCTAssertTrue(prompt.contains("MUST call stage_agent_instruction"))
        XCTAssertTrue(prompt.contains("Do not substitute read_session_transcript"))
        XCTAssertTrue(prompt.contains("If the user names a different agent than the focused one"))
        XCTAssertTrue(prompt.contains("may confirm or may send directly"))
        XCTAssertTrue(prompt.contains("Never claim a send unless Attaché reports it"))
        XCTAssertTrue(prompt.contains("always set stage_agent_instruction's intended_agent argument"))
        XCTAssertTrue(prompt.contains("Never guess or omit intended_agent when a name was given"))
        XCTAssertTrue(prompt.contains("it never reroutes to a different agent"))
        XCTAssertTrue(prompt.contains("Focused agent: Codex / Codex smoke"))
        XCTAssertTrue(prompt.contains("Latest agent reply: Three improvements were made."))
        XCTAssertTrue(prompt.contains("Find an artifact's exact path from the transcript"))
    }

    func testConversationPromptForbidsAgentMessagingWhenToolUnavailable() {
        let prompt = CompanionPersonality.conversationSystemPrompt(
            memoryContext: nil,
            sessionTitle: nil,
            workingDirectory: nil,
            latestSummary: nil,
            canStageAgentInstruction: false
        )

        XCTAssertFalse(prompt.contains("stage_agent_instruction"))
        XCTAssertTrue(prompt.contains("Do not address, write to, or imply you can message the work agent"))
    }

    // MARK: - Watched sessions inventory (INF-239)

    func testWatchedSessionsBlockWordsEmptyCaseWhenNoOtherSessionsExist() {
        XCTAssertEqual(
            CompanionPersonality.watchedSessionsBlock([]),
            "No other sessions are being watched."
        )

        let now = Date()
        let onlyTheFocusedOne = CompanionPersonality.WatchedSessionSummary(
            sourceName: "Codex",
            title: "attache release prep",
            updatedAt: now,
            isFocused: true,
            isTwoWayEnabled: true
        )
        XCTAssertEqual(
            CompanionPersonality.watchedSessionsBlock([onlyTheFocusedOne], now: now),
            "No other sessions are being watched."
        )
    }

    func testWatchedSessionsBlockMarksFocusedAndTwoWayEnabledOnlyForFocusedEntry() {
        let now = Date()
        let focused = CompanionPersonality.WatchedSessionSummary(
            sourceName: "Claude Code",
            title: "Weekly Codex Improvement Review",
            updatedAt: now.addingTimeInterval(-120),
            isFocused: true,
            isTwoWayEnabled: true
        )
        let other = CompanionPersonality.WatchedSessionSummary(
            sourceName: "Codex",
            title: "attache release prep",
            updatedAt: now.addingTimeInterval(-3 * 3600),
            isFocused: false,
            isTwoWayEnabled: true // should never surface: two-way is focused-only per spec
        )

        let block = CompanionPersonality.watchedSessionsBlock([focused, other], now: now)

        let expected = """
        Watched sessions:
        - Claude Code / "Weekly Codex Improvement Review" (focused, two-way enabled, active 2m ago)
        - Codex / "attache release prep" (active 3h ago)
        """
        XCTAssertEqual(block, expected)
    }

    func testWatchedSessionsBlockCapsAtSixMostRecentFirst() {
        let now = Date()
        // 8 sessions, oldest first; the two oldest should be dropped by the cap.
        let sessions = (0..<8).map { index -> CompanionPersonality.WatchedSessionSummary in
            CompanionPersonality.WatchedSessionSummary(
                sourceName: "Codex",
                title: "session \(index)",
                updatedAt: now.addingTimeInterval(-Double(8 - index) * 3600),
                isFocused: false,
                isTwoWayEnabled: false
            )
        }

        let block = CompanionPersonality.watchedSessionsBlock(sessions, now: now)
        let lines = block.split(separator: "\n")

        XCTAssertEqual(lines.first, "Watched sessions:")
        XCTAssertEqual(lines.count, 1 + 6, "expected the header plus exactly 6 capped entries")
        // Most recent first: "session 7" (1h ago) leads, "session 2" (6h ago) is last kept.
        XCTAssertTrue(lines[1].contains("session 7"))
        XCTAssertTrue(lines[6].contains("session 2"))
        XCTAssertFalse(block.contains("session 1\""))
        XCTAssertFalse(block.contains("session 0\""))
    }

    func testWatchedSessionsBlockFallsBackToUntitledForBlankTitle() {
        let now = Date()
        let sessions = [
            CompanionPersonality.WatchedSessionSummary(
                sourceName: "Codex", title: "  ", updatedAt: now, isFocused: false, isTwoWayEnabled: false
            ),
            CompanionPersonality.WatchedSessionSummary(
                sourceName: "Codex", title: "named", updatedAt: now.addingTimeInterval(-60), isFocused: false, isTwoWayEnabled: false
            )
        ]

        let block = CompanionPersonality.watchedSessionsBlock(sessions, now: now)

        XCTAssertTrue(block.contains("Codex / \"Untitled session\""))
    }

    func testConversationSystemPromptEmbedsWatchedSessionsBlock() {
        let now = Date()
        let watched = [
            CompanionPersonality.WatchedSessionSummary(
                sourceName: "Claude Code",
                title: "Weekly Codex Improvement Review",
                updatedAt: now,
                isFocused: true,
                isTwoWayEnabled: true
            ),
            CompanionPersonality.WatchedSessionSummary(
                sourceName: "Codex",
                title: "attache release prep",
                updatedAt: now.addingTimeInterval(-3 * 3600),
                isFocused: false,
                isTwoWayEnabled: false
            )
        ]

        let prompt = CompanionPersonality.conversationSystemPrompt(
            memoryContext: nil,
            sessionTitle: "Weekly Codex Improvement Review",
            sessionSourceName: "Claude Code",
            workingDirectory: nil,
            latestSummary: nil,
            canStageAgentInstruction: true,
            watchedSessions: watched
        )

        XCTAssertTrue(prompt.contains("Watched sessions:"))
        XCTAssertTrue(prompt.contains("- Claude Code / \"Weekly Codex Improvement Review\" (focused, two-way enabled, active just now)"))
        XCTAssertTrue(prompt.contains("- Codex / \"attache release prep\" (active 3h ago)"))
    }

    func testConversationSystemPromptDefaultsToNoOtherSessionsWatched() {
        let prompt = CompanionPersonality.conversationSystemPrompt(
            memoryContext: nil,
            sessionTitle: nil,
            workingDirectory: nil,
            latestSummary: nil,
            canStageAgentInstruction: false
        )

        XCTAssertTrue(prompt.contains("No other sessions are being watched."))
    }
}
