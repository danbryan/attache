import Foundation

/// The user's answer to an ask-first MCP tool confirmation.
public enum MCPApprovalDecision: Equatable, Sendable {
    /// Do not run the tool this time.
    case deny
    /// Run the tool once; do not change the stored grant.
    case allowOnce
    /// Run the tool and remember the grant. Persistence is still clamped to
    /// read-only tools by `MCPToolPolicy.grantToPersist`.
    case alwaysAllow
}

/// Pure permission policy for MCP tools. This is the single place that clamps
/// grants: effectful tools can never be always-allowed, and a Private Call
/// drops effectful tools entirely while read-only tools keep their grant.
public enum MCPToolPolicy {
    /// Resolve a stored grant into the permission that actually applies for
    /// this call, given whether the tool is read-only and whether the call is
    /// private.
    ///
    /// - Effectful (not read-only) tools clamp `alwaysAllow` down to
    ///   `askFirst`; there is no always-allow for anything that can act.
    /// - In a Private Call, effectful tools resolve to `notOffered` (absent
    ///   entirely) while read-only tools keep whatever grant they had.
    public static func effective(
        permission: MCPToolPermission,
        isReadOnly: Bool,
        isPrivateCall: Bool
    ) -> MCPToolPermission {
        if isPrivateCall && !isReadOnly {
            return .notOffered
        }
        if !isReadOnly && permission == .alwaysAllow {
            return .askFirst
        }
        return permission
    }

    /// The subset of `available` tools whose effective permission is
    /// `askFirst` or `alwaysAllow`, i.e. the tools whose schema should be sent
    /// to the model this turn.
    public static func offeredTools(
        available: [MCPToolDescriptor],
        grants: MCPToolGrants,
        isPrivateCall: Bool
    ) -> [MCPToolDescriptor] {
        available.filter { descriptor in
            let grant = grants[descriptor.namespacedName] ?? .defaultPermission
            let effective = effective(
                permission: grant,
                isReadOnly: descriptor.isReadOnly,
                isPrivateCall: isPrivateCall
            )
            return effective != .notOffered
        }
    }

    /// The grant to persist after the user chose "Always allow" in a
    /// confirmation. Read-only tools persist `alwaysAllow`; effectful tools
    /// persist nothing (the clamp), so a later turn still asks first.
    public static func grantToPersist(
        afterAlwaysAllowFor descriptor: MCPToolDescriptor
    ) -> MCPToolPermission? {
        descriptor.isReadOnly ? .alwaysAllow : nil
    }

    /// The next permission when the user cycles a tool's chip in the picker.
    /// Read-only tools cycle through all three states
    /// (`notOffered` -> `askFirst` -> `alwaysAllow` -> `notOffered`); effectful
    /// tools skip `alwaysAllow` entirely (`notOffered` -> `askFirst` ->
    /// `notOffered`), because they can never be always-allowed.
    public static func cyclePermission(
        _ permission: MCPToolPermission,
        isReadOnly: Bool
    ) -> MCPToolPermission {
        if isReadOnly {
            switch permission {
            case .notOffered: return .askFirst
            case .askFirst: return .alwaysAllow
            case .alwaysAllow: return .notOffered
            }
        }
        switch permission {
        case .notOffered: return .askFirst
        case .askFirst, .alwaysAllow: return .notOffered
        }
    }
}
