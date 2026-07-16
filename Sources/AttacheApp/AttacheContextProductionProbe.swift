import AttacheCore
import CryptoKit
import Foundation

/// Offline release probe for the exact provider payloads produced by the
/// packaged executable. This is deliberately a command-line affordance rather
/// than an alternate request builder: every artifact comes from
/// `AttacheProductionRequestBroker.compile`, the same compiled-only boundary
/// used immediately before HTTP or CLI transport.
enum AttacheContextProductionProbe {
    private struct Entry: Codable {
        let role: String
        let transport: String
        let relativePath: String
        let sha256: String
        let model: String
        let userSentinel: String
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let roleCount: Int
        let entries: [Entry]
    }

    static func generate(at outputURL: URL) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL)
        try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let broker = AttacheProductionRequestBroker()
        var entries: [Entry] = []
        for role in AttacheRequestRole.allCases {
            for provider in [
                AttachePresentationProvider.custom,
                AttachePresentationProvider.claudeCLI
            ] {
                let transport = provider == .custom ? "http" : provider.rawValue
                let userSentinel = "ATTACHE_CONTEXT_PROBE_\(role.rawValue)_\(transport)"
                let model = "probe-\(role.rawValue)-\(transport)"
                let settings = AttachePresentationSettings(
                    llmEnabled: true,
                    provider: provider,
                    baseURL: provider == .custom
                        ? URL(string: "https://context-probe.invalid/v1")!
                        : URL(string: "http://127.0.0.1")!,
                    apiKey: provider == .custom ? "synthetic-probe-key" : "",
                    apiKeySecretRef: "",
                    model: model,
                    reasoningEffort: "low",
                    serviceTier: nil,
                    profilePrompt: ""
                )
                let toolDefinitions = role == .conversation
                    ? try AttacheProductionRequestBroker.conversationToolDefinitions(
                        allowSessionContextTools: true,
                        allowAgentInstructionTool: true,
                        allowMemoryProposalTool: true
                    )
                    : Data()
                // Session tools are possible only with an explicit frozen
                // focus grant. Keep the probe internally valid instead of
                // serializing an impossible context-free/tool-bearing request.
                let focusedSession = AttacheFocusedSession(
                    sessionID: "context-probe-focused-session",
                    sourceKind: "codex",
                    displayTitle: "Synthetic focused context probe",
                    workingDirectory: "/synthetic/context-probe",
                    authorizationEpoch: AttacheFocusEpoch(1)
                )
                let focusedAuthorization = AttacheSessionAuthorization.focused(focusedSession)
                let session: AttacheSessionAuthorization = AttacheRequestAuthority
                    .roleMayUseSessionContext(role, authorization: focusedAuthorization)
                    ? focusedAuthorization
                    : .contextFree
                var contextItems = [AttacheContextItem(
                    source: .durableMemory,
                    content: "Synthetic memory fixture for provider serialization.",
                    provenance: "context-probe",
                    priority: 500,
                    treatment: .headTailExcerpt
                )]
                if session.isFocused {
                    contextItems.append(AttacheContextItem(
                        source: .focusedSessionMetadata,
                        content: "Focused session: Synthetic focused context probe (codex)",
                        provenance: "context-probe-focused-session",
                        authorization: session,
                        priority: 600,
                        treatment: .exactOnly
                    ))
                }
                let attempt = AttacheFrozenModelAttempt(
                    role: role,
                    settings: settings,
                    capability: AttacheModelCapabilityProfile(
                        architecturalMaximum: 64_000,
                        outputLimit: 4_096,
                        confidence: .authoritative,
                        provenance: .providerMetadata
                    ),
                    strategy: .automatic,
                    toolDefinitionsJSON: toolDefinitions
                )
                let snapshot = AttacheRequestSnapshot(
                    requestID: "probe-\(role.rawValue)-\(transport)",
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    role: role,
                    personality: Personality(
                        id: "context-probe",
                        name: "Context Probe",
                        prompt: "Keep the synthetic probe response concise."
                    ),
                    profilePrompt: "Keep the synthetic probe response concise.",
                    userInput: userSentinel,
                    session: session,
                    modelSettings: settings,
                    contextItems: contextItems,
                    contextStrategy: .automatic
                )
                let compiled = try broker.compile(
                    snapshot: snapshot,
                    attempt: attempt,
                    messages: [
                        AttacheChatMessage(
                            role: "system",
                            content: "Keep the synthetic probe response concise."
                        ),
                        AttacheChatMessage(role: "user", content: userSentinel)
                    ]
                )
                guard compiled.modelIdentity == attempt.modelIdentity,
                      compiled.receipt.modelIdentityKey == attempt.modelIdentity.capabilityKey else {
                    throw ProbeError.invalidArtifact("model identity drifted for \(role.rawValue)/\(transport)")
                }

                let fileExtension = provider == .custom ? "json" : "txt"
                let relativePath = "\(transport)/\(role.rawValue).\(fileExtension)"
                let artifactURL = outputURL.appendingPathComponent(relativePath)
                try fileManager.createDirectory(
                    at: artifactURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try compiled.serializedOutboundRequest.write(to: artifactURL, options: .atomic)
                entries.append(Entry(
                    role: role.rawValue,
                    transport: transport,
                    relativePath: relativePath,
                    sha256: digest(compiled.serializedOutboundRequest),
                    model: model,
                    userSentinel: userSentinel
                ))
            }
        }

        let manifest = Manifest(
            schemaVersion: 1,
            roleCount: AttacheRequestRole.allCases.count,
            entries: entries.sorted {
                ($0.transport, $0.role) < ($1.transport, $1.role)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(
            to: outputURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        try verify(at: outputURL)
    }

    static func verify(at outputURL: URL) throws {
        let manifestURL = outputURL.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.schemaVersion == 1,
              manifest.roleCount == AttacheRequestRole.allCases.count else {
            throw ProbeError.invalidArtifact("manifest role inventory is stale")
        }
        let expectedCount = AttacheRequestRole.allCases.count * 2
        guard manifest.entries.count == expectedCount else {
            throw ProbeError.invalidArtifact(
                "expected \(expectedCount) provider artifacts, found \(manifest.entries.count)"
            )
        }

        let roleNames = Set(AttacheRequestRole.allCases.map(\.rawValue))
        let transports = ["http", "claude_cli"]
        for transport in transports {
            let covered = Set(
                manifest.entries
                    .filter { $0.transport == transport }
                    .map(\.role)
            )
            guard covered == roleNames else {
                throw ProbeError.invalidArtifact("\(transport) does not cover every request role")
            }
        }

        for entry in manifest.entries {
            let artifactURL = outputURL.appendingPathComponent(entry.relativePath)
            let data = try Data(contentsOf: artifactURL)
            guard digest(data) == entry.sha256 else {
                throw ProbeError.invalidArtifact("artifact hash mismatch: \(entry.relativePath)")
            }
            let serialized = String(decoding: data, as: UTF8.self)
            if entry.role == AttacheRequestRole.conversation.rawValue {
                guard serialized.contains("read_session_transcript"),
                      serialized.contains("Synthetic focused context probe") else {
                    throw ProbeError.invalidArtifact(
                        "focused conversation authority or tools missing: \(entry.relativePath)"
                    )
                }
            } else if serialized.contains("read_session_transcript") {
                throw ProbeError.invalidArtifact(
                    "session tools leaked into context-free role: \(entry.relativePath)"
                )
            }
            if entry.transport == "http" {
                guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      payload["model"] as? String == entry.model,
                      let messages = payload["messages"] as? [[String: Any]],
                      messages.contains(where: {
                          $0["role"] as? String == "user"
                              && ($0["content"] as? String)?.contains(entry.userSentinel) == true
                      }) else {
                    throw ProbeError.invalidArtifact("invalid HTTP payload: \(entry.relativePath)")
                }
            } else {
                let prompt = String(decoding: data, as: UTF8.self)
                guard prompt.contains(entry.userSentinel),
                      prompt.contains("Respond as the assistant with your reply only.") else {
                    throw ProbeError.invalidArtifact("invalid CLI prompt: \(entry.relativePath)")
                }
            }
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum ProbeError: LocalizedError {
        case invalidArtifact(String)

        var errorDescription: String? {
            switch self {
            case .invalidArtifact(let detail): return detail
            }
        }
    }
}
