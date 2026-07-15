import Foundation

/// Structural classification of a failed conversation/personality LLM call.
///
/// Lives in AttacheCore (not AttacheApp, where `ConversationRecovery.classify`
/// derives it) so testable AttacheCore logic - such as a future `CallPhase`
/// state machine - can reference the category without AttacheCore depending
/// on AttacheApp.
/// `String`-backed so a category can be stored as stable card metadata (e.g.
/// `attache_presentation_error_category`) and read back later without
/// re-classifying the original error text.
/// `CaseIterable` (INF-258/D5) so `ConversationFallbackChain.shouldTrigger`
/// can be proven correct against every case at once - in particular, that
/// `.auth` is never one of the categories that triggers auto-fallback -
/// instead of only against the cases a test happens to enumerate by hand.
public enum ConversationFailureCategory: String, Equatable, CaseIterable {
    /// 429/402 usage or rate-limit responses, or (CLI providers only) text
    /// markers like "usage limit" / "quota".
    case usageOrRateLimit = "usage_or_rate_limit"
    /// 404, or 400 with a model-name marker in the body, or (CLI providers
    /// only) text markers naming an unavailable model.
    case modelUnavailable = "model_unavailable"
    /// Timeout/connection-lost transport errors, or 5xx responses. Recoverable
    /// and safe to retry or auto-fallback.
    case transient
    /// 401/403 authentication/authorization failures. Never auto-recovered;
    /// the user has to fix credentials.
    case auth
    case other
}
