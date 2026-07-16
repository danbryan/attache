import Foundation
import Darwin

/// Where a model request's context actually goes (INF-307). Consent and privacy
/// copy must describe this accurately: a locally launched CLI that sends prompts
/// to a subscription service is not on-device. Pure and testable so the same
/// classification drives onboarding, settings, personality selection, consent,
/// memory egress, and diagnostics.
public enum AttacheDataEgress: String, Equatable, Sendable, CaseIterable {
    /// No network at all; context never leaves the Mac.
    case onDevice
    /// Loopback only (127.0.0.1, ::1, localhost). Local to this Mac.
    case loopback
    /// A private LAN host (10/8, 172.16/12, 192.168/16, *.local, link-local).
    /// Stays on the home network but leaves this Mac.
    case localNetwork
    /// A known hosted API (xAI, Groq, Anthropic, OpenAI, ...). Leaves the Mac
    /// for a configured remote service.
    case configuredRemote
    /// A CLI that runs locally but sends prompts to a subscription service
    /// (Codex CLI, Claude Code CLI). Leaves the Mac even though the binary is local.
    case subscriptionRemoteCLI
    /// A custom OpenAI-compatible endpoint whose locality is not yet established.
    /// Fails closed to remote/unknown disclosure until endpoint rules or explicit
    /// user confirmation classifies it.
    case unknownCustom
    /// No model path is active.
    case disabled

    /// True when context may leave this Mac. Loopback and on-device do not.
    public var isRemote: Bool {
        switch self {
        case .onDevice, .loopback, .disabled: return false
        case .localNetwork, .configuredRemote, .subscriptionRemoteCLI, .unknownCustom: return true
        }
    }

    /// True when context stays on this Mac (no network, or loopback only).
    public var isLocal: Bool {
        switch self {
        case .onDevice, .loopback: return true
        case .localNetwork, .configuredRemote, .subscriptionRemoteCLI, .unknownCustom, .disabled: return false
        }
    }

    /// True when context goes to a remote service rather than staying on this Mac
    /// or the home LAN. Used for consent: a LAN host leaves the Mac but is not a
    /// remote service, so `isRemoteService` is false for `.localNetwork` even
    /// though `isRemote` is true.
    public var isRemoteService: Bool {
        switch self {
        case .onDevice, .loopback, .localNetwork, .disabled: return false
        case .configuredRemote, .subscriptionRemoteCLI, .unknownCustom: return true
        }
    }

    /// A short, user-facing label for consent and settings copy. Never exposes
    /// credentials, endpoints, or prompt content.
    public var disclosureLabel: String {
        switch self {
        case .onDevice: return "On-device"
        case .loopback: return "Local (this Mac)"
        case .localNetwork: return "Local network"
        case .configuredRemote: return "Remote service"
        case .subscriptionRemoteCLI: return "Subscription (remote)"
        case .unknownCustom: return "Unknown endpoint (treat as remote)"
        case .disabled: return "Off"
        }
    }

    /// The kinds of context that may leave the Mac under any remote egress, so
    /// consent copy can name them without revealing content.
    public static let dataCategories: [String] = [
        "your turn",
        "the personality prompt",
        "authorized session excerpts",
        "retrieved files",
        "durable memory",
        "tool results"
    ]
}

/// Pure egress classification and consent-transition logic (INF-307). The App
/// maps its provider enum and configured endpoint into these inputs; the
/// classifier never touches credentials, HTTP, or provider SDKs.
public enum AttacheDataEgressClassifier {
    /// Known hosted APIs that always send to a configured remote service.
    public static let hostedProviderRawValues: Set<String> = ["xai", "groq", "openai", "anthropic", "elevenlabs"]

    /// Classify where a model path sends context.
    /// - Parameters:
    ///   - providerRawValue: the provider id (e.g. "ollama", "xai", "custom",
    ///     "codex_cli", "claude_cli").
    ///   - endpoint: the resolved base URL string (may be empty for CLI paths).
    ///   - isCLI: true when the provider runs a local CLI binary that talks to a
    ///     subscription service.
    ///   - enabled: false when the model path is off.
    public static func classify(
        providerRawValue: String,
        endpoint: String?,
        isCLI: Bool,
        enabled: Bool
    ) -> AttacheDataEgress {
        guard enabled else { return .disabled }
        if isCLI { return .subscriptionRemoteCLI }
        let provider = providerRawValue.lowercased()
        if hostedProviderRawValues.contains(provider) { return .configuredRemote }
        // Ollama and custom OpenAI-compatible endpoints are classified by their
        // resolved endpoint, not the provider name alone (INF-307).
        let locality = endpointLocality(endpoint)
        let isCustom = provider == "custom"
        switch locality {
        case .loopback:
            return .loopback
        case .localNetwork:
            return .localNetwork
        case .remote:
            // Ollama knowingly pointed at a remote host is a configured remote.
            // A custom endpoint at a remote host fails closed to unknown until
            // the user confirms its trust class.
            return isCustom ? .unknownCustom : .configuredRemote
        case .unknown:
            // Malformed or missing endpoint: fail closed.
            return isCustom ? .unknownCustom : .loopback
        }
    }

    /// Whether a change in egress requires re-consent before the next
    /// context-bearing request. Material changes are any local-to-remote (or
    /// remote-to-local) transition, any change involving an unknown custom
    /// endpoint's trust class, and any enable/disable transition.
    public static func requiresReconsent(from: AttacheDataEgress, to: AttacheDataEgress) -> Bool {
        if from == to { return false }
        if from == .disabled || to == .disabled { return true }
        if from.isRemoteService != to.isRemoteService { return true }
        if from == .unknownCustom || to == .unknownCustom { return true }
        return false
    }

    /// The locality of a resolved endpoint host. Pure; no DNS resolution so the
    /// classifier is deterministic and testable.
    public static func endpointLocality(_ endpoint: String?) -> AttacheEndpointLocality {
        guard let endpoint, !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unknown
        }
        guard let host = host(from: endpoint) else { return .unknown }
        let lower = host.lowercased()
        if lower == "localhost" { return .loopback }
        if lower.hasSuffix(".local") { return .localNetwork }

        // CIDR rules apply only to syntactically complete IP literals. Prefix
        // checks alone let ordinary DNS names such as `127.evil.example` or
        // `fdomain.example` masquerade as local and bypass remote consent.
        if let bytes = ipv4Bytes(lower) {
            if bytes[0] == 127 || bytes == [0, 0, 0, 0] { return .loopback }
            if bytes[0] == 10
                || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 169 && bytes[1] == 254) {
                return .localNetwork
            }
            return .remote
        }
        if let bytes = ipv6Bytes(lower) {
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            if isLoopback { return .loopback }
            let isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 // fe80::/10
            let isUniqueLocal = (bytes[0] & 0xfe) == 0xfc // fc00::/7
            return (isLinkLocal || isUniqueLocal) ? .localNetwork : .remote
        }
        return .remote
    }

    /// Extract a host from a URL string, tolerating schemes and ports.
    static func host(from endpoint: String) -> String? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "attache://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else { return nil }
        return host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func ipv4Bytes(_ host: String) -> [UInt8]? {
        var address = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }
}

/// The locality of a resolved endpoint, used to classify Ollama and custom
/// endpoints (INF-307). Pure and deterministic.
public enum AttacheEndpointLocality: String, Equatable, Sendable {
    case loopback
    case localNetwork
    case remote
    case unknown
}
