import AttacheCore
import Foundation

struct CompanionPersonaSnapshot {
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

final class CompanionPersonaStore {
    let fileURL: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let override = environment["ATTACHE_PERSONALITY_FILE"] ?? environment["COMPANION_PERSONALITY_FILE"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fileURL = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            fileURL = CompanionAppSupport.supportDirectory()
                .appendingPathComponent("CompanionPersonality.md")
        }
    }

    func loadSnapshot() -> CompanionPersonaSnapshot {
        do {
            try ensurePersonaFile()
            let prompt = try String(contentsOf: fileURL, encoding: .utf8)
            return CompanionPersonaSnapshot(
                fileURL: fileURL,
                prompt: clean(prompt, fallback: CompanionPersonality.defaultProfilePrompt),
                errorDescription: nil
            )
        } catch {
            return CompanionPersonaSnapshot(
                fileURL: fileURL,
                prompt: CompanionPersonality.defaultProfilePrompt,
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
            try CompanionPersonality.defaultProfilePrompt.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return fileURL
    }

    private func clean(_ prompt: String, fallback: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
