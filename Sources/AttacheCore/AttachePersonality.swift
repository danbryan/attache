import Foundation

public struct AttacheChatMessage: Equatable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct AttachePresentationPrompt: Equatable {
    public var messages: [AttacheChatMessage]
    public var memoryContext: String?
    public var rawOutputCharacterCount: Int
    public var truncatedRawOutput: Bool

    public init(
        messages: [AttacheChatMessage],
        memoryContext: String?,
        rawOutputCharacterCount: Int,
        truncatedRawOutput: Bool
    ) {
        self.messages = messages
        self.memoryContext = memoryContext
        self.rawOutputCharacterCount = rawOutputCharacterCount
        self.truncatedRawOutput = truncatedRawOutput
    }
}

public struct AttacheFollowUpPrompt: Equatable {
    public var messages: [AttacheChatMessage]
    public var memoryContext: String?
    public var rawContextCharacterCount: Int
    public var truncatedRawContext: Bool

    public init(
        messages: [AttacheChatMessage],
        memoryContext: String?,
        rawContextCharacterCount: Int,
        truncatedRawContext: Bool
    ) {
        self.messages = messages
        self.memoryContext = memoryContext
        self.rawContextCharacterCount = rawContextCharacterCount
        self.truncatedRawContext = truncatedRawContext
    }
}

public enum AttachePersonality {
    public static let maxMemoryContentCharacters = 800
    public static let maxMemoryContextCharacters = 2_400

    private static let attacheIdentityPrompt = """
    You are Attaché, a local attache assistant for the person using this app.

    You are one attache, not a stack of separate bots. You are not the agent
    doing the work, and you do not pretend to be any model or provider. Agent
    sessions are work sources you observe. Your job is to translate raw agent
    output into a personalized spoken update for the user.
    """

    public static let defaultProfilePrompt = """
    Talk like a close peer: natural, brief, warm, and direct. A little wit is
    fine, but stay useful. Do not be bratty, mean, jealous, possessive,
    suggestive, or performatively edgy.

    When the user is working with coding agents, local LLMs, operations, code, or
    project context, become a practical coworker. Tell them what matters: what
    changed, what was confirmed, what is still uncertain if it affects the
    decision, and the next useful action.

    Do not bury the user in implementation detail unless the character prompt asks
    for it. Do not claim something is confirmed unless the provided agent output
    says it was verified with actual tool output, a file, browser state, or a
    connected service. If evidence is partial, say what is known and what still
    needs checking.

    Durable memory: when a memory block is provided, use it quietly for tone,
    routing, and user preferences. Do not say you looked up memory unless the
    user asks.

    For spoken responses, optimize for listenability: short sentences, clear
    transitions, and no giant lists. Give the headline first, then the key
    points. The output will be read aloud and captioned.

    Expression hygiene: do not output private stage directions, parenthetical
    acting notes, or asterisk-only process notes. Never use em-dashes; write
    with commas, periods, or parentheses instead.
    """

    public static let defaultMemoryFileText = """
    # Attaché Memory
    # Lines beginning with '-' are injected into the Attaché's presentation model.
    # Keep this file to durable preferences, routing rules, and tone guidance.
    """

    public static func memoryContext(from memoryText: String?) -> String? {
        let entries = parsedMemoryEntries(from: memoryText)
        guard !entries.isEmpty else { return nil }

        var lines = [
            "Attache durable memory:",
            "- These are persistent memories for this assistant, not proof that project files or tools were checked.",
            "- Use them when relevant to tone, routing, or user preferences. Do not mention memory lookup unless the user asks.",
            "- Relevant saved memories:"
        ]

        for entry in entries {
            let candidate = "  - \(entry)"
            let next = (lines + [candidate]).joined(separator: "\n")
            if next.count > maxMemoryContextCharacters {
                lines.append("  - [truncated]")
                break
            }
            lines.append(candidate)
        }

        return lines.joined(separator: "\n")
    }

    public static func parsedMemoryEntries(from memoryText: String?) -> [String] {
        let text = (memoryText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? memoryText ?? ""
            : defaultMemoryFileText

        return text
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !trimmed.hasPrefix("#"),
                      !trimmed.hasPrefix("//") else {
                    return nil
                }

                let stripped: String
                if trimmed.hasPrefix("- ") {
                    stripped = String(trimmed.dropFirst(2))
                } else if trimmed.hasPrefix("* ") {
                    stripped = String(trimmed.dropFirst(2))
                } else {
                    stripped = trimmed
                }

                return cleanMemoryContent(stripped)
            }
    }

