import Foundation

/// One structured assistant tool request. Keeping this in Core prevents a
/// multi-round conversation from being flattened into plain text before the
/// context compiler can authorize and budget the exact provider payload.
public struct AttacheChatToolCall: Equatable, Sendable, Codable {
    public var id: String
    public var type: String
    public var name: String
    public var arguments: String

    public init(id: String, type: String = "function", name: String, arguments: String) {
        self.id = id
        self.type = type
        self.name = name
        self.arguments = arguments
    }

    private enum CodingKeys: String, CodingKey { case id, type, function }
    private struct FunctionPayload: Equatable, Sendable, Codable {
        let name: String
        let arguments: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "function"
        let function = try container.decode(FunctionPayload.self, forKey: .function)
        name = function.name
        arguments = function.arguments
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(FunctionPayload(name: name, arguments: arguments), forKey: .function)
    }
}

public struct AttacheChatMessage: Equatable, Sendable, Codable {
    public var role: String
    public var content: String
    /// Present on assistant messages that requested tools.
    public var toolCalls: [AttacheChatToolCall]
    /// Present on a tool result message and bound to exactly one prior call.
    public var toolCallID: String?

    public init(
        role: String,
        content: String,
        toolCalls: [AttacheChatToolCall] = [],
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    private enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        toolCalls = try container.decodeIfPresent([AttacheChatToolCall].self, forKey: .toolCalls) ?? []
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        if !toolCalls.isEmpty { try container.encode(toolCalls, forKey: .toolCalls) }
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
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
    points. The output will be read aloud and captioned. Long technical strings
    like links and checksums are never read out loud; describe them at a high
    level instead.

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

    /// System prompt for an ongoing voice conversation with the user (multi-turn, with
    /// tools to pull more session context). Distinct from the one-shot presentation
    /// and follow-up prompts.
    public static func conversationSystemPrompt(
        profilePrompt: String = defaultProfilePrompt,
        memoryContext: String?,
        sessionTitle: String?,
        sessionIsFocused: Bool? = nil,
        sessionSourceName: String? = nil,
        workingDirectory: String?,
        latestSummary: String?,
        latestAgentReply: String? = nil,
        canStageAgentInstruction: Bool = false,
        canProposeMemory: Bool = false
    ) -> String {
        let memoryBlock = memoryContext.map { "\n\n\($0)" } ?? ""
        let hasSessionContext = sessionIsFocused ?? (sessionTitle != nil)
        let canStage = hasSessionContext && canStageAgentInstruction
        let titleLine: String
        if hasSessionContext, let sessionTitle, let sessionSourceName {
            titleLine = "- Focused agent: \(sessionSourceName) / \(sessionTitle)\n"
        } else if hasSessionContext {
            titleLine = sessionTitle.map { "- Session: \($0)\n" } ?? ""
        } else {
            titleLine = ""
        }
        let cwdLine = hasSessionContext ? (workingDirectory.map { "- Working directory: \($0)\n" } ?? "") : ""
        let summaryLine = hasSessionContext ? (latestSummary.map { "- Latest update: \($0)\n" } ?? "") : ""
        let latestReplyLine = hasSessionContext ? (latestAgentReply.map { "- Latest agent reply: \($0)\n" } ?? "") : ""
        let agentInstructionLine = canStage
            ? """
            - Use stage_agent_instruction only when the user explicitly asks the focused work agent to take an action.
            - Keep this boundary exact: "What did Codex say?" is a question for you to answer with session-reading tools. "Ask Codex what it changed" is an explicit delegation, so you MUST call stage_agent_instruction. Asking the agent to answer, explain, check, read, summarize, or report is still an action request, even when it concerns prior work or an artifact.
            - Do not substitute read_session_transcript, list_working_directory, or read_file when the user explicitly asks you to ask the focused agent. Use local read tools only when the user asks you to inspect or explain the context yourself.
            - If the user names a different agent than the focused one, ask them to focus that session instead of staging. A personality-requested handoff always opens a native confirmation before sending. After the tool returns, report its actual status and target. Never claim a send unless Attaché reports it.
            - Whenever the user names a specific agent (Codex or Claude Code) in this turn, always set stage_agent_instruction's intended_agent argument to that agent, so Attaché can verify it against the focused session before staging. Never guess or omit intended_agent when a name was given; leave it unset only when no agent was named. Attaché only ever refuses on a mismatch, it never reroutes to a different agent.

            """
            : "- Do not address, write to, or imply you can message the work agent from this conversation.\n"
        let memoryToolDescription = "propose_memory (save one fact the user explicitly asked you to remember)"
        let toolsLine: String
        if canStage {
            toolsLine = canProposeMemory
                ? "- Tools available: read_session_transcript (the full earlier conversation), list_working_directory (what files exist), read_file (a file's contents), stage_agent_instruction (prepare a user-confirmed instruction for the work agent), and \(memoryToolDescription). Only read, stage, or propose what you need.\n"
                : "- Tools available: read_session_transcript (the full earlier conversation), list_working_directory (what files exist), read_file (a file's contents), and stage_agent_instruction (prepare a user-confirmed instruction for the work agent). Only read or stage what you need.\n"
        } else if hasSessionContext {
            toolsLine = canProposeMemory
                ? "- Tools available: read_session_transcript (the full earlier conversation), list_working_directory (what files exist), read_file (a file's contents), and \(memoryToolDescription). Only read or propose what you need.\n"
                : "- Tools available: read_session_transcript (the full earlier conversation), list_working_directory (what files exist), and read_file (a file's contents). Only read what you need.\n"
        } else {
            // The disclaimer names only the session, rename, and agent-send
            // tools that are genuinely absent in a context-free conversation,
            // so it can never contradict an offered memory tool.
            toolsLine = canProposeMemory
                ? "- No work-session, transcript, project-file, rename, or agent-send tools are available in this conversation.\n- Tools available: \(memoryToolDescription).\n"
                : "- No work-session, transcript, project-file, rename, or agent-send tools are available in this conversation.\n"
        }
        let memoryProposalLine = canProposeMemory
            ? "- Call propose_memory ONLY when the user explicitly asks you to remember, save, or note something, and you MUST call it then. An explicit ask includes the user affirming your own offer to remember, or agreeing to save a fact from the turns just before (\"yes, do that\", \"yeah, save it\"). When consent arrives as an affirmation, the fact to save is the one from the earlier turn. The same applies when you just told the user you do not know or lack a fact and they reply by supplying it: that completes the record you said was missing, so treat it as an explicit ask and call propose_memory. If you offered to remember and the user says yes, you MUST call propose_memory that turn; never offer and then refuse, and never ask the user to repeat a fact you can already see in this conversation. A spoken acknowledgment alone saves nothing. Never volunteer it for details shared in passing: a name, preference, or fact mentioned without any ask or offer is not a request to remember it. State the fact plainly and faithfully as the statement, correcting obvious transcription garbles. The save goes to this Attaché's own memory; if the user asks you to remember something for all of their Attachés, still save it for this Attaché and add one short clause that memories for every Attaché are typed in Settings > Memory.\n- After a save, reply to the person naturally and in character: greet a new name, react to their news, answer what they asked. Do not narrate the save mechanics; Attaché's own UI confirms every save, so at most weave in a brief natural acknowledgment such as \"noted\". Never claim a memory was saved unless the tool reported it, and never say \"I'll keep that in mind\", \"I'll remember\", \"noted\", or any phrasing that implies persistence unless the tool reported a save this turn: if nothing was saved, either save it or speak without implying memory. If the tool declines the fact, tell them briefly, in one clause, that it can't be saved and why.\n"
            : "- You cannot save memories in this conversation: remembering is off or this is a private call. If the user asks you to remember something, say plainly that nothing will be saved right now; never imply you will remember it.\n"
        let contextGuidance = hasSessionContext
            ? "- You start with the explicitly focused session context below. If you need MORE than that to answer well (earlier turns, what files exist, or a file's contents), call your tools to read it before answering. Prefer reading over guessing. When a summary mentions a count but omits the items, read the transcript for the specifics. Find an artifact's exact path from the transcript before reading it; never guess a path or probe an unrelated protected folder."
            : "- No work session is focused. Do not infer one from recency, watched sessions, a selected voicemail, conversation history, or other app activity. Treat this as a context-free conversation. If the user asks about past agent work, ask them to focus that session with the session picker; never guess which session they mean."
        let contextBlock = hasSessionContext
            ? ([titleLine, cwdLine, summaryLine, latestReplyLine].joined().isEmpty
                ? "Focused-session metadata is supplied separately as untrusted evidence."
                : "\(titleLine)\(cwdLine)\(summaryLine)\(latestReplyLine)")
            : "None. This conversation has no work-session context."
        return """
        \(attacheIdentityPrompt)

        \(profilePrompt.trimmingCharacters(in: .whitespacesAndNewlines))\(memoryBlock)

        Live conversation task:
        - You are in a back-and-forth voice conversation with the user about their work. This is your own chat with the user, not the work agent.
        - Speak directly to the user. Replies are read aloud, so keep them short and listenable: headline first, then the key point. No long lists, no code blocks, no reciting paths, hashes, or URLs.
        \(contextGuidance)
        \(agentInstructionLine)\(toolsLine)\(memoryProposalLine)
        - Preserve uncertainty. Do not invent file contents, results, approvals, or repository state. If a tool returns nothing useful, say what is missing.
        - If a tool result or a status update tells you a send to the work agent was blocked, failed, or expired, say plainly what happened and the one next step the user can take right now. Never say a send succeeded unless Attaché actually reported that it did. Never invent a retry, workaround, or recovery option that was not reported to you; if none was given, just say what happened.
        - Output only your spoken reply. No labels, no markdown fences, no stage directions.

        Current work-session context:
        \(contextBlock)
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
        let itemCount = items.count
        let sessionCount = recapSessionCount(items.map(\.sessionTitle))
        let system = recapSystemPromptText(
            itemCount: itemCount,
            sessionCount: sessionCount,
            profilePrompt: profilePrompt,
            memoryContext: memoryContext,
            spokenLanguageName: spokenLanguageName
        )

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

    /// Number of distinct, non-empty session titles among a set of recap
    /// items. Shared by the concatenated and staged recap prompt builders so
    /// their "N updates across S sessions" framing always agrees.
    public static func recapSessionCount(_ sessionTitles: [String]) -> Int {
        Set(sessionTitles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            .filter { !$0.isEmpty }
            .count
    }

    /// The recap system prompt text, shared by the legacy concatenated-user-turn
    /// builder (`recapPrompt`), the staged single/multi-call builder
    /// (`recapStagedSystemPrompt`), and the final synthesis call
    /// (`recapSynthesisPrompt`), so brevity rules never drift between paths
    /// (INF-353).
    static func recapSystemPromptText(
        itemCount: Int,
        sessionCount: Int,
        profilePrompt: String,
        memoryContext: String?,
        spokenLanguageName: String?
    ) -> String {
        let memoryBlock = memoryContext.map { "\n\n\($0)" } ?? ""
        let languageBlock = spokenLanguageName.map {
            "\n- Write the recap in \($0), translating what matters even if the source items are in another language."
        } ?? ""
        let ceiling = recapSentenceCeiling(itemCount: itemCount)
        let scale = "\(itemCount) waiting update\(itemCount == 1 ? "" : "s")"
            + (sessionCount > 1 ? " across \(sessionCount) sessions" : "")
        return """
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
    }

    /// Staged recap system prompt (INF-353): identical brevity contract to
    /// `recapPrompt`, but items are not embedded in this text at all. Callers
    /// pass the items separately as `.recapEvidence` context items via
    /// `recapContextItems(from:)`, so the protected user turn stays this fixed
    /// instruction text regardless of inbox size.
    public static func recapStagedSystemPrompt(
        itemCount: Int,
        sessionCount: Int,
        profilePrompt: String = defaultProfilePrompt,
        memoryContext: String?,
        spokenLanguageName: String? = nil
    ) -> String {
        recapSystemPromptText(
            itemCount: itemCount,
            sessionCount: sessionCount,
            profilePrompt: profilePrompt,
            memoryContext: memoryContext,
            spokenLanguageName: spokenLanguageName
        )
    }

    /// The fixed instruction text for a staged recap's protected user turn
    /// (INF-353). It never grows with inbox size; the items themselves ride
    /// as separate `.recapEvidence` context items with `treatment:
    /// .summarizeEligible`, so the current user turn stays cheap to budget.
    public static func recapStagedUserInstruction() -> String {
        "Using the waiting inbox items provided above as evidence, write the spoken recap now."
    }

    /// Build the `.recapEvidence` context items for a set of recap items
    /// (INF-353). Each carries a stable `recap-item:<id>` provenance so a
    /// compiler receipt can name exactly which items were included or
    /// omitted, and `treatment: .summarizeEligible` so the compiler may stage
    /// rather than silently drop items that do not fit.
    public static func recapContextItems(
        from items: [(id: String, item: RecapItem)],
        priorityBase: Int = 500
    ) -> [AttacheContextItem] {
        items.enumerated().map { index, entry in
            let (id, item) = entry
            let title = item.sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let spoken = item.spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = summary.isEmpty ? spoken : summary
            let decision = item.needsDecision ? " [needs a decision from the user]" : ""
            let content = "\(title.isEmpty ? "Update" : title): \(detail)\(decision)"
            return AttacheContextItem(
                source: .recapEvidence,
                content: content,
                provenance: "recap-item:\(id)",
                priority: priorityBase - index,
                treatment: .summarizeEligible
            )
        }
    }

    /// The final synthesis call over per-stage recap summaries (INF-353),
    /// producing one combined spoken recap. Used only when a plan yields more
    /// than one stage; the single-stage case uses that stage's own completion
    /// directly, with no synthesis call.
    public static func recapSynthesisPrompt(
        stageSummaries: [String],
        itemCount: Int,
        sessionCount: Int,
        profilePrompt: String = defaultProfilePrompt,
        memoryContext: String?,
        spokenLanguageName: String? = nil
    ) -> AttachePresentationPrompt {
        let system = recapSystemPromptText(
            itemCount: itemCount,
            sessionCount: sessionCount,
            profilePrompt: profilePrompt,
            memoryContext: memoryContext,
            spokenLanguageName: spokenLanguageName
        )
        + "\n- The material below is already your own condensed summaries of earlier stages, not raw updates. Combine them into one recap; do not re-summarize them as a list of stages."

        var lines: [String] = ["Stage summaries to combine into one final spoken recap:"]
        for (index, summary) in stageSummaries.enumerated() {
            lines.append("\(index + 1). \(summary.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let user = lines.joined(separator: "\n") + "\n\nWrite the single combined spoken recap now."

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
        - The user already heard \(priorNameForPrompt)'s take on this same material and wants to hear it again from you, in your own voice and character.
        - Open with one short beat that reacts to \(priorNameForPrompt)'s take: agree, push back, or reframe it. One clause or one short sentence. Do not repeat their take back or summarize it at length.
        - Then give your own take on the underlying source material or conversation context, in your voice: what actually matters here and what the user can do next. Bring your own angle, not a paraphrase of \(priorNameForPrompt).
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
        Here is \(priorNameForPrompt)'s earlier take. React to it in one short beat, do not repeat it:
        \(trimmedPrior.isEmpty ? "[No prior take text was provided.]" : trimmedPrior)

        Here is the underlying source material or conversation context to give your own take on:
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

    /// The synthesis turn for INF-370 "Summarize Session…": one presentation
    /// call that turns an `AttacheExhaustiveReviewCoordinator` run's staged
    /// summaries (already assembled with an incompleteness notice when
    /// coverage isn't complete, `AttacheSessionSummaryLanguage`) into a single
    /// spoken-style voicemail card, in the active personality's voice, with
    /// the same dynamic length scaling and no-em-dash rule as every other
    /// spoken path. Pure and deterministic; the caller runs it through the
    /// presentation model and `stripDashes` on the result, exactly like recap
    /// and another-take.
    public static func sessionSummarySynthesisPrompt(
        sourceText: String,
        sessionTitle: String,
        sourceKindDisplayName: String,
        profilePrompt: String = defaultProfilePrompt,
        memoryContext: String?,
        spokenLanguageName: String? = nil,
        maxSourceCharacters: Int = 20_000
    ) -> AttachePresentationPrompt {
        let rawSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let clippedSource: String
        let truncated: Bool
        if rawSource.count > maxSourceCharacters {
            let end = rawSource.index(rawSource.startIndex, offsetBy: maxSourceCharacters)
            clippedSource = String(rawSource[..<end]) + "\n\n[Review material truncated.]"
            truncated = true
        } else {
            clippedSource = rawSource
            truncated = false
        }
        let title = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let ceiling = anotherTakeSentenceCeiling(sourceCharacters: rawSource.count)
        let memoryBlock = memoryContext.map { "\n\n\($0)" } ?? ""
        let languageBlock = spokenLanguageName.map {
            "\n- Speak in \($0), translating what matters even if the source is in another language."
        } ?? ""

        let system = """
        \(attacheIdentityPrompt)

        \(profilePrompt.trimmingCharacters(in: .whitespacesAndNewlines))\(memoryBlock)

        Session summary task:\(languageBlock)
        - The user asked you to summarize a \(sourceKindDisplayName) session titled "\(title.isEmpty ? "Untitled session" : title)" they were not listening to live. The material below is the staged review's own findings, not raw transcript; do not re-derive anything not present in it.
        - Compress hard: a solved problem gets its outcome, not each step; keep every decision, every unresolved failure, and anything the user still needs to act on.
        - If the material below ends with a line stating the summary only covers part of the session, you must say so out loud, near the end, in your own words. Never claim full coverage unless no such line is present.
        - This is spoken and captioned: short sentences, headline first, no lists, no code, no reciting paths, hashes, URLs, or IDs.
        - Keep it tight: at most \(ceiling) sentences. Let the information set the length; do not pad.
        - Speak directly to the user, never to an agent. No stage directions, no parentheticals, no asterisk notes.
        - Never use em dashes; write with commas, periods, or parentheses instead.

        Required output format:
        CARD_SUMMARY: <a tight 6-12 word card summary, no period>

        <spoken session summary>
        """

        let user = """
        Staged review findings for "\(title.isEmpty ? "Untitled session" : title)":
        \(clippedSource.isEmpty ? "[No findings were produced.]" : clippedSource)

        Write the spoken session summary now.
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

    /// De-noise text that is about to be SPOKEN (and captioned). Applies
    /// `stripDashes` first, then deterministically replaces the long technical
    /// strings a voice should never read out letter by letter: full URLs become
    /// "a link", UUIDs become "an ID", and long bare hex runs (checksums, SHAs)
    /// become "a checksum". Short IDs and file paths are intentionally left
    /// alone; the prompt handles those. Word-boundary safe, punctuation
    /// preserving, and idempotent. Only the spoken/captioned string is passed
    /// through this; a card's raw text keeps the full details (INF, the
    /// Notion-URL letter-by-letter incident).
    public static func sanitizeSpokenText(_ text: String) -> String {
        var s = stripDashes(text)

        // Full URLs -> "a link". Two forms: scheme://rest and www.-prefixed.
        // The run stops at whitespace or a closing bracket/quote; trailing
        // sentence punctuation is peeled back off so the sentence keeps its stop.
        s = replacingURLs(in: s, replacement: "a link")

        // Collapse an article the writer placed in front of the URL against the
        // article the substitution introduced ("the a link" -> "the link",
        // "a a link" -> "a link").
        s = replacingRegex(#"(?i)\b(the|an|a)\s+a link\b"#, in: s, template: "$1 link")

        // UUIDs (8-4-4-4-12 hex) -> "an ID". A UUID has no 16+ contiguous hex
        // run, so this pass and the bare-hex pass do not collide.
        s = replacingRegex(
            #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#,
            in: s,
            template: "an ID"
        )

        // Bare hex runs of 16+ characters (checksums, SHAs) -> "a checksum".
        s = replacingRegex(#"(?i)\b[0-9a-f]{16,}\b"#, in: s, template: "a checksum")

        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingRegex(_ pattern: String, in text: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func replacingURLs(in text: String, replacement: String) -> String {
        let pattern = #"(?i)(?:[a-z][a-z0-9+.\-]*://|www\.)[^\s<>()\[\]{}"'`]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        let trailing: Set<Character> = [".", ",", ";", ":", "!", "?"]
        // Rebuild from the end so earlier ranges stay valid as the string shrinks.
        for match in matches.reversed() {
            guard let matchedRange = Range(match.range, in: result) else { continue }
            var matched = String(result[matchedRange])
            var suffix = ""
            while let last = matched.last, trailing.contains(last) {
                suffix = String(last) + suffix
                matched.removeLast()
            }
            result.replaceSubrange(matchedRange, with: replacement + suffix)
        }
        return result
    }

    /// The system prompt for the creator audition (INF): a short in-character
    /// self-introduction that names the personality, phrased entirely by the
    /// personality's own prompt (a cowboy prompt that says "always open with
    /// howdy" should produce "Howdy, y'all, my name's Colt..." not "Hi, I'm
    /// Colt"), and capped to a roughly eight-second spoken budget of about 22
    /// words. The caller also trims any overrun deterministically with
    /// `trimSpokenIntroduction`, so the budget is enforced twice.
    public static func auditionIntroductionPrompt(personalityPrompt: String) -> String {
        """
        \(personalityPrompt)

        This is a character-creator audition. Introduce yourself to the user in the
        first person, staying fully in this personality, and say your name so they
        hear who they are meeting. Let this personality's own wording lead: if the
        prompt above tells you to open a certain way, open that way. Keep it to
        about 22 words so it speaks in roughly eight seconds. Output only the
        introduction. Do not use stage directions, quotation marks, or em dashes.
        """
    }

    /// Trim a spoken self-introduction to a spoken-duration budget without ever
    /// cutting a word in half. Prefers to end on a complete sentence that fits
    /// the word budget; if even the first sentence is over budget, falls back to
    /// the first `wordBudget` whole words and closes with a period. Idempotent:
    /// a take already within budget comes back unchanged aside from whitespace
    /// tidying.
    public static func trimSpokenIntroduction(_ text: String, wordBudget: Int = 22) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wordBudget > 0 else { return trimmed }
        let totalWords = trimmed.split(whereSeparator: { $0.isWhitespace })
        if totalWords.count <= wordBudget { return trimmed }

        var kept: [String] = []
        var wordCount = 0
        for sentence in splitIntoSentences(trimmed) {
            let words = sentence.split(whereSeparator: { $0.isWhitespace }).count
            if wordCount + words > wordBudget { break }
            kept.append(sentence)
            wordCount += words
        }
        if !kept.isEmpty {
            return kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // The opening sentence alone overruns: keep whole words up to the budget.
        return totalWords.prefix(wordBudget).joined(separator: " ") + "."
    }

    private static func splitIntoSentences(_ text: String) -> [String] {
        let chars = Array(text)
        var sentences: [String] = []
        var current = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            if c == "." || c == "!" || c == "?" {
                let nextIsTerminator = i + 1 < chars.count
                    && (chars[i + 1] == "." || chars[i + 1] == "!" || chars[i + 1] == "?")
                if !nextIsTerminator {
                    let cut = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cut.isEmpty { sentences.append(cut) }
                    current = ""
                }
            }
            i += 1
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
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
        - Do not recite code blocks, logs, paths, hashes, URLs, IDs, or file lists. Even when a link or hash is the main point, describe it (the link is on the card) and never speak it.
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
