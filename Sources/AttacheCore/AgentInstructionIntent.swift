import Foundation

/// Provider-independent recognition for "tell the work agent..." requests.
///
/// Structured tool calls are still used when a provider supports them, but the app
/// owns this first pass so text-only providers can stage agent instructions too.
public struct AgentInstructionIntent: Equatable {
    public enum RequestedAgent: String, Equatable {
        case attached
        case codex
        case claudeCode

        public var displayName: String {
            switch self {
            case .attached: return "attached agent"
            case .codex: return "Codex"
            case .claudeCode: return "Claude Code"
            }
        }

        public func matches(sourceKind: SourceKind) -> Bool {
            switch self {
            case .attached:
                return SourceKind.liveAgentRawValues.contains(sourceKind.rawValue)
            case .codex:
                return sourceKind == .codex
            case .claudeCode:
                return sourceKind == .claudeCode
            }
        }
    }

    public var requestedAgent: RequestedAgent
    public var instruction: String
    public var originalText: String

    public init(requestedAgent: RequestedAgent, instruction: String, originalText: String) {
        self.requestedAgent = requestedAgent
        self.instruction = instruction
        self.originalText = originalText
    }

    public static func detect(in text: String) -> AgentInstructionIntent? {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return nil }

        let normalized = collapseWhitespace(original)
        let lowered = normalized.lowercased()
        let stripped = stripLeadingPoliteness(lowered)
        let offset = lowered.distance(from: lowered.startIndex, to: stripped.startIndex)
        let strippedOriginal = String(normalized.dropFirst(offset))

        if let parsed = parseTellAskHave(strippedOriginal) {
            return AgentInstructionIntent(
                requestedAgent: parsed.agent,
                instruction: parsed.instruction,
                originalText: original
            )
        }
        if let parsed = parseSendForward(strippedOriginal) {
            return AgentInstructionIntent(
                requestedAgent: parsed.agent,
                instruction: parsed.instruction,
                originalText: original
            )
        }
        return nil
    }

    private typealias ParsedIntent = (agent: RequestedAgent, instruction: String)

    private static let instructionVerbs = ["tell", "ask", "instruct", "have"]
    private static let sendVerbs = ["send", "forward", "pass"]

    private static let targetPhrases: [(phrase: String, agent: RequestedAgent)] = [
        ("claude code", .claudeCode),
        ("claude", .claudeCode),
        ("codex", .codex),
        ("the attached work agent", .attached),
        ("attached work agent", .attached),
        ("the attached agent", .attached),
        ("attached agent", .attached),
        ("the work agent", .attached),
        ("work agent", .attached),
        ("the agent", .attached),
        ("agent", .attached),
        ("the brain", .attached),
        ("brain", .attached),
        ("the session", .attached),
        ("session", .attached),
        ("it", .attached),
        ("them", .attached)
    ]

    private static func parseTellAskHave(_ text: String) -> ParsedIntent? {
        let lower = text.lowercased()
        for verb in instructionVerbs {
            let prefix = "\(verb) "
            guard lower.hasPrefix(prefix) else { continue }
            let remainder = String(text.dropFirst(prefix.count))
            guard let target = parseTargetPrefix(in: remainder) else { return nil }
            guard let instruction = cleanInstruction(target.remainder) else { return nil }
            return (target.agent, instruction)
        }
        return nil
    }

    private static func parseSendForward(_ text: String) -> ParsedIntent? {
        let lower = text.lowercased()
        for verb in sendVerbs {
            let prefix = "\(verb) "
            guard lower.hasPrefix(prefix) else { continue }
            let remainder = String(text.dropFirst(prefix.count))
            if let parsed = parseSendThisToTarget(remainder) {
                return parsed
            }
            guard let target = parseTargetPrefix(in: remainder) else { return nil }
            guard let instruction = cleanInstruction(target.remainder) else { return nil }
            return (target.agent, instruction)
        }
        return nil
    }

    private static func parseSendThisToTarget(_ text: String) -> ParsedIntent? {
        var lower = text.lowercased()
        var original = text
        for prefix in ["this to ", "that to ", "the following to ", "a message to ", "a note to "] {
            if lower.hasPrefix(prefix) {
                original = String(original.dropFirst(prefix.count))
                lower = String(lower.dropFirst(prefix.count))
                if let target = parseTargetPrefix(in: original),
                   let instruction = cleanInstruction(target.remainder) {
                    return (target.agent, instruction)
                }
            }
        }
        return nil
    }

    private static func parseTargetPrefix(in text: String) -> (agent: RequestedAgent, remainder: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for target in targetPhrases {
            guard lower == target.phrase || lower.hasPrefix(target.phrase + " ") || lower.hasPrefix(target.phrase + ":") || lower.hasPrefix(target.phrase + ",") else {
                continue
            }
            let remainder = String(trimmed.dropFirst(target.phrase.count))
            return (target.agent, remainder)
        }
        return nil
    }

    private static func cleanInstruction(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ":,;- "))
        let lower = text.lowercased()
        for prefix in ["to ", "that ", "with ", "message "] {
            if lower.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                text = text.trimmingCharacters(in: CharacterSet(charactersIn: ":,;- "))
                break
            }
        }
        text = stripMatchingQuotes(text)
        guard !text.isEmpty else { return nil }
        return text
    }

    private static func stripLeadingPoliteness(_ text: String) -> Substring {
        var result = text[...]
        var changed = true
        while changed {
            changed = false
            for prefix in [
                "please ",
                "hey attaché, ",
                "hey attache, ",
                "attaché, ",
                "attache, ",
                "can you ",
                "could you ",
                "would you ",
                "will you "
            ] {
                if result.hasPrefix(prefix) {
                    result = result.dropFirst(prefix.count)
                    changed = true
                }
            }
        }
        return result
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func stripMatchingQuotes(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        let pairs: [(Character, Character)] = [
            ("\"", "\""),
            ("'", "'"),
            ("“", "”")
        ]
        for (open, close) in pairs where text.first == open && text.last == close {
            return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
