import Foundation

/// Lifecycle of a two-way instruction, from creation to delivery. The default
/// send policy requires explicit per-message confirmation. A user can opt into
/// direct send after a session is enabled, which immediately advances a prepared
/// instruction to `confirmed` through the same engine path.
public enum InstructionState: String, Codable, Equatable, Sendable {
    case pending      // created, awaiting explicit confirmation
    case confirmed    // user confirmed; eligible to deliver once the session is idle
    case delivering   // an adapter is delivering it right now
    case delivered    // the agent received it
    case failed       // delivery failed or the instruction expired
    case canceled     // the user or the system canceled it before delivery
}

/// How an instruction entered the two-way pipeline. This stays in the audit log
/// so a direct user turn is distinguishable from a personality-generated handoff.
public enum InstructionOrigin: String, Codable, Equatable, Sendable {
    case tellAgent = "tell_agent"
    case personalityTool = "personality_tool"
    case offCallComposer = "off_call_composer"
    case legacy
}

/// One instruction the user has directed at an agent session, plus its delivery
/// state and audit fields. The engine and the store both work in these terms; the
/// adapters (INF-172) turn a `confirmed`/`delivering` instruction into a real
/// resume call.
public struct Instruction: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var sessionID: String        // external agent session id (shared CLI/Desktop)
    public var sourceKind: String       // "codex" | "claude_code" | ...
    public var text: String
    public var state: InstructionState
    public var createdAt: Date
    public var confirmedAt: Date?
    public var deliveredAt: Date?
    /// When this instruction most recently entered `.delivering`. Distinct from
    /// `confirmedAt`, which marks confirmation, not the start of the delivery
    /// attempt: a confirmed instruction can sit waiting for the session to go
    /// idle for a while before it ever reaches `.delivering`, so `confirmedAt`
    /// would overcount how long a stuck delivery has actually been in flight.
    /// Used by the runtime strand-recovery check (INF-249/B6) to find a
    /// `.delivering` instruction that has been stuck longer than
    /// `InstructionReplyEngine.deliveringStrandTimeout`.
    public var deliveringAt: Date?
    public var deliveryMechanism: String?   // e.g. "headless-resume"
    public var error: String?
    public var resultingCardID: String?     // the narration card the agent's reply produced
    public var origin: InstructionOrigin
    public var sourceUtterance: String?      // original user wording before personality rewriting
    public var targetDisplayName: String?    // frozen label shown at confirmation time
    public var deliveryCheckpoint: Int64?    // transcript byte offset before headless resume
    public var deliveryReplyText: String?    // assistant reply text parsed from the resume output (INF-238)
    public var deliveryReplyTurnID: String?  // turn/session identifier parsed from the resume output, if present

    public init(
        id: String,
        sessionID: String,
        sourceKind: String,
        text: String,
        state: InstructionState = .pending,
        createdAt: Date,
        confirmedAt: Date? = nil,
        deliveredAt: Date? = nil,
        deliveringAt: Date? = nil,
        deliveryMechanism: String? = nil,
        error: String? = nil,
        resultingCardID: String? = nil,
        origin: InstructionOrigin = .legacy,
        sourceUtterance: String? = nil,
        targetDisplayName: String? = nil,
        deliveryCheckpoint: Int64? = nil,
        deliveryReplyText: String? = nil,
        deliveryReplyTurnID: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sourceKind = sourceKind
        self.text = text
        self.state = state
        self.createdAt = createdAt
        self.confirmedAt = confirmedAt
        self.deliveredAt = deliveredAt
        self.deliveringAt = deliveringAt
        self.deliveryMechanism = deliveryMechanism
        self.error = error
        self.resultingCardID = resultingCardID
        self.origin = origin
        self.sourceUtterance = sourceUtterance
        self.targetDisplayName = targetDisplayName
        self.deliveryCheckpoint = deliveryCheckpoint
        self.deliveryReplyText = deliveryReplyText
        self.deliveryReplyTurnID = deliveryReplyTurnID
    }

    public var isTerminal: Bool {
        state == .delivered || state == .failed || state == .canceled
    }
}
