import AttacheCore
import Foundation

/// Opt-in auto-fallback chain for the live call's conversation model
/// (INF-258/D5). Mirrors the shape of the existing deterministic voice
/// playback fallback (`AttacheSpeechConfiguration.resolvedForPlayback`,
/// `AttacheSpeechProvider.swift:82-117`): a reason the current choice can't
/// be used, and a deterministic, independently-testable rule for what to use
/// instead. See docs/reviews/2026-07-10-app-review.md section 4 item 3.
///
/// Conversation role only (spec scope): presentation/recap/tagging keep their
/// existing silent-degrade or manual-recovery behavior.
enum ConversationFallbackChain {
    /// Whether a failure category should ever trigger auto-fallback.
    /// `.auth` must NEVER trigger: switching providers on an auth failure
    /// would hide a problem the user actually needs to fix (docs/reviews
    /// section 4 item 3). `.other` also never triggers: it is "we don't know
    /// what this is," which is not the same thing as "safe to retry
    /// elsewhere." Exhaustive over every `ConversationFailureCategory` case
    /// (not `default`) so a new case forces a decision here instead of
    /// silently falling on one side or the other.
    static func shouldTrigger(for category: ConversationFailureCategory) -> Bool {
        switch category {
        case .usageOrRateLimit, .modelUnavailable, .transient:
            return true
        case .auth, .other:
            return false
        }
    }

    /// Finds the first entry in `chain` that is not the provider that just
    /// failed, is configured (has credentials, or needs none), and is
    /// consented (cloud data-residency consent already acknowledged, or the
    /// provider never sends to the cloud). Returns `nil` when the chain is
    /// exhausted: every remaining entry is unconfigured, unconsented, or is
    /// the provider that just failed.
    ///
    /// Never prompts for consent itself (spec: "do not re-prompt for consent
    /// mid-fallback"); an unconsented candidate is simply skipped, same as an
    /// unconfigured one.
    static func nextCandidate(
        chain: [AttachePresentationProvider],
        failedProvider: AttachePresentationProvider,
        isConfigured: (AttachePresentationProvider) -> Bool,
        isConsented: (AttachePresentationProvider) -> Bool
    ) -> AttachePresentationProvider? {
        for candidate in chain {
            guard candidate != failedProvider else { continue }
            guard isConfigured(candidate) else { continue }
            guard isConsented(candidate) else { continue }
            return candidate
        }
        return nil
    }

    /// The status-line text and spoken sentence for one fallback hop, e.g.
    /// "xAI / Grok hit its usage limit; using Ollama for now." Never contains
    /// an em dash (AGENTS.md "Never emit em dashes in spoken output"); this is
    /// a fixed template over provider titles, which never contain one either,
    /// but it still runs through `AttachePersonality.stripDashes` so the
    /// guarantee is structural, not just "true today."
    static func announcement(
        category: ConversationFailureCategory,
        failedProviderTitle: String,
        fallbackProviderTitle: String
    ) -> String {
        let problem: String
        switch category {
        case .usageOrRateLimit:
            problem = "hit its usage limit"
        case .modelUnavailable:
            problem = "model is unavailable"
        case .transient:
            problem = "had a connection issue"
        case .auth, .other:
            // Never reached in practice: shouldTrigger(for:) excludes both
            // categories, so `ConversationFallbackState.advance` never gets
            // here for them. Kept exhaustive (not `default`) for the same
            // reason as shouldTrigger above.
            problem = "is unavailable"
        }
        let sentence = "\(failedProviderTitle) \(problem); using \(fallbackProviderTitle) for now."
        return AttachePersonality.stripDashes(sentence)
    }
}

/// Tracks the auto-fallback chain's state for one live call. Pure and
/// `AppModel`-independent so the sticky/reset/advance rules are directly
/// unit-testable; `AppModel` owns one instance and resets it at the start of
/// every call (`startConversation()`), never mid-call.
struct ConversationFallbackState: Equatable {
    /// The provider currently acting as the fallback, once one has been
    /// triggered this call. `nil` means the configured/primary provider is
    /// still in effect, either because fallback hasn't triggered yet or
    /// because it's disabled.
    private(set) var activeProvider: AttachePresentationProvider?

    /// True once a fallback has been triggered this call. Distinct wording
    /// from `activeProvider != nil` only for readability at call sites (spec:
    /// "sticky for the rest of the call, do not re-evaluate the chain again
    /// mid-call once a fallback is active").
    var hasFallenBackThisCall: Bool { activeProvider != nil }

    /// Resets to "no fallback active." Called at the start of every call so
    /// the primary provider is retried automatically on the next call, never
    /// mid-call.
    mutating func reset() {
        activeProvider = nil
    }

    /// Decides whether and where to fall back after a failed conversation
    /// attempt. Returns `nil` (no state change) when: `enabled` is false, a
    /// fallback is already active this call (sticky - this is the "do not
    /// re-evaluate the chain again" rule, so a second failure this call
    /// always falls through to manual recovery instead of hopping again),
    /// the category never triggers auto-fallback, or the chain is exhausted.
    /// On success, records the new `activeProvider` (sticky for the rest of
    /// the call) and returns it.
    @discardableResult
    mutating func advance(
        enabled: Bool,
        category: ConversationFailureCategory,
        chain: [AttachePresentationProvider],
        failedProvider: AttachePresentationProvider,
        isConfigured: (AttachePresentationProvider) -> Bool,
        isConsented: (AttachePresentationProvider) -> Bool
    ) -> AttachePresentationProvider? {
        guard enabled, !hasFallenBackThisCall, ConversationFallbackChain.shouldTrigger(for: category) else {
            return nil
        }
        guard let candidate = ConversationFallbackChain.nextCandidate(
            chain: chain,
            failedProvider: failedProvider,
            isConfigured: isConfigured,
            isConsented: isConsented
        ) else {
            return nil
        }
        activeProvider = candidate
        return candidate
    }
}
