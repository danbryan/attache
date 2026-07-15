import AttacheCore
import Foundation

struct AttachePersonaSnapshot {
    var fileURL: URL
    var prompt: String
    var errorDescription: String?

    var statusText: String {
        if let errorDescription {
            return "Personality prompt unavailable: \(errorDescription)"
        }
        return "Personality prompt: editable file"
    }
}

final class AttachePersonaStore {
    let fileURL: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let override = environment["ATTACHE_PERSONALITY_FILE"] ?? environment["COMPANION_PERSONALITY_FILE"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fileURL = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            fileURL = AttacheAppSupport.supportDirectory()
                .appendingPathComponent("AttachePersonality.md")
        }
        migrateLegacyFileIfNeeded()
    }

    private func migrateLegacyFileIfNeeded() {
        let legacy = fileURL.deletingLastPathComponent()
            .appendingPathComponent("CompanionPersonality.md")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: fileURL.path), fm.fileExists(atPath: legacy.path) else { return }
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: legacy, to: fileURL)
    }

    func loadSnapshot() -> AttachePersonaSnapshot {
        do {
            try ensurePersonaFile()
            let prompt = try String(contentsOf: fileURL, encoding: .utf8)
            return AttachePersonaSnapshot(
                fileURL: fileURL,
                prompt: clean(prompt, fallback: AttachePersonality.defaultProfilePrompt),
                errorDescription: nil
            )
        } catch {
            return AttachePersonaSnapshot(
                fileURL: fileURL,
                prompt: AttachePersonality.defaultProfilePrompt,
                errorDescription: error.localizedDescription
            )
        }
    }

    @discardableResult
    func ensurePersonaFile() throws -> URL {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try AttachePersonality.defaultProfilePrompt.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return fileURL
    }

    private func clean(_ prompt: String, fallback: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
