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
    public var deliveryMechanism: String?   // e.g. "headless-resume"
    public var error: String?
    public var resultingCardID: String?     // the narration card the agent's reply produced

    public init(
        id: String,
        sessionID: String,
        sourceKind: String,
        text: String,
        state: InstructionState = .pending,
        createdAt: Date,
        confirmedAt: Date? = nil,
        deliveredAt: Date? = nil,
        deliveryMechanism: String? = nil,
        error: String? = nil,
        resultingCardID: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sourceKind = sourceKind
        self.text = text
        self.state = state
        self.createdAt = createdAt
        self.confirmedAt = confirmedAt
        self.deliveredAt = deliveredAt
        self.deliveryMechanism = deliveryMechanism
        self.error = error
        self.resultingCardID = resultingCardID
    }

    public var isTerminal: Bool {
        state == .delivered || state == .failed || state == .canceled
    }
}