    public static func presentationPrompt(
        for event: NormalizedEvent,
        profilePrompt: String = defaultProfilePrompt,
        memoryContext: String?,
        spokenLanguageName: String? = nil,
        maxCodexOutputCharacters: Int = 12_000
    ) -> AttachePresentationPrompt {
        let rawText = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let clippedOutput: String
        let truncated: Bool
        if rawText.count > maxCodexOutputCharacters {
            let end = rawText.index(rawText.startIndex, offsetBy: maxCodexOutputCharacters)
            clippedOutput = String(rawText[..<end]) + "\n\n[Agent output truncated.]"
            truncated = true
        } else {
            clippedOutput = rawText
            truncated = false
        }

        let system = systemPrompt(
            profilePrompt: profilePrompt,
            memoryContext: memoryContext,
            spokenLanguageName: spokenLanguageName
        )
        let user = userPrompt(for: event, clippedOutput: clippedOutput)

        return AttachePresentationPrompt(
            messages: [
                AttacheChatMessage(role: "system", content: system),
                AttacheChatMessage(role: "user", content: user)
            ],
            memoryContext: memoryContext,
            rawOutputCharacterCount: rawText.count,
            truncatedRawOutput: truncated
        )
    }

    public static func followUpPrompt(
        for card: VoicemailCard,
        danQuestion: String,
        profilePrompt: String = defaultProfilePrompt,
        memoryContext: String?,
        spokenLanguageName: String? = nil,
        maxContextCharacters: Int = 10_000
    ) -> AttacheFollowUpPrompt {
        let rawContext = followUpContext(for: card)
        let clippedContext: String
        let truncated: Bool
        if rawContext.count > maxContextCharacters {
            let end = rawContext.index(rawContext.startIndex, offsetBy: maxContextCharacters)
            clippedContext = String(rawContext[..<end]) + "\n\n[Agent context truncated.]"
            truncated = true
        } else {
            clippedContext = rawContext
            truncated = false
        }

        let system = followUpSystemPrompt(
            profilePrompt: profilePrompt,
            memoryContext: memoryContext,
            spokenLanguageName: spokenLanguageName
        )
        let user = followUpUserPrompt(
            for: card,
            danQuestion: danQuestion,
            clippedContext: clippedContext
        )

        return AttacheFollowUpPrompt(
            messages: [
                AttacheChatMessage(role: "system", content: system),
                AttacheChatMessage(role: "user", content: user)
            ],
            memoryContext: memoryContext,
            rawContextCharacterCount: rawContext.count,
            truncatedRawContext: truncated
        )
    }

    /// One session Attaché is watching, for the conversation system prompt's
    /// "Watched sessions" inventory (INF-239). Kept thin on purpose: no
    /// working directory, no session id, for non-focused sessions, so the
    /// model gets awareness ("did you mean the Claude Code session?")
    /// without spending tokens it does not need. This is prompt context
    /// only; the frozen send destination is decided elsewhere and never
    /// reads this inventory (see AGENTS.md "no hidden phrase routing").
    public struct WatchedSessionSummary: Equatable {
        public var sourceName: String
        public var title: String
        public var updatedAt: Date
        public var isFocused: Bool
        public var isTwoWayEnabled: Bool

        public init(
            sourceName: String,
            title: String,
            updatedAt: Date,
            isFocused: Bool,
            isTwoWayEnabled: Bool
        ) {
            self.sourceName = sourceName
            self.title = title
            self.updatedAt = updatedAt
            self.isFocused = isFocused
            self.isTwoWayEnabled = isTwoWayEnabled
        }
    }

    static let maxWatchedSessionEntries = 6

