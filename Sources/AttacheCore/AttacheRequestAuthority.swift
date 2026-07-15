import Foundation

/// Every model-backed role in Attaché. One enum so the request snapshot can
/// name exactly which role a frozen request serves, and so isolation tests can
/// table-drive every role (INF-304). Broader than `ModelRole` because it also
/// covers narration-only roles (another-take, preview, live follow-up) that are
/// not per-task model-recovery roles.
public enum AttacheRequestRole: String, Equatable, Sendable, CaseIterable {
    case presentation
    case conversation
    case recap
    case followUp
    case liveFollowUp
    case anotherTake
    case preview
    case topicTagging
}

/// The session authorization frozen into a request snapshot. This is the
/// authority boundary: a request either carries an explicitly focused session
/// (with its identity frozen at capture time) or it is context-free and may
/// carry no work-session evidence or tools. Reconnect, watched activity,
/// Command-K search, or a later selection can never mutate a frozen value.
public enum AttacheSessionAuthorization: Equatable, Sendable {
    case contextFree
    case focused(AttacheFocusedSession)

    public var isFocused: Bool {
        if case .focused = self { return true }
        return false
    }

    public var focusedSession: AttacheFocusedSession? {
        if case .focused(let session) = self { return session }
        return nil
    }
}

/// The frozen identity of one explicitly focused session. Separate from the
/// reverse-send destination, which is its own safety object (INF-304).
public struct AttacheFocusedSession: Equatable, Sendable {
    public let sessionID: String
    public let sourceKind: String
    public let displayTitle: String
    public let workingDirectory: String?

    public init(sessionID: String, sourceKind: String, displayTitle: String, workingDirectory: String?) {
        self.sessionID = sessionID
        self.sourceKind = sourceKind
        self.displayTitle = displayTitle
        self.workingDirectory = workingDirectory
    }
}

/// Pure authority resolution for every model request (INF-304).
///
/// One precedence rule governs the personality prompt a request uses:
///   1. explicit test/environment override
///   2. the selected personality's prompt
///   3. a migrated legacy prompt, only when no selected value exists
///   4. a safe built-in default
///
/// The legacy file store is a migration input, not a competing runtime
/// authority. A sentinel that selects one personality while legacy state
/// contains another must always resolve to the selected personality's prompt.
public enum AttacheRequestAuthority {
    /// Resolve the profile prompt for a request using the single precedence rule.
    /// Pure and deterministic so isolation tests can assert it per role.
    public static func resolvedProfilePrompt(
        testOverride: String?,
        selectedPersonalityPrompt: String,
        migratedLegacyPrompt: String?,
        fallback: String = AttachePersonality.defaultProfilePrompt
    ) -> String {
        if let override = testOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        let selected = selectedPersonalityPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty { return selected }
        if let migrated = migratedLegacyPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !migrated.isEmpty {
            return migrated
        }
        return fallback
    }

    /// Resolve the active personality for a request. The selected personality
    /// wins; a migrated legacy personality only stands in when nothing is
    /// selected, and the built-in Attaché personality is the final fallback.
    /// Returns the personality id and prompt the snapshot should freeze.
    public static func resolvedPersonality(
        selected: (id: String, prompt: String)?,
        migratedLegacy: (id: String, prompt: String)?,
        fallbackID: String = "builtin.bigPicture",
        fallbackPrompt: String = AttachePersonality.defaultProfilePrompt
    ) -> (id: String, prompt: String) {
        if let selected, !selected.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let prompt = resolvedProfilePrompt(
                testOverride: nil,
                selectedPersonalityPrompt: selected.prompt,
                migratedLegacyPrompt: nil,
                fallback: fallbackPrompt
            )
            return (selected.id, prompt)
        }
        if let migrated = migratedLegacy, !migrated.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let prompt = resolvedProfilePrompt(
                testOverride: nil,
                selectedPersonalityPrompt: migrated.prompt,
                migratedLegacyPrompt: nil,
                fallback: fallbackPrompt
            )
            return (migrated.id, prompt)
        }
        return (fallbackID, fallbackPrompt)
    }

    /// True when a role is allowed to see focused-session context. Topic tagging
    /// is deliberately neutral: it may run, but it never inherits a focused
    /// session's evidence or another personality's context.
    public static func roleMayUseSessionContext(_ role: AttacheRequestRole, authorization: AttacheSessionAuthorization) -> Bool {
        guard authorization.isFocused else { return false }
        switch role {
        case .topicTagging:
            return false
        case .presentation, .conversation, .recap, .followUp, .liveFollowUp, .anotherTake, .preview:
            return true
        }
    }
}