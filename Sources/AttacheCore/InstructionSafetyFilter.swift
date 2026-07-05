import Foundation

/// Refuses instructions that are really agent-side permission or tool approvals.
/// Two-way must never let Attaché click through an agent's permission prompt on
/// the user's behalf (docs/two-way.md safety rules). This is a content-level check
/// independent of any adapter.
public enum InstructionSafetyFilter {
    /// Bare approval tokens: a payload that is *only* one of these is an approval,
    /// not an instruction.
    private static let approvalTokens: Set<String> = [
        "y", "yes", "yep", "yeah", "yup", "ok", "okay", "sure", "approve",
        "approved", "allow", "allowed", "accept", "confirm", "confirmed",
        "proceed", "continue", "go", "go ahead", "do it", "1", "2", "3"
    ]

    /// Phrases that request granting the agent a permission, bypassing its sandbox,
    /// or approving tool use. Matched anywhere in the text.
    private static let grantPhrases: [String] = [
        "approve the", "approve this", "allow the", "allow it to", "grant permission",
        "grant access", "give it permission", "bypass the sandbox", "bypass sandbox",
        "disable the sandbox", "skip the confirmation", "skip confirmation",
        "auto-approve", "auto approve", "always allow", "yes to all", "approve all",
        "allow all tools", "enable full access", "danger", "--dangerously"
    ]

    /// A human-readable reason to refuse, or nil if the instruction is allowed.
    public static func rejectionReason(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "The instruction is empty."
        }
        let normalized = trimmed.lowercased()
        // Strip trailing punctuation for the bare-token check ("yes." -> "yes").
        let bare = normalized.trimmingCharacters(in: CharacterSet(charactersIn: ".!, "))
        if approvalTokens.contains(bare) {
            return "That looks like an approval, not an instruction. Attaché won't approve permissions or tool use on the agent's behalf; do that directly in the agent."
        }
        for phrase in grantPhrases where normalized.contains(phrase) {
            return "That asks the agent to grant a permission or bypass a safeguard. Attaché won't deliver permission or sandbox approvals; handle those directly in the agent."
        }
        return nil
    }

    public static func isAllowed(_ text: String) -> Bool {
        rejectionReason(for: text) == nil
    }
}
