import Foundation

/// User-facing confirmation policy for sending instructions back into watched
/// agent sessions.
public enum AgentInstructionSendPolicy: String, CaseIterable, Codable, Equatable, Sendable {
    case confirmEveryInstruction
    case directAfterSessionEnable

    public static let defaultValue: AgentInstructionSendPolicy = .confirmEveryInstruction

    public var sendsDirectlyAfterSessionEnable: Bool {
        self == .directAfterSessionEnable
    }
}
