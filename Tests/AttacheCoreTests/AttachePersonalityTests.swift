import AttacheCore
import XCTest

final class AttachePersonalityTests: XCTestCase {
    func testMemoryContextUsesDurablePreferenceLines() {
        let memory = """
        # ignored heading
        - [preference, importance 0.90] The user wants concise spoken updates.
        - [routing, importance 0.85] Treat agent output as source material, not the attache voice.
        """

        let context = AttachePersonality.memoryContext(from: memory)

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("Attache durable memory:") == true)
        XCTAssertTrue(context?.contains("The user wants concise spoken updates") == true)
        XCTAssertTrue(context?.contains("not proof that project files or tools were checked") == true)
        XCTAssertFalse(context?.contains("ignored heading") == true)
    }

    func testMemoryContextStartsEmptyWithoutSavedEntries() {
        let context = AttachePersonality.memoryContext(from: "")

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
        let memory = AttachePersonality.memoryContext(from: "- [preference] Keep spoken updates brief.")

        let prompt = AttachePersonality.presentationPrompt(
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
        XCTAssertFalse(AttachePersonality.defaultProfilePrompt.contains("You are Attaché"))

        let event = NormalizedEvent(
            source: "codex",
            eventType: "assistant.completed",
            title: "Short update",
            text: "Done."
        )

        let prompt = AttachePersonality.presentationPrompt(
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

        let prompt = AttachePersonality.presentationPrompt(
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

        let prompt = AttachePersonality.followUpPrompt(
            for: card,
            danQuestion: "What matters about the new flow?",
            memoryContext: AttachePersonality.memoryContext(from: "- [preference] The user wants concise attache answers.")
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
            AttachePersonality.RecapItem(
                sessionTitle: "QBO cleanup",
                summary: "Posted 25 transactions, 7 need review",
                spokenText: "The books are mostly caught up.",
                needsDecision: true
            ),
            AttachePersonality.RecapItem(
                sessionTitle: "Web build",
                summary: "CI is red on the web app",
                spokenText: "The web build failed in CI.",
                needsDecision: false
            )
        ]

        let prompt = AttachePersonality.recapPrompt(
            items: items,
            profilePrompt: "Be extremely chatty and tell long stories.",
            memoryContext: AttachePersonality.memoryContext(from: "- [preference] The user wants concise updates.")
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
        XCTAssertTrue(prompt.messages[0].content.contains("at most \(AttachePersonality.recapSentenceCeiling(itemCount: items.count)) sentences"))
        // The already-condensed items feed the user prompt, decision flagged.
        XCTAssertTrue(prompt.messages[1].content.contains("QBO cleanup"))
        XCTAssertTrue(prompt.messages[1].content.contains("Posted 25 transactions, 7 need review"))
        XCTAssertTrue(prompt.messages[1].content.contains("needs a decision from the user"))
        XCTAssertTrue(prompt.messages[1].content.contains("Web build"))
    }

    func testRecapPromptFallsBackToSpokenTextWhenSummaryEmpty() {
        let items = [
            AttachePersonality.RecapItem(
                sessionTitle: "Migration",
                summary: "   ",
                spokenText: "The database migration finished cleanly.",
                needsDecision: false
            )
        ]

        let prompt = AttachePersonality.recapPrompt(items: items, memoryContext: nil)

        XCTAssertTrue(prompt.messages[1].content.contains("The database migration finished cleanly."))
        XCTAssertFalse(prompt.messages[1].content.contains("needs a decision"))
    }

    func testRecapSentenceCeilingScalesWithVolume() {
        // A couple of items stays terse; a big inbox earns a short paragraph
        // but never an essay, and the ceiling never shrinks as volume grows.
        XCTAssertEqual(AttachePersonality.recapSentenceCeiling(itemCount: 1), 2)
        XCTAssertEqual(AttachePersonality.recapSentenceCeiling(itemCount: 5), 3)
        XCTAssertEqual(AttachePersonality.recapSentenceCeiling(itemCount: 27), 9)
        XCTAssertLessThanOrEqual(AttachePersonality.recapSentenceCeiling(itemCount: 500), 9)
        let ceilings = [1, 3, 6, 12, 24, 50].map { AttachePersonality.recapSentenceCeiling(itemCount: $0) }
        XCTAssertEqual(ceilings, ceilings.sorted())
    }

    func testRecapPromptScalesCeilingAndNamesSessionSpread() {
        let items = (0..<27).map { i in
            AttachePersonality.RecapItem(
                sessionTitle: i < 20 ? "Launch readiness" : "Shell smoke",
                summary: "Update \(i)",
                spokenText: "Spoken \(i)",
                needsDecision: i == 0
            )
        }
        let system = AttachePersonality.recapPrompt(items: items, memoryContext: nil).messages[0].content
        XCTAssertTrue(system.contains("27 waiting updates across 2 sessions"))
        XCTAssertTrue(system.contains("at most 9 sentences"))
    }

    func testStripDashesReplacesEmAndEnDashesWithCommas() {
        // The model sometimes ignores the no-em-dash instruction; the code strips
        // them deterministically so captions and speech never show the dash.
        XCTAssertEqual(AttachePersonality.stripDashes("brew upgrade — verified end to end"), "brew upgrade, verified end to end")
        XCTAssertEqual(AttachePersonality.stripDashes("red–blue"), "red, blue")
        XCTAssertEqual(AttachePersonality.stripDashes("no dashes here"), "no dashes here")
        XCTAssertFalse(AttachePersonality.stripDashes("a — b — c").contains("—"))
    }

    func testSanitizeSpokenTextReplacesURLsMidSentence() {
        let input = "The notes are at https://notion.so/a/really/long/path and the rest is fine."
        let out = AttachePersonality.sanitizeSpokenText(input)
        XCTAssertEqual(out, "The notes are at a link and the rest is fine.")
        XCTAssertFalse(out.contains("http"))
        XCTAssertFalse(out.contains("notion"))
    }

    func testSanitizeSpokenTextHandlesURLInParensAndKeepsPunctuation() {
        // A markdown-ish parenthesized link keeps its parens and the sentence
        // keeps its closing period.
        let input = "See the doc (https://example.com/x). Thanks."
        let out = AttachePersonality.sanitizeSpokenText(input)
        XCTAssertEqual(out, "See the doc (a link). Thanks.")

        // An article the writer placed in front collapses cleanly.
        XCTAssertEqual(
            AttachePersonality.sanitizeSpokenText("open the https://example.com now"),
            "open the link now"
        )
    }

    func testSanitizeSpokenTextReplacesShaAndUUID() {
        let sha = "d34db33fcafebabe0123456789abcdef01234567" // 40 hex chars
        XCTAssertEqual(
            AttachePersonality.sanitizeSpokenText("commit \(sha) landed"),
            "commit a checksum landed"
        )
        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        XCTAssertEqual(
            AttachePersonality.sanitizeSpokenText("session \(uuid) started"),
            "session an ID started"
        )
    }

    func testSanitizeSpokenTextIsIdempotentAndStripsDashes() {
        let input = "Grab it at https://a.b/c — the sha is d34db33fcafebabe0123456789abcdef01234567."
        let once = AttachePersonality.sanitizeSpokenText(input)
        let twice = AttachePersonality.sanitizeSpokenText(once)
        XCTAssertEqual(once, twice)
        XCTAssertFalse(once.contains("—"))
        XCTAssertFalse(once.contains("http"))
        XCTAssertTrue(once.contains("a checksum"))
    }

    func testSanitizeSpokenTextLeavesOrdinaryTextAndShortIDsAlone() {
        let plain = "Posted 25 transactions and left 7 pending for review."
        XCTAssertEqual(AttachePersonality.sanitizeSpokenText(plain), plain)
        // A short id and a file path are the prompt's job, not this pass.
        let kept = "See file src/App.swift for ticket INF-347."
        XCTAssertEqual(AttachePersonality.sanitizeSpokenText(kept), kept)
    }

    func testTrimSpokenIntroductionTrimsAtSentenceBoundaryWithinBudget() {
        let long = "Howdy, my name's Colt and I ride point on your herd. " +
            "I count the strays, mend the fences, and drive the whole outfit through the gate at first light every single day."
        let trimmed = AttachePersonality.trimSpokenIntroduction(long, wordBudget: 22)
        XCTAssertEqual(trimmed, "Howdy, my name's Colt and I ride point on your herd.")
        XCTAssertLessThanOrEqual(trimmed.split(whereSeparator: { $0.isWhitespace }).count, 22)
        // The trim never splits a word: the last kept token is whole.
        XCTAssertTrue(trimmed.hasSuffix("herd."))
    }

    func testTrimSpokenIntroductionIsIdempotentAndLeavesShortTakes() {
        let short = "Hi, I'm Echo, glad to help."
        XCTAssertEqual(AttachePersonality.trimSpokenIntroduction(short, wordBudget: 22), short)
        let long = "Howdy, my name's Colt and I ride point on your herd. And then some more words here entirely."
        let once = AttachePersonality.trimSpokenIntroduction(long, wordBudget: 22)
        XCTAssertEqual(AttachePersonality.trimSpokenIntroduction(once, wordBudget: 22), once)
    }

    func testTrimSpokenIntroductionClipsFirstOverlongSentenceOnWholeWords() {
        let runOn = "My name is Colt and I ride point and mend fences and count the herd and drive them through the gate and tip my hat at sundown and ride out again"
        let trimmed = AttachePersonality.trimSpokenIntroduction(runOn, wordBudget: 22)
        XCTAssertLessThanOrEqual(trimmed.split(whereSeparator: { $0.isWhitespace }).count, 22)
        XCTAssertTrue(trimmed.hasSuffix("."))
        // Clipped on a whole-word boundary: no partial trailing token.
        XCTAssertFalse(trimmed.dropLast().hasSuffix(" "))
        XCTAssertTrue(runOn.hasPrefix(String(trimmed.dropLast())))
    }

    func testPresentationPromptForbidsSpeakingLinksEvenAsMainPoint() {
        // The "unless they are the main point" escape hatch is gone: a link or
        // hash is always described, never spoken, even when it is the point.
        let event = NormalizedEvent(
            source: "codex",
            eventType: "assistant.completed",
            title: "Link",
            text: "Here is the URL."
        )
        let prompt = AttachePersonality.presentationPrompt(for: event, memoryContext: nil)
        let system = prompt.messages[0].content
        XCTAssertFalse(system.contains("unless they are the main point"))
        XCTAssertTrue(system.contains("never speak it"))
    }

    func testDefaultProfilePromptNeverReadsLongTechnicalStrings() {
        // The prompt is a wrapped multi-line literal, so assert on fragments that
        // do not cross a line break.
        let prompt = AttachePersonality.defaultProfilePrompt
        XCTAssertTrue(prompt.contains("Long technical strings"))
        XCTAssertTrue(prompt.contains("are never read out loud"))
        XCTAssertTrue(prompt.contains("describe them at a high"))
    }

    func testAuditionIntroductionPromptAsksForNamedIntroductionWithinBudget() {
        let prompt = AttachePersonality.auditionIntroductionPrompt(
            personalityPrompt: "You're Colt, always open with howdy."
        )
        // The personality's own prompt leads the phrasing.
        XCTAssertTrue(prompt.contains("You're Colt, always open with howdy."))
        XCTAssertTrue(prompt.lowercased().contains("introduce yourself"))
        XCTAssertTrue(prompt.contains("say your name"))
        XCTAssertTrue(prompt.contains("this personality's own wording lead"))
        // The word ceiling (spoken-duration budget) is instructed in the prompt.
        XCTAssertTrue(prompt.contains("22 words"))
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
            spokenText: "Recent attache history says the last response completed chapter 13.",
            status: .heard,
            createdAt: Date(),
            heardAt: nil,
            metadataJSON: "{}",
            durationMs: 0,
            alignment: nil
        )

        let prompt = AttachePersonality.followUpPrompt(
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
        let prompt = AttachePersonality.conversationSystemPrompt(
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
        XCTAssertTrue(prompt.contains("always opens a native confirmation"))
        XCTAssertTrue(prompt.contains("Never claim a send unless Attaché reports it"))
        XCTAssertTrue(prompt.contains("always set stage_agent_instruction's intended_agent argument"))
        XCTAssertTrue(prompt.contains("Never guess or omit intended_agent when a name was given"))
        XCTAssertTrue(prompt.contains("it never reroutes to a different agent"))
        XCTAssertTrue(prompt.contains("Focused agent: Codex / Codex smoke"))
        XCTAssertTrue(prompt.contains("Latest agent reply: Three improvements were made."))
        XCTAssertTrue(prompt.contains("Find an artifact's exact path from the transcript"))
        XCTAssertTrue(prompt.contains("blocked, failed, or expired"))
        XCTAssertTrue(prompt.contains("Never say a send succeeded unless Attaché actually reported that it did"))
        XCTAssertTrue(prompt.contains("Never invent a retry, workaround, or recovery option that was not reported to you"))
    }

    func testConversationPromptForbidsAgentMessagingWhenToolUnavailable() {
        let prompt = AttachePersonality.conversationSystemPrompt(
            memoryContext: nil,
            sessionTitle: nil,
            workingDirectory: nil,
            latestSummary: nil,
            canStageAgentInstruction: false
        )

        XCTAssertFalse(prompt.contains("stage_agent_instruction"))
        XCTAssertFalse(prompt.contains("read_session_transcript"))
        XCTAssertFalse(prompt.contains("list_working_directory"))
        XCTAssertFalse(prompt.contains("read_file"))
        XCTAssertFalse(prompt.contains("rename_session"))
        XCTAssertTrue(prompt.contains("Do not address, write to, or imply you can message the work agent"))
        XCTAssertTrue(prompt.contains("No work session is focused"))
        XCTAssertTrue(prompt.contains("no work-session context"))
    }

    func testContextFreeConversationDropsStraySessionFieldsAndPrivileges() {
        let prompt = AttachePersonality.conversationSystemPrompt(
            memoryContext: nil,
            sessionTitle: nil,
            sessionSourceName: "Codex",
            workingDirectory: "/private/should-not-leak",
            latestSummary: "SECRET SUMMARY",
            latestAgentReply: "SECRET AGENT REPLY",
            canStageAgentInstruction: true
        )

        XCTAssertFalse(prompt.contains("Codex"))
        XCTAssertFalse(prompt.contains("/private/should-not-leak"))
        XCTAssertFalse(prompt.contains("SECRET SUMMARY"))
        XCTAssertFalse(prompt.contains("SECRET AGENT REPLY"))
        XCTAssertFalse(prompt.contains("stage_agent_instruction"))
        XCTAssertFalse(prompt.contains("read_session_transcript"))
        XCTAssertTrue(prompt.contains("Do not infer one from recency, watched sessions, a selected voicemail, conversation history, or other app activity"))
    }

    // MARK: - Memory proposal tool availability

    /// The prompt must name propose_memory in every branch where the tool is
    /// offered, including the context-free no-focused-session branch, and must
    /// carry the explicit-only capture rule plus the no-narration rule: the
    /// app's UI confirms saves, so the reply stays natural and in character.
    func testConversationPromptNamesMemoryToolInEveryBranchWhenAvailable() {
        let focusedWithStaging = AttachePersonality.conversationSystemPrompt(
            memoryContext: nil,
            sessionTitle: "Codex smoke",
            sessionSourceName: "Codex",
            workingDirectory: "/tmp/smoke",
            latestSummary: "Ready",
            canStageAgentInstruction: true,
            canProposeMemory: true
        )
        let focusedReadOnly = AttachePersonality.conversationSystemPrompt(
            memoryContext: nil,
            sessionTitle: "Codex smoke",
            sessionSourceName: "Codex",
            workingDirectory: "/tmp/smoke",
            latestSummary: "Ready",
            canStageAgentInstruction: false,
            canProposeMemory: true
        )
        let contextFree = AttachePersonality.conversationSystemPrompt(
            memoryContext: nil,
            sessionTitle: nil,
            workingDirectory: nil,
            latestSummary: nil,
            canStageAgentInstruction: false,
            canProposeMemory: true
        )

        for prompt in [focusedWithStaging, focusedReadOnly, contextFree] {
            // Explicit-only capture: only an explicit ask triggers the tool,
            // and nothing is volunteered for facts shared in passing.
            XCTAssertTrue(prompt.contains("Call propose_memory ONLY when the user explicitly asks"))
            XCTAssertTrue(prompt.contains("you MUST call it then"))
            XCTAssertTrue(prompt.contains("Never volunteer it for details shared in passing"))
            XCTAssertTrue(prompt.contains("is not a request to remember it"))
            XCTAssertTrue(prompt.contains("State the fact plainly and faithfully as the statement"))
            XCTAssertTrue(prompt.contains("correcting obvious transcription garbles"))
            XCTAssertTrue(prompt.contains("A spoken acknowledgment alone saves nothing"))
            // Scoping: conversation saves belong to this Attaché; all-Attaché
            // memories are typed in Settings.
            XCTAssertTrue(prompt.contains("The save goes to this Attaché's own memory"))
            XCTAssertTrue(prompt.contains("memories for every Attaché are typed in Settings > Memory"))
            // Affirmation-of-offer consent: an accepted offer can never be
            // refused, and the user is never asked to re-say a visible fact.
            XCTAssertTrue(prompt.contains("affirming your own offer to remember"))
            XCTAssertTrue(prompt.contains("the fact to save is the one from the earlier turn"))
            XCTAssertTrue(prompt.contains("never offer and then refuse"))
            XCTAssertTrue(prompt.contains("never ask the user to repeat a fact you can already see in this conversation"))
            // Gap-fill consent: supplying a fact you just said you lacked is
            // an explicit ask.
            XCTAssertTrue(prompt.contains("you do not know or lack a fact and they reply by supplying it"))
            XCTAssertTrue(prompt.contains("treat it as an explicit ask and call propose_memory"))
            // No narration: the UI chip confirms saves, the reply stays natural.
            XCTAssertTrue(prompt.contains("Do not narrate the save mechanics"))
            XCTAssertTrue(prompt.contains("Attaché's own UI confirms every save"))
            XCTAssertTrue(prompt.contains("greet a new name, react to their news, answer what they asked"))
            XCTAssertTrue(prompt.contains("Never claim a memory was saved unless the tool reported it"))
            // Banned implied-persistence phrases without a reported save.
            XCTAssertTrue(prompt.contains("I'll keep that in mind"))
            XCTAssertTrue(prompt.contains("any phrasing that implies persistence unless the tool reported a save this turn"))
            XCTAssertTrue(prompt.contains("either save it or speak without implying memory"))
            // A validator decline is final and relayed briefly; the retired
            // retry-with-exact-words instruction is gone.
            XCTAssertTrue(prompt.contains("that it can't be saved and why"))
            XCTAssertFalse(prompt.contains("retry once"))
            XCTAssertFalse(prompt.contains("exact words the user spoke"))
            XCTAssertFalse(prompt.contains("You cannot save memories in this conversation"))
        }

        // The context-free branch keeps its honest session-tool disclaimer,
        // which names only the tools that are genuinely absent, while still
        // offering the memory tool.
        XCTAssertTrue(contextFree.contains("No work-session, transcript, project-file, rename, or agent-send tools are available in this conversation."))
        XCTAssertTrue(contextFree.contains("Tools available: propose_memory"))
        XCTAssertFalse(contextFree.contains("read_session_transcript"))
        XCTAssertFalse(contextFree.contains("stage_agent_instruction"))
    }

    /// When the tool is not offered (Off mode or a private call), the prompt
    /// must not mention it and must tell the model to say plainly that nothing
    /// will be saved instead of fake-acknowledging a remember request.
    func testConversationPromptNeverNamesMemoryToolWhenUnavailable() {
        let focused = AttachePersonality.conversationSystemPrompt(
            memoryContext: nil,
            sessionTitle: "Codex smoke",
            sessionSourceName: "Codex",
            workingDirectory: "/tmp/smoke",
            latestSummary: "Ready",
            canStageAgentInstruction: true,
            canProposeMemory: false
        )
        let contextFree = AttachePersonality.conversationSystemPrompt(
            memoryContext: nil,
            sessionTitle: nil,
            workingDirectory: nil,
            latestSummary: nil,
            canStageAgentInstruction: false,
            canProposeMemory: false
        )
        let defaulted = AttachePersonality.conversationSystemPrompt(
            memoryContext: nil,
            sessionTitle: nil,
            workingDirectory: nil,
            latestSummary: nil
        )

        for prompt in [focused, contextFree, defaulted] {
            XCTAssertFalse(prompt.contains("propose_memory"))
            XCTAssertTrue(prompt.contains("You cannot save memories in this conversation: remembering is off or this is a private call."))
            XCTAssertTrue(prompt.contains("say plainly that nothing will be saved right now; never imply you will remember it"))
        }
    }

    // MARK: - Error-behavior guidance for blocked/failed/expired sends (INF-252)

    /// The error-behavior block explains how to relay a blocked/failed/expired
    /// send; that can matter in a conversation even when this turn's tool set
    /// doesn't include stage_agent_instruction (e.g. a status about an earlier
    /// send, or a focus change mid-call), so it must not be gated on
    /// canStageAgentInstruction like the agent-instruction-only lines are.
    func testErrorBehaviorBlockIsPresentRegardlessOfAgentInstructionToolAvailability() {
        let withTool = AttachePersonality.conversationSystemPrompt(
            memoryContext: nil,
            sessionTitle: "Codex smoke",
            sessionSourceName: "Codex",
            workingDirectory: "/tmp/smoke",
            latestSummary: "Ready",
            canStageAgentInstruction: true
        )
        let withoutTool = AttachePersonality.conversationSystemPrompt(
            memoryContext: nil,
            sessionTitle: nil,
            workingDirectory: nil,
            latestSummary: nil,
            canStageAgentInstruction: false
        )

        for prompt in [withTool, withoutTool] {
            XCTAssertTrue(prompt.contains("blocked, failed, or expired"))
            XCTAssertTrue(prompt.contains("say plainly what happened and the one next step"))
            XCTAssertTrue(prompt.contains("Never say a send succeeded unless Attaché actually reported that it did"))
            XCTAssertTrue(prompt.contains("Never invent a retry, workaround, or recovery option that was not reported to you"))
        }
    }

    // MARK: - T5: "another take" re-narration engine

    private func anotherTakeParts(_ prompt: AttachePresentationPrompt) -> (system: String, user: String) {
        let system = prompt.messages.first { $0.role == "system" }?.content ?? ""
        let user = prompt.messages.first { $0.role == "user" }?.content ?? ""
        return (system, user)
    }

    func testAnotherTakeReferencesPriorTakeAsABriefNod() {
        let prompt = AttachePersonality.anotherTakePrompt(
            sourceText: "Deploy finished; two checks are red.",
            priorTake: "The herd's mostly through the gate, two strays left.",
            priorPersonalityName: "Cowboy",
            targetProfilePrompt: "You are precise and calm.",
            memoryContext: nil
        )
        let (system, user) = anotherTakeParts(prompt)
        XCTAssertTrue(system.contains("Cowboy"))
        XCTAssertTrue(user.contains("The herd's mostly through the gate, two strays left."))
        XCTAssertTrue(system.lowercased().contains("one short beat"))
        XCTAssertTrue(system.lowercased().contains("do not repeat"))
    }

    func testAnotherTakeEnforcesDomainAgnosticPhrasing() {
        let prompt = AttachePersonality.anotherTakePrompt(
            sourceText: "x", priorTake: "y", priorPersonalityName: "Explainer",
            targetProfilePrompt: "Be curious.", memoryContext: nil
        )
        let system = anotherTakeParts(prompt).system.lowercased()
        XCTAssertTrue(system.contains("any profession"))
        XCTAssertTrue(system.contains("never assume software"))
    }

    func testAnotherTakeForbidsEmDashesAndStripDashesRemovesThem() {
        let prompt = AttachePersonality.anotherTakePrompt(
            sourceText: "x", priorTake: "y", priorPersonalityName: "Big Picture",
            targetProfilePrompt: "Be visionary.", memoryContext: nil
        )
        XCTAssertTrue(anotherTakeParts(prompt).system.lowercased().contains("never use em dashes"))
        XCTAssertEqual(
            AttachePersonality.stripDashes("We shipped it — finally."),
            "We shipped it, finally."
        )
    }

    func testAnotherTakeSentenceCeilingScalesWithLength() {
        XCTAssertEqual(AttachePersonality.anotherTakeSentenceCeiling(sourceCharacters: 50), 2)
        XCTAssertEqual(AttachePersonality.anotherTakeSentenceCeiling(sourceCharacters: 800), 3)
        XCTAssertEqual(AttachePersonality.anotherTakeSentenceCeiling(sourceCharacters: 3000), 4)
        XCTAssertEqual(AttachePersonality.anotherTakeSentenceCeiling(sourceCharacters: 9000), 5)
        let shortPrompt = AttachePersonality.anotherTakePrompt(
            sourceText: String(repeating: "a", count: 50), priorTake: "",
            priorPersonalityName: "X", targetProfilePrompt: "Y", memoryContext: nil
        )
        let longPrompt = AttachePersonality.anotherTakePrompt(
            sourceText: String(repeating: "a", count: 9000), priorTake: "",
            priorPersonalityName: "X", targetProfilePrompt: "Y", memoryContext: nil
        )
        XCTAssertTrue(anotherTakeParts(shortPrompt).system.contains("at most 2 sentences"))
        XCTAssertTrue(anotherTakeParts(longPrompt).system.contains("at most 5 sentences"))
    }

    func testAnotherTakeIsDeterministic() {
        func make() -> AttachePresentationPrompt {
            AttachePersonality.anotherTakePrompt(
                sourceText: "same", priorTake: "prior", priorPersonalityName: "A",
                targetProfilePrompt: "B", memoryContext: "mem"
            )
        }
        XCTAssertEqual(make(), make())
    }

    func testAnotherTakeUsesCardSummaryFormatForFiling() {
        let prompt = AttachePersonality.anotherTakePrompt(
            sourceText: "s", priorTake: "p", priorPersonalityName: "A",
            targetProfilePrompt: "B", memoryContext: nil
        )
        XCTAssertTrue(anotherTakeParts(prompt).system.contains("CARD_SUMMARY:"))
    }

    func testAnotherTakeHandlesMissingPriorNameGracefully() {
        let prompt = AttachePersonality.anotherTakePrompt(
            sourceText: "s", priorTake: "p", priorPersonalityName: "   ",
            targetProfilePrompt: "B", memoryContext: nil
        )
        XCTAssertTrue(anotherTakeParts(prompt).system.contains("another personality"))
    }
}