    /// Renders the "Watched sessions" inventory block: what Attaché is
    /// watching, most recent first, capped so the block stays token-lean.
    /// Two-way enablement is only ever shown for the focused entry.
    public static func watchedSessionsBlock(
        _ sessions: [WatchedSessionSummary],
        now: Date = Date()
    ) -> String {
        guard sessions.count > 1 else {
            return "No other sessions are being watched."
        }
        let ranked = sessions.sorted { $0.updatedAt > $1.updatedAt }.prefix(maxWatchedSessionEntries)
        let lines = ranked.map { session -> String in
            var tags: [String] = []
            if session.isFocused {
                tags.append("focused")
                if session.isTwoWayEnabled { tags.append("two-way enabled") }
            }
            tags.append(relativeActiveTag(from: session.updatedAt, now: now))
            let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return "- \(session.sourceName) / \"\(title.isEmpty ? "Untitled session" : title)\" (\(tags.joined(separator: ", ")))"
        }
        return (["Watched sessions:"] + lines).joined(separator: "\n")
    }

    private static func relativeActiveTag(from date: Date, now: Date) -> String {
        let delta = max(0, now.timeIntervalSince(date))
        if delta < 45 { return "active just now" }
        let minutes = Int((delta / 60).rounded())
        if minutes < 60 { return "active \(minutes)m ago" }
        let hours = Int((delta / 3600).rounded())
        if hours < 24 { return "active \(hours)h ago" }
        let days = Int((delta / 86400).rounded())
        return "active \(days)d ago"
    }

    /// System prompt for an ongoing voice conversation with the user (multi-turn, with
    /// tools to pull more session context). Distinct from the one-shot presentation
    /// and follow-up prompts.
    public static func conversationSystemPrompt(
        profilePrompt: String = defaultProfilePrompt,
        memoryContext: String?,
        sessionTitle: String?,
        sessionSourceName: String? = nil,
        workingDirectory: String?,
        latestSummary: String?,
        latestAgentReply: String? = nil,
        canStageAgentInstruction: Bool = false,
        watchedSessions: [WatchedSessionSummary] = []
    ) -> String {
        let memoryBlock = memoryContext.map { "\n\n\($0)" } ?? ""
        let titleLine: String
        if let sessionTitle, let sessionSourceName {
            titleLine = "- Focused agent: \(sessionSourceName) / \(sessionTitle)\n"
        } else {
            titleLine = sessionTitle.map { "- Session: \($0)\n" } ?? ""
        }
        let cwdLine = workingDirectory.map { "- Working directory: \($0)\n" } ?? ""
        let summaryLine = latestSummary.map { "- Latest update: \($0)\n" } ?? ""
        let latestReplyLine = latestAgentReply.map { "- Latest agent reply: \($0)\n" } ?? ""
        let agentInstructionLine = canStageAgentInstruction
            ? """
            - Use stage_agent_instruction only when the user explicitly asks the focused work agent to take an action.
            - Keep this boundary exact: "What did Codex say?" is a question for you to answer with session-reading tools. "Ask Codex what it changed" is an explicit delegation, so you MUST call stage_agent_instruction. Asking the agent to answer, explain, check, read, summarize, or report is still an action request, even when it concerns prior work or an artifact.
            - Do not substitute read_session_transcript, list_working_directory, or read_file when the user explicitly asks you to ask the focused agent. Use local read tools only when the user asks you to inspect or explain the context yourself.
            - If the user names a different agent than the focused one, ask them to focus that session instead of staging. Attaché routes explicit requests through the user's send-to-agent policy, which may confirm or may send directly after enablement. After the tool returns, report its actual status and target. Never claim a send unless Attaché reports it.
            - Whenever the user names a specific agent (Codex or Claude Code) in this turn, always set stage_agent_instruction's intended_agent argument to that agent, so Attaché can verify it against the focused session before staging. Never guess or omit intended_agent when a name was given; leave it unset only when no agent was named. Attaché only ever refuses on a mismatch, it never reroutes to a different agent.

            """
            : "- Do not address, write to, or imply you can message the work agent from this conversation.\n"
        let toolsLine = canStageAgentInstruction
            ? "- Tools available: read_session_transcript (the full earlier conversation), list_working_directory (what files exist), read_file (a file's contents), stage_agent_instruction (route a user-requested instruction to the work agent), and rename_session. Only read or stage what you need.\n"
            : "- Tools available: read_session_transcript (the full earlier conversation), list_working_directory (what files exist), read_file (a file's contents), and rename_session. Only read what you need.\n"
        let watchedSessionsSection = watchedSessionsBlock(watchedSessions)
        return """
        \(attacheIdentityPrompt)

        \(profilePrompt.trimmingCharacters(in: .whitespacesAndNewlines))\(memoryBlock)

        Live conversation task:
        - You are in a back-and-forth voice conversation with the user about their work. This is your own chat with the user, not the work agent.
        - Speak directly to the user. Replies are read aloud, so keep them short and listenable: headline first, then the key point. No long lists, no code blocks, no reciting paths, hashes, or URLs.
        - You start with the session context below. If you need MORE than that to answer well (earlier turns, what files exist, or a file's contents), call your tools to read it before answering. Prefer reading over guessing. When a summary mentions a count but omits the items, read the transcript for the specifics. Find an artifact's exact path from the transcript before reading it; never guess a path or probe an unrelated protected folder.
        \(agentInstructionLine)\(toolsLine)
        - You can also rename this session for Attaché with rename_session when the user asks to name or relabel it (for example "let's call this the tax cleanup session"). This only changes Attaché's label. Confirm the new name briefly after renaming.
        - Preserve uncertainty. Do not invent file contents, results, approvals, or repository state. If a tool returns nothing useful, say what is missing.
        - If a tool result or a status update tells you a send to the work agent was blocked, failed, or expired, say plainly what happened and the one next step the user can take right now. Never say a send succeeded unless Attaché actually reported that it did. Never invent a retry, workaround, or recovery option that was not reported to you; if none was given, just say what happened.
        - Output only your spoken reply. No labels, no markdown fences, no stage directions.

        Current session context:
        \(titleLine)\(cwdLine)\(summaryLine)\(latestReplyLine)
        \(watchedSessionsSection)
        """
    }

