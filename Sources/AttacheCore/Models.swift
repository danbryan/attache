import Foundation

public enum CardStatus: String, Codable, Equatable, CaseIterable {
    case unread
    case heard
    case archived
    case failed
}

public enum CardKind: String, Codable, Equatable, CaseIterable {
    case update
    case error
    case approval
    case reminder
}

public enum SourceKind: String, Codable, Equatable, CaseIterable {
    case codex
    case claudeCode = "claude_code"
    case mcp
    case generic
    case simulated

    /// Full name for menus and settings.
    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .mcp: return "MCP"
        case .generic: return "Custom"
        case .simulated: return "Demo"
        }
    }

    /// Compact label for the per-session source badge.
    public var shortLabel: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude"
        case .mcp: return "MCP"
        case .generic: return "Custom"
        case .simulated: return "Demo"
        }
    }

    /// Raw values for sources that represent a live coding agent whose session
    /// Attaché attaches to, narrates, and answers questions about. Behavior gated on
    /// "is this a real agent session" should check membership here, not `== .codex`.
    public static let liveAgentRawValues: Set<String> = [
        SourceKind.codex.rawValue, SourceKind.claudeCode.rawValue
    ]
}

public struct NormalizedEvent: Codable, Equatable {
    public var source: String
    public var eventType: String
    public var externalSessionID: String?
    public var projectPath: String?
    public var title: String
    public var text: String
    public var metadata: [String: String]

    public init(
        source: String,
        eventType: String,
        externalSessionID: String? = nil,
        projectPath: String? = nil,
        title: String,
        text: String,
        metadata: [String: String] = [:]
    ) {
        self.source = source
        self.eventType = eventType
        self.externalSessionID = externalSessionID
        self.projectPath = projectPath
        self.title = title
        self.text = text
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case source
        case eventType = "event_type"
        case externalSessionID = "external_session_id"
        case projectPath = "project_path"
        case title
        case text
        case metadata
    }
}

public struct VoicemailCard: Identifiable, Codable, Equatable {
    public var id: String
    public var sourceID: String
    public var sourceKind: String
    public var sourceDisplayName: String
    public var sessionID: String?
    public var externalSessionID: String?
    public var projectPath: String?
    public var sessionTitle: String?
    public var kind: CardKind
    public var rawText: String
    public var summary: String
    public var spokenText: String
    public var status: CardStatus
    public var createdAt: Date
    public var heardAt: Date?
    public var metadataJSON: String
    public var durationMs: Int
    public var alignment: CaptionAlignment?

    public init(
        id: String,
        sourceID: String,
        sourceKind: String,
        sourceDisplayName: String,
        sessionID: String?,
        externalSessionID: String?,
        projectPath: String?,
        sessionTitle: String?,
        kind: CardKind,
        rawText: String,
        summary: String,
        spokenText: String,
        status: CardStatus,
        createdAt: Date,
        heardAt: Date?,
        metadataJSON: String,
        durationMs: Int,
        alignment: CaptionAlignment?
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceKind = sourceKind
        self.sourceDisplayName = sourceDisplayName
        self.sessionID = sessionID
        self.externalSessionID = externalSessionID
        self.projectPath = projectPath
        self.sessionTitle = sessionTitle
        self.kind = kind
        self.rawText = rawText
        self.summary = summary
        self.spokenText = spokenText
        self.status = status
        self.createdAt = createdAt
        self.heardAt = heardAt
        self.metadataJSON = metadataJSON
        self.durationMs = durationMs
        self.alignment = alignment
    }
}

public struct StoredSource: Identifiable, Codable, Equatable {
    public var id: String
    public var kind: String
    public var displayName: String
    public var enabled: Bool
    public var configJSON: String
}

public struct StoredSession: Identifiable, Codable, Equatable {
    public var id: String
    public var sourceID: String
    public var externalSessionID: String?
    public var projectPath: String?
    public var title: String
    public var lastSeenAt: Date
}

public extension VoicemailCard {
    /// The presentation step can flag an update as blocked on the user
    /// (INF-169). Absent or malformed metadata reads as false.
    var needsDecision: Bool {
        guard let data = metadataJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return (object["companion_needs_decision"] as? String) == "1"
    }
}
