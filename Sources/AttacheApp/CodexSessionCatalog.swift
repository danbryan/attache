import Foundation
import AttacheCore

enum CodexAttachmentCategory: String, Codable, Equatable {
    case activeSession
    case archivedSession
    case automation

    var title: String {
        switch self {
        case .activeSession: return "Active"
        case .archivedSession: return "Archived"
        case .automation: return "Automation"
        }
    }
}

struct CodexSessionTarget: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var updatedAt: Date
    var category: CodexAttachmentCategory
    var status: String?
    var sourceKind: SourceKind = .codex
    var filePath: String? = nil

    var shortID: String {
        String(id.prefix(8))
    }

    var displayTitle: String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Untitled session" : clean
    }

    var detailLabel: String {
        if let status, !status.isEmpty {
            return "\(category.title) / \(status)"
        }
        return category.title
    }

    /// Friendly recency label ("5m ago", "just now") shown instead of the raw
    /// session ID, so the interface reads for non-developers too.
    var activityLabel: String {
        let delta = Date().timeIntervalSince(updatedAt)
        if delta < 45 { return "active just now" }
        return "active \(CodexSessionTarget.relativeFormatter.localizedString(for: updatedAt, relativeTo: Date()))"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// A stand-in search record built purely from the stored watch target, for
    /// a watched session whose real record is not in the live index (archived
    /// with Archived off, aged out of the transcript index, or its files
    /// removed). Lets Command-K always surface a watched session so it can be
    /// unwatched even when search would produce no row for it. Carries no
    /// transcript content, so it never matches a content query and focusing it
    /// stays unsupported; only its id, title, recency, source, and archived
    /// flag are meaningful.
    func syntheticSessionRecord() -> SessionRecord {
        SessionRecord(
            id: id,
            title: title,
            project: nil,
            threadName: nil,
            updatedAt: updatedAt,
            archived: category == .archivedSession,
            filePath: filePath ?? "",
            fileMtime: 0,
            content: "",
            topicTag: nil,
            sourceKind: sourceKind,
            localModelHint: nil
        )
    }
}

struct CodexSessionCatalogSnapshot {
    var activeSessions: [CodexSessionTarget]
    var archivedSessions: [CodexSessionTarget]
    var automations: [CodexSessionTarget]

    var allTargets: [CodexSessionTarget] {
        activeSessions + automations + archivedSessions
    }
}

final class CodexSessionCatalog {
    private struct SessionIndexEntry: Decodable {
        var id: String
        var threadName: String
        var updatedAt: String

        enum CodingKeys: String, CodingKey {
            case id
            case threadName = "thread_name"
            case updatedAt = "updated_at"
        }
    }

    private let fileURL: URL
    private let sessionsDirectory: URL
    private let archivedSessionsDirectory: URL
    private let automationsDirectory: URL
    private let fractionalParser = ISO8601DateFormatter()
    private let wholeSecondParser = ISO8601DateFormatter()
    private let sessionIDPattern = try? NSRegularExpression(
        pattern: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#,
        options: [.caseInsensitive]
    )

    init(
        fileURL: URL? = nil,
        codexHome: URL? = nil,
        sessionsDirectory: URL? = nil,
        archivedSessionsDirectory: URL? = nil,
        automationsDirectory: URL? = nil
    ) {
        let resolvedCodexHome = codexHome ?? CodexPaths.home()
        self.fileURL = fileURL ?? resolvedCodexHome
            .appendingPathComponent("session_index.jsonl")
        self.sessionsDirectory = sessionsDirectory ?? resolvedCodexHome
            .appendingPathComponent("sessions", isDirectory: true)
        self.archivedSessionsDirectory = archivedSessionsDirectory ?? resolvedCodexHome
            .appendingPathComponent("archived_sessions", isDirectory: true)
        self.automationsDirectory = automationsDirectory ?? resolvedCodexHome
            .appendingPathComponent("automations", isDirectory: true)
        fractionalParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        wholeSecondParser.formatOptions = [.withInternetDateTime]
    }

    func loadSnapshot(activeLimit: Int = 30, archivedLimit: Int = 20, automationLimit: Int = 20) -> CodexSessionCatalogSnapshot {
        let indexedSessions = loadIndexedSessions()
        let activeFiles = sessionFiles(in: sessionsDirectory)
        let archivedFiles = sessionFiles(in: archivedSessionsDirectory)
        let missingFilesystemIndex = activeFiles.isEmpty && archivedFiles.isEmpty
        let automations = loadAutomations(limit: automationLimit)

        let activeSessions = indexedSessions.compactMap { entry -> CodexSessionTarget? in
            guard missingFilesystemIndex || activeFiles[entry.id] != nil else { return nil }
            return CodexSessionTarget(
                id: entry.id,
                title: entry.threadName,
                updatedAt: entry.date,
                category: .activeSession,
                status: nil,
                filePath: activeFiles[entry.id]?.path
            )
        }
        .prefix(activeLimit)
        .map { $0 }

        let archivedSessions = indexedSessions.compactMap { entry -> CodexSessionTarget? in
            guard !missingFilesystemIndex, archivedFiles[entry.id] != nil else { return nil }
            return CodexSessionTarget(
                id: entry.id,
                title: entry.threadName,
                updatedAt: entry.date,
                category: .archivedSession,
                status: nil,
                filePath: archivedFiles[entry.id]?.path
            )
        }
        .prefix(archivedLimit)
        .map { $0 }

        return CodexSessionCatalogSnapshot(
            activeSessions: activeSessions,
            archivedSessions: archivedSessions,
            automations: automations
        )
    }

    private func loadIndexedSessions() -> [(id: String, threadName: String, date: Date)] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let lineData = String(line).data(using: .utf8),
                  let entry = try? decoder.decode(SessionIndexEntry.self, from: lineData),
                  let date = parseDate(entry.updatedAt) else {
                return nil
            }
            return (entry.id, entry.threadName, date)
        }
        .sorted { $0.date > $1.date }
    }

    private func parseDate(_ value: String) -> Date? {
        fractionalParser.date(from: value) ?? wholeSecondParser.date(from: value)
    }

    private func sessionFiles(in directory: URL) -> [String: URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var files: [String: URL] = [:]
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            if let id = sessionID(in: fileURL.lastPathComponent) {
                files[id] = fileURL
            }
        }
        return files
    }

    private func sessionID(in fileName: String) -> String? {
        guard let sessionIDPattern else { return nil }
        let range = NSRange(fileName.startIndex..<fileName.endIndex, in: fileName)
        guard let match = sessionIDPattern.firstMatch(in: fileName, range: range),
              let matchRange = Range(match.range, in: fileName) else {
            return nil
        }
        return String(fileName[matchRange])
    }

    private func loadAutomations(limit: Int) -> [CodexSessionTarget] {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: automationsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return directories.compactMap { directory -> CodexSessionTarget? in
            let fileURL = directory.appendingPathComponent("automation.toml")
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
            let fields = parseAutomationFields(text)
            guard let id = fields["id"], let name = fields["name"] else { return nil }
            let updatedAt = fields["updated_at"].flatMap { Double($0) }
                .map { Date(timeIntervalSince1970: $0 / 1000.0) }
                ?? Date(timeIntervalSince1970: 0)
            return CodexSessionTarget(
                id: id,
                title: name,
                updatedAt: updatedAt,
                category: .automation,
                status: fields["status"]
            )
        }
        .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        .prefix(limit)
        .map { $0 }
    }

    private func parseAutomationFields(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"),
                  let separator = line.firstIndex(of: "=") else {
                continue
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            fields[String(key)] = String(value)
        }
        return fields
    }
}
