import AttacheCore
import Foundation

/// Builds the model-facing tool definition objects for granted MCP tools, in
/// the same `{"type":"function","function":{...}}` shape as the built-in tools.
enum MCPToolOffering {
    static func toolObjects(descriptors: [MCPToolDescriptor]) -> [[String: Any]] {
        descriptors.map(toolObject(for:))
    }

    static func toolObject(for descriptor: MCPToolDescriptor) -> [String: Any] {
        let function: [String: Any] = [
            "name": descriptor.namespacedName,
            "description": descriptor.description,
            "parameters": parameters(from: descriptor.schemaJSON)
        ]
        return ["type": "function", "function": function]
    }

    /// Decode the tool's JSON schema string into an object usable as the
    /// function `parameters`. Falls back to an empty object schema when the
    /// server reported no schema or an unreadable one.
    static func parameters(from schemaJSON: String) -> [String: Any] {
        if let data = schemaJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           !object.isEmpty {
            return object
        }
        return ["type": "object", "properties": [String: Any]()]
    }
}

/// A pending ask-first confirmation, surfaced so a phase-2 sheet can bind to it.
/// The interactive approval path publishes one of these and suspends until the
/// UI (or a test) calls `resolve`.
final class PendingMCPApproval: Identifiable {
    let id = UUID()
    let descriptor: MCPToolDescriptor
    let argumentsJSON: String
    private var continuation: CheckedContinuation<MCPApprovalDecision, Never>?

    init(
        descriptor: MCPToolDescriptor,
        argumentsJSON: String,
        continuation: CheckedContinuation<MCPApprovalDecision, Never>
    ) {
        self.descriptor = descriptor
        self.argumentsJSON = argumentsJSON
        self.continuation = continuation
    }

    /// Resume the awaiting tool call exactly once. Later calls are ignored.
    func resolve(_ decision: MCPApprovalDecision) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: decision)
    }
}

/// Applies the MCP permission policy to a single tool call: clamps the grant,
/// requests approval for ask-first tools, persists an always-allow grant for
/// read-only tools only, and runs the tool. Injectable end to end so tests can
/// drive it without a live model, network, or subprocess.
final class MCPToolCallCoordinator {
    /// The approval hook for ask-first tools. Defaults to fail-closed deny; the
    /// app replaces it with an interactive handler, and tests set it directly.
    var approvalHandler: (MCPToolDescriptor, String) async -> MCPApprovalDecision

    private let performCall: (String, String) async throws -> String
    private let persistGrant: (String, MCPToolPermission) -> Void

    init(
        approvalHandler: @escaping (MCPToolDescriptor, String) async -> MCPApprovalDecision = { descriptor, _ in
            AttacheLog.mcp.info("mcp approval defaulted to deny tool=\(descriptor.toolName, privacy: .public)")
            return .deny
        },
        performCall: @escaping (String, String) async throws -> String,
        persistGrant: @escaping (String, MCPToolPermission) -> Void = { _, _ in }
    ) {
        self.approvalHandler = approvalHandler
        self.performCall = performCall
        self.persistGrant = persistGrant
    }

    /// Resolve permission, confirm if needed, and run the tool. Always returns a
    /// spoken-path-friendly result string; it never throws.
    func execute(
        descriptor: MCPToolDescriptor,
        grant: MCPToolPermission,
        isPrivateCall: Bool,
        argumentsJSON: String
    ) async -> String {
        let effective = MCPToolPolicy.effective(
            permission: grant,
            isReadOnly: descriptor.isReadOnly,
            isPrivateCall: isPrivateCall
        )
        switch effective {
        case .notOffered:
            return "The \(descriptor.toolName) tool is not available in this conversation."
        case .alwaysAllow:
            break
        case .askFirst:
            let decision = await approvalHandler(descriptor, argumentsJSON)
            switch decision {
            case .deny:
                return "The user declined the \(descriptor.toolName) lookup."
            case .allowOnce:
                break
            case .alwaysAllow:
                if let persistable = MCPToolPolicy.grantToPersist(afterAlwaysAllowFor: descriptor) {
                    persistGrant(descriptor.namespacedName, persistable)
                }
            }
        }
        do {
            return try await performCall(descriptor.namespacedName, argumentsJSON)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return "The \(descriptor.toolName) lookup could not complete: \(message)"
        }
    }
}