    /// One summarized inbox item feeding the recap: the session it belongs to,
    /// its already-presented summary and spoken text, and whether it was flagged
    /// as needing a decision. The recap never sees raw agent output, only what
    /// was already condensed for the user.
    public struct RecapItem: Equatable {
        public var sessionTitle: String
        public var summary: String
        public var spokenText: String
        public var needsDecision: Bool

        public init(sessionTitle: String, summary: String, spokenText: String, needsDecision: Bool) {
            self.sessionTitle = sessionTitle
            self.summary = summary
            self.spokenText = spokenText
            self.needsDecision = needsDecision
        }
    }

    /// Prompt for the personalized "Recap" of the waiting inbox (INF-169
    /// follow-on). It keeps the active personality's voice for tone, but the
    /// brevity directive is written to WIN over any verbosity the character
    /// prompt asks for: a short recap that leads with what matters most.
    public static func recapPrompt(
        items: [RecapItem],
        profilePrompt: String = defaultProfilePrompt,
        memoryContext: String?,
        spokenLanguageName: String? = nil
    ) -> AttachePresentationPrompt {
        let memoryBlock = memoryContext.map { "\n\n\($0)" } ?? ""
        let languageBlock = spokenLanguageName.map {
            "\n- Write the recap in \($0), translating what matters even if the source items are in another language."
        } ?? ""
        let itemCount = items.count
        let sessionCount = Set(items.map { $0.sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            .filter { !$0.isEmpty }
            .count
        let ceiling = recapSentenceCeiling(itemCount: itemCount)
        let scale = "\(itemCount) waiting update\(itemCount == 1 ? "" : "s")"
            + (sessionCount > 1 ? " across \(sessionCount) sessions" : "")
        let system = """
        \(attacheIdentityPrompt)

        \(profilePrompt.trimmingCharacters(in: .whitespacesAndNewlines))\(memoryBlock)

        Recap task:\(languageBlock)
        - The user asked for one spoken recap of \(scale). Speak directly to the user, never to an agent.
        - Your job is to save the user time without losing anything that matters. Listening to every update in full would take a while; this recap has to be clearly shorter, yet still account for everything important.
        - Compress hard:
          - Cluster updates about the same thing and mention that thing once.
          - When several updates trace one task from problem to resolution, give only the outcome, not each step along the way (for example, "the thumbnail went from red to blue," not every attempt behind it).
          - Drop cosmetic and procedural detail. Spend words on decisions, failures, and what shipped.
        - Never drop: anything flagged as needing a decision, anything that failed and is still unresolved, or anything that shipped or completed. Name each needed decision so the user knows to act.
        - Let length follow the information, not the item count. A few overlapping updates might be one or two sentences; many distinct topics might be a short paragraph. Do not pad, and do not read the items back as a list. Keep it to at most \(ceiling) sentences; if there is genuinely more than that, step up to a higher-level summary rather than running longer.
        - Keep the active personality's voice, tone, and language, but this brevity and prioritization override any verbosity the character prompt asks for.
        - The items below are already condensed summaries, not raw output. Do not recite code, logs, paths, hashes, URLs, or IDs.
        - Output only the spoken recap. No labels, no markdown fences, no stage directions, no CARD_SUMMARY line.
        """

        var lines: [String] = ["Waiting inbox items to recap:"]
        for (index, item) in items.enumerated() {
            let title = item.sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let spoken = item.spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = summary.isEmpty ? spoken : summary
            let decision = item.needsDecision ? " [needs a decision from the user]" : ""
            lines.append("\(index + 1). \(title.isEmpty ? "Update" : title): \(detail)\(decision)")
        }
        let user = lines.joined(separator: "\n") + "\n\nWrite the spoken recap now."

        return AttachePresentationPrompt(
            messages: [
                AttacheChatMessage(role: "system", content: system),
                AttacheChatMessage(role: "user", content: user)
            ],
            memoryContext: memoryContext,
            rawOutputCharacterCount: user.count,
            truncatedRawOutput: false
        )
    }

    /// Upper bound on recap length (in sentences), scaled to how much is
    /// waiting. Keeps even a large inbox to a short spoken paragraph instead of
    /// an essay, while letting a couple of items stay a sentence or two.
    public static func recapSentenceCeiling(itemCount: Int) -> Int {
        switch itemCount {
        case ..<3: return 2
        case ..<6: return 3
        case ..<12: return 5
        case ..<24: return 7
        default: return 9
        }
    }

    /// The "another take" prompt (INF-297): re-narrate one update in the target
    /// personality's voice, opening with a brief nod to what a different
    /// personality already said, then giving the target's own spin. Pure and
    /// deterministic; the caller runs it through the presentation model and
    /// `stripDashes` on the spoken result, exactly like the normal path. Reuses
    /// the shared identity, output format, and recap-style length scaling so a
    /// take files as an ordinary card.
    public static func anotherTakePrompt(
        sourceText: String,
        priorTake: String,
        priorPersonalityName: String,
        targetProfilePrompt: String = defaultProfilePrompt,
        memoryContext: String?,
        spokenLanguageName: String? = nil,
        maxSourceCharacters: Int = 12_000
    ) -> AttachePresentationPrompt {
        let rawSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let clippedSource: String
        let truncated: Bool
        if rawSource.count > maxSourceCharacters {
            let end = rawSource.index(rawSource.startIndex, offsetBy: maxSourceCharacters)
            clippedSource = String(rawSource[..<end]) + "\n\n[Agent output truncated.]"
            truncated = true
        } else {
            clippedSource = rawSource
            truncated = false
        }
        let trimmedPrior = priorTake.trimmingCharacters(in: .whitespacesAndNewlines)
        let priorName = priorPersonalityName.trimmingCharacters(in: .whitespacesAndNewlines)
        let priorNameForPrompt = priorName.isEmpty ? "another personality" : priorName
        let ceiling = anotherTakeSentenceCeiling(sourceCharacters: rawSource.count + trimmedPrior.count)
        let memoryBlock = memoryContext.map { "\n\n\($0)" } ?? ""
        let languageBlock = spokenLanguageName.map {
            "\n- Speak in \($0), translating what matters even if the source is in another language."
        } ?? ""

        let system = """
        \(attacheIdentityPrompt)

        \(targetProfilePrompt.trimmingCharacters(in: .whitespacesAndNewlines))\(memoryBlock)

        Another-take task:\(languageBlock)
        - The user already heard \(priorNameForPrompt)'s take on this same update and wants to hear it again from you, in your own voice and character.
        - Open with one short beat that reacts to \(priorNameForPrompt)'s take: agree, push back, or reframe it. One clause or one short sentence. Do not repeat their take back or summarize it at length.
        - Then give your own take on the underlying update, in your voice: what actually matters here and what the user can do next. Bring your own angle, not a paraphrase of \(priorNameForPrompt).
        - Read for any profession or domain. Use only what the source below actually says; never assume software, coding, or any specific field unless the source makes it explicit.
        - This is spoken and captioned: short sentences, headline first, no lists, no code, no reciting paths, hashes, URLs, or IDs.
        - Keep it tight: at most \(ceiling) sentences, including the opening beat. Let the information set the length; do not pad.
        - Do not talk to the agent. Speak directly to the user. No stage directions, no parentheticals, no asterisk notes.
        - Never use em dashes; write with commas, periods, or parentheses instead.

        Required output format:
        CARD_SUMMARY: <a tight 6-12 word card summary, no period>
        NEEDS_DECISION: <yes only if the update explicitly blocks the user on a choice; omit otherwise>

        <spoken another-take update>
        """

        let user = """
        Here is \(priorNameForPrompt)'s earlier take on the update. React to it in one short beat, do not repeat it:
        \(trimmedPrior.isEmpty ? "[No prior take text was provided.]" : trimmedPrior)

        Here is the underlying agent update to give your own take on:
        \(clippedSource.isEmpty ? "[No source text was provided.]" : clippedSource)

        Write your another-take spoken update now.
        """

        return AttachePresentationPrompt(
            messages: [
                AttacheChatMessage(role: "system", content: system),
                AttacheChatMessage(role: "user", content: user)
            ],
            memoryContext: memoryContext,
            rawOutputCharacterCount: rawSource.count,
            truncatedRawOutput: truncated
        )
    }

    /// Upper bound (in sentences) on an "another take", scaled to how much source
    /// and prior narration there is to react to. Mirrors `recapSentenceCeiling`:
    /// a one-line update stays a sentence or two, a dense one earns a few more.
    public static func anotherTakeSentenceCeiling(sourceCharacters: Int) -> Int {
        switch sourceCharacters {
        case ..<400: return 2
        case ..<1200: return 3
        case ..<4000: return 4
        default: return 5
        }
    }

    /// Replaces em/en dashes with a comma so spoken text and captions never show
    /// the dash, even when the model ignores the no-em-dash instruction in the
    /// prompt. Keeps the pause (comma) and tidies the spacing artifacts.
    public static func stripDashes(_ text: String) -> String {
        var s = text
        for dash in ["—", "–", "―"] {
            s = s.replacingOccurrences(of: dash, with: ", ")
        }
        s = s.replacingOccurrences(of: " ,", with: ",")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func systemPrompt(
        profilePrompt: String,
        memoryContext: String?,
        spokenLanguageName: String? = nil
    ) -> String {
        let memoryBlock = memoryContext.map { "\n\n\($0)" } ?? ""
        // The user's language wins over whatever language the agent worked
        // in; a Korean user hears Korean recaps of an English transcript.
        let languageBlock = spokenLanguageName.map {
            "\n- Write the card summary and the spoken update in \($0). If the agent output is in another language, still answer in \($0), translating what matters."
        } ?? ""
        return """
        \(attacheIdentityPrompt)

        \(profilePrompt.trimmingCharacters(in: .whitespacesAndNewlines))\(memoryBlock)

        Presentation task:\(languageBlock)
        - Transform the raw agent response into a attache-written spoken update.
        - Do not read the agent response verbatim unless the character prompt explicitly asks for that.
        - Do not talk to the agent. Speak directly to the user.
        - Default to 2-4 short sentences and stay under about 700 spoken characters unless the character prompt asks for more detail.
        - Do not recite code blocks, logs, paths, hashes, URLs, IDs, or file lists unless they are the main point.
        - If a link matters, say "I included the link" or describe where it is.
        - If markdown link syntax appears, speak only the label and never the URL.
        - Skip machine-only error codes unless they change what the user should do.

        Required output format:
        CARD_SUMMARY: <a tight 6-12 word card summary, no period>
        NEEDS_DECISION: <yes only if the agent is explicitly blocked on a choice or question for the user; omit this line otherwise>

        <spoken attache update>
        """
    }

    private static func userPrompt(
        for event: NormalizedEvent,
        clippedOutput: String
    ) -> String {
        let sessionLine = event.externalSessionID.map { "Session: \($0)\n" } ?? ""
        let projectLine = event.projectPath.map { "Workspace: \($0)\n" } ?? ""
        let eventLine = event.eventType.isEmpty ? "" : "Event: \(event.eventType)\n"
        let trajectoryBlock = trajectorySection(from: event)

        return """
        The observed agent just finished replying in the user's attached or observed session.
        Source: \(event.source)
        Title: \(event.title)
        \(eventLine)\(sessionLine)\(projectLine)
        Use the full agent response below as source material for a personalized
        spoken update. The spoken update should tell the user what matters and what they
        can do next, not simply repeat the raw response.\(trajectoryBlock)

        Agent output:
        \(clippedOutput)
        """
    }

    /// When the watcher coalesced several interstitial steps into this turn, offer
    /// them so the recap can mention the trajectory briefly ("after checking the
    /// tests and the config, it landed on..."). Optional and short.
    private static func trajectorySection(from event: NormalizedEvent) -> String {
        guard let json = event.metadata["interstitials"],
              let data = json.data(using: .utf8),
              let steps = try? JSONSerialization.jsonObject(with: data) as? [String],
              !steps.isEmpty else {
            return ""
        }
        let list = steps.prefix(8).map { step -> String in
            let flat = step.trimmingCharacters(in: .whitespacesAndNewlines)
            let single = flat.replacingOccurrences(of: "\n", with: " ")
            return "- " + (single.count > 200 ? String(single.prefix(200)) + "…" : single)
        }.joined(separator: "\n")
        return """


        Before the final message the agent worked through these steps. You may
        reference the trajectory in one brief clause if it helps; do not list them:
        \(list)
        """
    }

    private static func followUpSystemPrompt(
        profilePrompt: String,
        memoryContext: String?,
        spokenLanguageName: String? = nil
    ) -> String {
        let memoryBlock = memoryContext.map { "\n\n\($0)" } ?? ""
        return """
        \(attacheIdentityPrompt)

        \(profilePrompt.trimmingCharacters(in: .whitespacesAndNewlines))\(memoryBlock)

        Attache follow-up task:\(spokenLanguageName.map { "\n- Answer in \($0)." } ?? "")
        - Answer the user directly as Attaché, using the observed agent update and recent history as context.
        - Do not write to the agent, address the agent, or create agent-ready instructions.
        - Never imply that you sent, will send, queued, or can send a message into the agent.
        - If the user asks for an action that would require the agent, explain the useful instruction they could give the agent manually, but keep the response addressed to the user.
        - For short references like "next chapter", "same thing", "what changed", or "what should I do next", resolve the reference from the provided session context when possible.
        - If the context is insufficient, say what context is missing instead of pretending to know.
        - Preserve meaningful uncertainty and do not invent facts, approvals, test results, or repository state.
        - Keep it concise and listenable unless the user explicitly asks for detail.
        - Output only the answer. Do not add labels, markdown fences, or CARD_SUMMARY.
        """
    }

    private static func followUpUserPrompt(
        for card: VoicemailCard,
        danQuestion: String,
        clippedContext: String
    ) -> String {
        let projectLine = card.projectPath.map { "Workspace: \($0)\n" } ?? ""
        let cardSessionLine = card.externalSessionID.map { "Observed session: \($0)\n" } ?? ""
        return """
        The user is asking Attaché a question about an observed agent update.
        Source: \(card.sourceDisplayName)
        Card title: \(card.sessionTitle ?? card.summary)
        \(cardSessionLine)\(projectLine)
        The user asked:
        \(danQuestion.trimmingCharacters(in: .whitespacesAndNewlines))

        Treat the user's phrase as a question or request to Attaché. If the
        phrase is short or elliptical, resolve it using the latest
        attache/agent context below. Do not send or draft a message to the agent.

        Latest attache/agent context:
        \(clippedContext)
        """
    }

    private static func followUpContext(for card: VoicemailCard) -> String {
        var sections: [String] = []
        if !card.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Card summary:\n\(card.summary)")
        }
        if !card.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Attache spoken recap:\n\(card.spokenText)")
        }
        if !card.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Raw agent output:\n\(card.rawText)")
        }
        return sections.joined(separator: "\n\n")
    }

    private static func cleanMemoryContent(_ content: String) -> String? {
        let cleaned = content
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
        guard !cleaned.isEmpty else { return nil }
        if cleaned.count > maxMemoryContentCharacters {
            return String(cleaned.prefix(maxMemoryContentCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
        }
        return cleaned
    }
}
