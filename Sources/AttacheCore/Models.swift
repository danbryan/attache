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
    case grokBuild = "grok_build"
    case opencode
    case mcp
    case generic
    case simulated

    /// Full name for menus and settings.
    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .grokBuild: return "Grok Build"
        case .opencode: return "opencode"
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
        case .grokBuild: return "Grok"
        case .opencode: return "opencode"
        case .mcp: return "MCP"
        case .generic: return "Custom"
        case .simulated: return "Demo"
        }
    }

    /// Raw values for sources that represent a live coding agent whose session
    /// Attaché attaches to, narrates, and answers questions about. Behavior gated on
    /// "is this a real agent session" should check membership here, not `== .codex`.
    /// Grok Build (INF-361) and opencode (INF-362) are included: their sessions are
    /// watched, narrated, and attached the same way Codex/Claude Code are, and both
    /// now support two-way delivery too (Grok Build INF-394; opencode INF-395, over
    /// the SQLite two-way seam).
    public static let liveAgentRawValues: Set<String> = [
        SourceKind.codex.rawValue, SourceKind.claudeCode.rawValue, SourceKind.grokBuild.rawValue,
        SourceKind.opencode.rawValue
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
    /// Event schema version (INF-359). Absent on the wire means 1.
    /// `EventNormalizer.normalize` fills this to `EventNormalizer.supportedSchemaVersion`
    /// when the sender omits it, so a normalized event always carries an explicit value.
    public var schemaVersion: Int?

    public init(
        source: String,
        eventType: String,
        externalSessionID: String? = nil,
        projectPath: String? = nil,
        title: String,
        text: String,
        metadata: [String: String] = [:],
        schemaVersion: Int? = nil
    ) {
        self.source = source
        self.eventType = eventType
        self.externalSessionID = externalSessionID
        self.projectPath = projectPath
        self.title = title
        self.text = text
        self.metadata = metadata
        self.schemaVersion = schemaVersion
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case source
        case eventType = "event_type"
        case externalSessionID = "external_session_id"
        case projectPath = "project_path"
        case title
        case text
        case metadata
        case schemaVersion = "schema_version"
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
    /// Parsed metadata blob, or empty when absent or malformed.
    var metadataObject: [String: Any] {
        guard let data = metadataJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    /// The presentation step can flag an update as blocked on the user
    /// (INF-169). Absent or malformed metadata reads as false.
    var needsDecision: Bool {
        (metadataObject["companion_needs_decision"] as? String) == "1"
    }

    /// When this card is an "another take" of an earlier card (INF-299), the
    /// original card's id. Nil for ordinary cards.
    var takeOf: String? { metadataObject["companion_take_of"] as? String }

    /// True when this card is a re-narration of another card.
    var isAnotherTake: Bool { takeOf != nil }

    /// The personality that produced this card, when recorded. Used as the
    /// "prior take" attribution when making another take of it.
    var producedByPersonalityName: String? { metadataObject["companion_personality_name"] as? String }
}
