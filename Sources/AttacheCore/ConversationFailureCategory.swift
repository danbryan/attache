import Foundation

/// Structural classification of a failed conversation/personality LLM call.
///
/// Lives in AttacheCore (not AttacheApp, where `ConversationRecovery.classify`
/// derives it) so testable AttacheCore logic - such as a future `CallPhase`
/// state machine - can reference the category without AttacheCore depending
/// on AttacheApp.
public enum ConversationFailureCategory: Equatable {
    /// 429/402 usage or rate-limit responses, or (CLI providers only) text
    /// markers like "usage limit" / "quota".
    case usageOrRateLimit
    /// 404, or 400 with a model-name marker in the body, or (CLI providers
    /// only) text markers naming an unavailable model.
    case modelUnavailable
    /// Timeout/connection-lost transport errors, or 5xx responses. Recoverable
    /// and safe to retry or auto-fallback.
    case transient
    /// 401/403 authentication/authorization failures. Never auto-recovered;
    /// the user has to fix credentials.
    case auth
    case other
}
