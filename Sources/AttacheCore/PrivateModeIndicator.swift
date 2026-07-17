import Foundation

/// Pure copy and state rules for the incognito identity indicators (INF-356):
/// the character's crown band, the call HUD's PRIVATE chip, and the
/// VoiceOver announcements that fire on entering and leaving a private call.
/// Kept here, not in AttacheApp, so the state-driven visibility and copy
/// selection are unit-testable without a live app instance.
public enum PrivateModeIndicator {
    /// Every incognito indicator (crown band, PRIVATE chip) is visible
    /// exactly when the conversation is private; there is no independent
    /// on/off switch per indicator. Trivial today, but named so a future
    /// per-indicator override has one place to change without hunting every
    /// call site that currently writes `isPrivateConversation` directly.
    public static func indicatorsVisible(isPrivateConversation: Bool) -> Bool {
        isPrivateConversation
    }

    /// The PRIVATE chip's tooltip, derived from where the active model
    /// attempt's context actually goes (INF-356 step 2). Never a static
    /// disclosure: a local model promises more than a cloud one, so the
    /// copy must not overstate a cloud attempt's guarantee.
    public static func chipTooltip(modelIsLocal: Bool) -> String {
        modelIsLocal
            ? "Nothing leaves this Mac and no record is kept"
            : "No record is kept on this Mac; the model provider still receives the conversation"
    }

    /// VoiceOver announcement fired the moment a call becomes private,
    /// whether it started private or was switched mid-call (INF-355).
    public static let enteredAnnouncement = "Private call started, no record will be kept"

    /// VoiceOver announcement fired when a private call ends (hang-up is
    /// the only way out; there is no private-to-saved transition).
    public static let exitedAnnouncement = "Private call ended"
}
