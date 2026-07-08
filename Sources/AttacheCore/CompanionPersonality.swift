import Foundation

public struct CompanionChatMessage: Equatable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct CompanionPresentationPrompt: Equatable {
    public var messages: [CompanionChatMessage]
    public var memoryContext: String?
    public var rawOutputCharacterCount: Int
    public var truncatedRawOutput: Bool

    public init(
        messages: [CompanionChatMessage],
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

public struct CompanionFollowUpPrompt: Equatable {
    public var messages: [CompanionChatMessage]
    public var memoryContext: String?
    public var rawContextCharacterCount: Int
    public var truncatedRawContext: Bool

    public init(
        messages: [CompanionChatMessage],
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

public enum CompanionPersonality {
    public static let maxMemoryContentCharacters = 800
    public static let maxMemoryContextCharacters = 2_400

    private static let companionIdentityPrompt = """
    You are Attaché, a local companion assistant for the person using this app.

    You are one companion, not a stack of separate bots. You are not the agent
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
            "Companion durable memory:",
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
    ) -> CompanionPresentationPrompt {
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

        return CompanionPresentationPrompt(
            messages: [
                CompanionChatMessage(role: "system", content: system),
                CompanionChatMessage(role: "user", content: user)
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
    ) -> CompanionFollowUpPrompt {
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

        return CompanionFollowUpPrompt(
            messages: [
                CompanionChatMessage(role: "system", content: system),
                CompanionChatMessage(role: "user", content: user)
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
        workingDirectory: String?,
        latestSummary: String?,
        canStageAgentInstruction: Bool = false
    ) -> String {
        let memoryBlock = memoryContext.map { "\n\n\($0)" } ?? ""
        let titleLine = sessionTitle.map { "- Session: \($0)\n" } ?? ""
        let cwdLine = workingDirectory.map { "- Working directory: \($0)\n" } ?? ""
        let summaryLine = latestSummary.map { "- Latest update: \($0)\n" } ?? ""
        let agentInstructionLine = canStageAgentInstruction
            ? "- If the user explicitly asks you to tell, ask, or instruct the work agent, use stage_agent_instruction with a concise instruction for that agent. Attaché will route it through the user's send-to-agent policy, which may require confirmation or may send directly after the session is enabled. After the tool returns, report the actual status it gives you. Never say the agent has been told unless Attaché reports that it sent the instruction.\n"
            : "- Do not address, write to, or imply you can message the work agent from this conversation.\n"
        let toolsLine = canStageAgentInstruction
            ? "- Tools available: read_session_transcript (the full earlier conversation), list_working_directory (what files exist), read_file (a file's contents), stage_agent_instruction (route a user-requested instruction to the work agent), and rename_session. Only read or stage what you need.\n"
            : "- Tools available: read_session_transcript (the full earlier conversation), list_working_directory (what files exist), read_file (a file's contents), and rename_session. Only read what you need.\n"
        return """
        \(companionIdentityPrompt)

        \(profilePrompt.trimmingCharacters(in: .whitespacesAndNewlines))\(memoryBlock)

        Live conversation task:
        - You are in a back-and-forth voice conversation with the user about their work. This is your own chat with the user, not the work agent.
        - Speak directly to the user. Replies are read aloud, so keep them short and listenable: headline first, then the key point. No long lists, no code blocks, no reciting paths, hashes, or URLs.
        - You start with the session context below. If you need MORE than that to answer well (earlier turns, what files exist, or a file's contents), call your tools to read it before answering. Prefer reading over guessing.
        \(agentInstructionLine)\(toolsLine)
        - You can also rename this session for Attaché with rename_session when the user asks to name or relabel it (for example "let's call this the tax cleanup session"). This only changes Attaché's label. Confirm the new name briefly after renaming.
        - Preserve uncertainty. Do not invent file contents, results, approvals, or repository state. If a tool returns nothing useful, say what is missing.
        - Output only your spoken reply. No labels, no markdown fences, no stage directions.

        Current session context:
        \(titleLine)\(cwdLine)\(summaryLine)
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
    ) -> CompanionPresentationPrompt {
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
        \(companionIdentityPrompt)

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

        return CompanionPresentationPrompt(
            messages: [
                CompanionChatMessage(role: "system", content: system),
                CompanionChatMessage(role: "user", content: user)
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
        \(companionIdentityPrompt)

        \(profilePrompt.trimmingCharacters(in: .whitespacesAndNewlines))\(memoryBlock)

        Presentation task:\(languageBlock)
        - Transform the raw agent response into a companion-written spoken update.
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

        <spoken companion update>
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
        \(companionIdentityPrompt)

        \(profilePrompt.trimmingCharacters(in: .whitespacesAndNewlines))\(memoryBlock)

        Companion follow-up task:\(spokenLanguageName.map { "\n- Answer in \($0)." } ?? "")
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
        companion/agent context below. Do not send or draft a message to the agent.

        Latest companion/agent context:
        \(clippedContext)
        """
    }

    private static func followUpContext(for card: VoicemailCard) -> String {
        var sections: [String] = []
        if !card.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Card summary:\n\(card.summary)")
        }
        if !card.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Companion spoken recap:\n\(card.spokenText)")
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
