import Foundation

/// What an adapter can do for a session right now, so the engine knows whether to
/// deliver immediately or hold until the session goes idle (per docs/two-way.md,
/// the only safe live path is a single writer; queue-until-idle guarantees it).
public struct DeliveryCapability: Equatable, Sendable {
    /// The adapter recognizes and can reach this session at all.
    public var canDeliver: Bool
    /// Delivery must wait until the session is quiet (a second writer mid-turn is
    /// unsafe). True for the v1 headless-resume mechanism.
    public var requiresIdle: Bool
    /// When `canDeliver` is false, a human-readable reason (missing CLI, unknown
    /// session) for the UX to surface instead of failing at send time.
    public var reason: String?

    public init(canDeliver: Bool, requiresIdle: Bool, reason: String? = nil) {
        self.canDeliver = canDeliver
        self.requiresIdle = requiresIdle
        self.reason = reason
    }

    public static func unavailable(_ reason: String) -> DeliveryCapability {
        DeliveryCapability(canDeliver: false, requiresIdle: false, reason: reason)
    }
}

public enum InstructionDeliveryError: Error, Equatable, Sendable {
    case notDeliverable(String)   // no adapter / session can't be reached
    case sessionGone              // the target session was deleted or archived
    case deliveryFailed(String)   // the resume call itself failed
}

/// Result of a successful delivery: which mechanism actually delivered it, for
/// the audit log.
public struct DeliveryReceipt: Equatable, Sendable {
    public var mechanism: String   // e.g. "headless-resume"
    public init(mechanism: String) {
        self.mechanism = mechanism
    }
}

/// The seam the vendor adapters (INF-172) implement. The engine (INF-171) is
/// agent-agnostic and talks only to this protocol.
public protocol InstructionDeliveryAdapter: Sendable {
    /// Which source kind this adapter handles ("codex", "claude_code").
    var sourceKind: String { get }
    /// Can this adapter deliver to the session, and must it wait for idle?
    func capability(forSessionID sessionID: String) -> DeliveryCapability
    /// Deliver the instruction (e.g. a headless resume). Called at most once per
    /// instruction, with single-flight guaranteed by the engine.
    func deliver(_ instruction: Instruction) async -> Result<DeliveryReceipt, InstructionDeliveryError>
}
