import AttacheCore
import CryptoKit
import Foundation

/// Immutable authorization for one explicit Another Take request (INF-336).
///
/// Ordinary personality selection never creates one of these. The only callers
/// are the explicit Another Take action and the legacy live-clarification path.
/// The content digest binds the authorization to the exact card bytes that the
/// model will see, rather than trusting a reusable card id by itself.
struct AnotherTakeRequestAuthorization: Equatable, Sendable {
    enum Scope: Equatable, Sendable {
        case explicitCard
        case liveCall(callID: UUID, focusedSessionID: String)
    }

    let cardID: String
    let sourceKind: String
    let externalSessionID: String?
    let contentDigest: String
    let scope: Scope

    static func explicit(card: VoicemailCard) -> AnotherTakeRequestAuthorization {
        AnotherTakeRequestAuthorization(
            cardID: card.id,
            sourceKind: card.sourceKind,
            externalSessionID: card.externalSessionID,
            contentDigest: digest(for: card),
            scope: .explicitCard
        )
    }

    static func live(
        card: VoicemailCard,
        callID: UUID,
        focusedSessionID: String
    ) -> AnotherTakeRequestAuthorization {
        AnotherTakeRequestAuthorization(
            cardID: card.id,
            sourceKind: card.sourceKind,
            externalSessionID: card.externalSessionID,
            contentDigest: digest(for: card),
            scope: .liveCall(callID: callID, focusedSessionID: focusedSessionID)
        )
    }

    func authorizes(_ card: VoicemailCard) -> Bool {
        guard card.id == cardID,
              card.sourceKind == sourceKind,
              card.externalSessionID == externalSessionID,
              Self.digest(for: card) == contentDigest else {
            return false
        }
        if case .liveCall(_, let focusedSessionID) = scope {
            return card.externalSessionID == focusedSessionID
        }
        return true
    }

    private static func digest(for card: VoicemailCard) -> String {
        let material = [
            card.id,
            card.sourceKind,
            card.externalSessionID ?? "",
            card.rawText,
            card.spokenText
        ].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// A thread-safe, per-user-turn ledger for irreversible model tool effects
/// (INF-337). The same instance is captured by every tool round and retained
/// when the turn is retried on a fallback provider. Each effect kind may be
/// claimed once; later model calls receive a deterministic refusal.
final class ConversationTurnEffectLedger: @unchecked Sendable {
    enum Effect: String, Hashable, Sendable {
        case renameSession = "rename_session"
        case agentInstruction = "stage_agent_instruction"
        case memoryProposal = "propose_memory"
        case sessionDiscovery = "request_session_search"
    }

    private let lock = NSLock()
    private var claimedEffects: Set<Effect> = []
    private var attemptCounts: [Effect: Int] = [:]

    @discardableResult
    func claim(_ effect: Effect) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return claimedEffects.insert(effect).inserted
    }

    func contains(_ effect: Effect) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return claimedEffects.contains(effect)
    }

    /// Counts an attempt at an effect without consuming its once-per-turn
    /// claim, so a rejected attempt (which had no side effect) can be retried.
    /// Returns false once the cap for this turn is exhausted or the effect was
    /// already claimed. The claim itself still happens only when the effect
    /// actually occurs.
    @discardableResult
    func registerAttempt(_ effect: Effect, cap: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimedEffects.contains(effect) else { return false }
        let next = (attemptCounts[effect] ?? 0) + 1
        guard next <= cap else { return false }
        attemptCounts[effect] = next
        return true
    }

    func attemptCount(_ effect: Effect) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return attemptCounts[effect] ?? 0
    }

    var hasEffects: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !claimedEffects.isEmpty
    }
}

/// Consent identity for a model egress destination (INF-342). Consent follows
/// the normalized endpoint and its current egress class, never just a provider
/// label such as "Custom".
struct PresentationConsentScope: Equatable, Hashable, Sendable {
    static let storageVersion = "v2"

    let provider: AttachePresentationProvider
    let normalizedEndpoint: String
    let egress: AttacheDataEgress

    init(provider: AttachePresentationProvider, endpoint: String) {
        self.provider = provider
        // Subscription CLIs have no Attaché-selected network destination. Use
        // one stable sentinel rather than the placeholder URL required by the
        // settings value, so Settings and the request gate derive the same key.
        normalizedEndpoint = provider.isCLI ? Self.normalize("") : Self.normalize(endpoint)
        egress = provider.dataEgress(endpoint: normalizedEndpoint)
    }

    var storageKey: String {
        let digest = SHA256.hash(data: Data(normalizedEndpoint.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(Self.storageVersion)|\(provider.rawValue)|\(egress.rawValue)|\(digest)"
    }

    static func isScopedStorageKey(_ value: String) -> Bool {
        value.hasPrefix("\(storageVersion)|")
    }

    static func normalize(_ rawEndpoint: String) -> String {
        let trimmed = rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "<none>" }
        guard var components = URLComponents(string: trimmed) else {
            return trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.user = nil
        components.password = nil
        components.fragment = nil
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string ?? trimmed.lowercased()
    }
}

/// Consent identity for a speech egress destination. Voice consent is bound to
/// both the provider and the exact normalized endpoint, so an imported
/// personality cannot reuse approval for xAI's normal API against a different
/// host. The fixed providers intentionally ignore caller-supplied endpoints.
struct VoiceConsentScope: Equatable, Hashable, Sendable {
    static let storageVersion = "voice-v1"

    let provider: AttacheSpeechProvider
    let normalizedEndpoint: String

    init(provider: AttacheSpeechProvider, xaiBaseURL: String? = nil) {
        self.provider = provider
        normalizedEndpoint = PresentationConsentScope.normalize(
            Self.endpoint(for: provider, xaiBaseURL: xaiBaseURL)
        )
    }

    var storageKey: String {
        let digest = SHA256.hash(data: Data(normalizedEndpoint.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(Self.storageVersion)|\(provider.rawValue)|\(digest)"
    }

    static func isScopedStorageKey(_ value: String) -> Bool {
        value.hasPrefix("\(storageVersion)|")
    }

    static func endpoint(for provider: AttacheSpeechProvider, xaiBaseURL: String?) -> String {
        switch provider {
        case .system, .attachePremium:
            return "<on-device>"
        case .elevenLabs:
            return "https://api.elevenlabs.io"
        case .xai:
            return xaiBaseURL ?? "https://api.x.ai/v1"
        case .openai:
            return "https://api.openai.com"
        }
    }
}
