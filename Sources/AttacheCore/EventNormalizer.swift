import Foundation

public enum EventNormalizerError: Error, LocalizedError, Equatable {
    case emptyText
    case unsupportedPayload
    /// The event named a `schema_version` higher than this server understands
    /// (INF-359). `requested` is what the sender sent; `supported` is the
    /// highest version this build of Attaché accepts.
    case unsupportedSchemaVersion(requested: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Event text was empty."
        case .unsupportedPayload:
            return "Event payload could not be normalized."
        case .unsupportedSchemaVersion(let requested, let supported):
            return "Unsupported schema_version \(requested); this server supports schema_version \(supported)."
        }
    }
}

public enum EventNormalizer {
    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    /// Highest `schema_version` this build of Attaché accepts on `POST /events`
    /// (INF-359, docs/integrations.md). Absent on the wire is treated as this
    /// version; anything higher is rejected before normalization runs.
    public static let supportedSchemaVersion = 1

    public static func decode(data: Data) throws -> NormalizedEvent {
        let event = try decoder.decode(NormalizedEvent.self, from: data)
        if let requested = event.schemaVersion, requested > supportedSchemaVersion {
            throw EventNormalizerError.unsupportedSchemaVersion(requested: requested, supported: supportedSchemaVersion)
        }
        return try normalize(event)
    }

    public static func normalize(_ event: NormalizedEvent) throws -> NormalizedEvent {
        let trimmedText = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { throw EventNormalizerError.emptyText }

        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return NormalizedEvent(
            source: event.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "generic" : event.source,
            eventType: event.eventType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "assistant.completed" : event.eventType,
            externalSessionID: cleanOptional(event.externalSessionID),
            projectPath: cleanOptional(event.projectPath),
            title: title.isEmpty ? "Agent update" : title,
            text: trimmedText,
            metadata: event.metadata,
            schemaVersion: event.schemaVersion ?? supportedSchemaVersion
        )
    }

    public static func metadataJSON(for event: NormalizedEvent) -> String {
        var metadata = event.metadata
        metadata["event_type"] = event.eventType
        metadata["source"] = event.source
        if let externalSessionID = event.externalSessionID {
            metadata["external_session_id"] = externalSessionID
        }
        if let projectPath = event.projectPath {
            metadata["project_path"] = projectPath
        }
        // Previously the whole event JSON (including its `text`, already stored as
        // the card's raw_text) was embedded here, doubling storage of every
        // transcript chunk. Nothing reads it, so it's dropped (INF-170).
        let data = (try? encoder.encode(metadata)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func summary(for event: NormalizedEvent, limit: Int = 180) -> String {
        let compact = event.text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard compact.count > limit else { return compact }
        let end = compact.index(compact.startIndex, offsetBy: limit)
        let prefix = compact[..<end]
        if let sentenceEnd = prefix.lastIndex(where: { ".!?".contains($0) }) {
            return String(prefix[...sentenceEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(prefix).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    public static func storedSummary(for event: NormalizedEvent) -> String {
        metadataText(event.metadata["companion_summary"])
            ?? metadataText(event.metadata["card_summary"])
            ?? summary(for: event)
    }

    public static func storedSpokenText(for event: NormalizedEvent, summary: String? = nil) -> String {
        if let override = metadataText(event.metadata["companion_spoken_text"])
            ?? metadataText(event.metadata["spoken_text"]) {
            return override
        }
        return spokenText(for: event, summary: summary)
    }

    public static func spokenText(for event: NormalizedEvent, summary: String? = nil) -> String {
        let projectName = event.projectPath.flatMap { URL(fileURLWithPath: $0).lastPathComponent }
        let heading = [event.title, projectName].compactMap { value -> String? in
            guard let value else { return nil }
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        }.joined(separator: " in ")
        let body = summary ?? self.summary(for: event, limit: 260)
        return heading.isEmpty ? body : "\(heading). \(body)"
    }

    public static func simulatedEvent(projectPath: String) -> NormalizedEvent {
        NormalizedEvent(
            source: "codex",
            eventType: "assistant.completed",
            externalSessionID: "simulated-codex-session",
            projectPath: projectPath,
            title: "MVP smoke update",
            text: "The Attaché prototype received a simulated Codex completion. This card should stay unread until playback finishes, survive restart, and replay with captions.",
            metadata: [
                "adapter": "simulated",
                "cwd": projectPath
            ]
        )
    }

    private static func metadataText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cleanOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
