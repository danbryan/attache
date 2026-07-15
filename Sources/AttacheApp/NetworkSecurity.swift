import Foundation

enum NetworkSecurity {
    /// Only attach a Bearer credential when the destination is https or loopback,
    /// so a misconfigured base URL can't leak an API key in cleartext to a
    /// third-party or attacker-controlled host. Local model servers (Ollama,
    /// Ollama runs over http on loopback and carries no key, so it is allowed.
    static func allowsBearer(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        return isLoopbackHost(url.host)
    }

    /// True for the loopback hosts local model servers such as Ollama,
    /// so they're never treated as "data leaves this Mac".
    static func isLoopbackHost(_ host: String?) -> Bool {
        switch host?.lowercased() {
        case "localhost", "127.0.0.1", "::1", "[::1]":
            return true
        default:
            return false
        }
    }

    /// True when a configured base URL points off this machine, i.e. selecting it
    /// will send data to a third party. Empty or unparseable text is treated as
    /// not-cloud (nothing to send to yet).
    static func isCloudEndpoint(_ urlText: String) -> Bool {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            return false
        }
        return !isLoopbackHost(host)
    }
}
