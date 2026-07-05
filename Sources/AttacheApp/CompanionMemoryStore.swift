import AttacheCore
import Foundation

struct CompanionMemorySnapshot {
    var fileURL: URL
    var rawText: String
    var context: String?
    var errorDescription: String?

    var statusText: String {
        if let errorDescription {
            return "Memory unavailable: \(errorDescription)"
        }
        let count = CompanionPersonality.parsedMemoryEntries(from: rawText).count
        return "Memory: \(count) saved preference\(count == 1 ? "" : "s")"
    }
}

final class CompanionMemoryStore {
    let fileURL: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let override = environment["ATTACHE_MEMORY_FILE"] ?? environment["COMPANION_MEMORY_FILE"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fileURL = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            fileURL = CompanionAppSupport.supportDirectory()
                .appendingPathComponent("AttacheMemory.md")
        }
        migrateLegacyFileIfNeeded()
    }

    /// Renames a memory file written by earlier builds (CompanionMemory.md) to the
    /// current name at launch, so upgrading users keep their saved preferences.
    private func migrateLegacyFileIfNeeded() {
        let fm = FileManager.default
        // Rename a file written by earlier builds (CompanionMemory.md) to the new name.
        let legacy = fileURL.deletingLastPathComponent().appendingPathComponent("CompanionMemory.md")
        if !fm.fileExists(atPath: fileURL.path), fm.fileExists(atPath: legacy.path) {
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: legacy, to: fileURL)
        }
        // Refresh the header comment earlier builds wrote (it used the old wording),
        // in place, without disturbing the user's saved entries.
        if let content = try? String(contentsOf: fileURL, encoding: .utf8),
           content.contains("companion presentation LLM") {
            let fixed = content.replacingOccurrences(
                of: "injected into the companion presentation LLM",
                with: "injected into Attaché's presentation model")
            try? fixed.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    func loadSnapshot() -> CompanionMemorySnapshot {
        do {
            try ensureMemoryFile()
            let rawText = try String(contentsOf: fileURL, encoding: .utf8)
            return CompanionMemorySnapshot(
                fileURL: fileURL,
                rawText: rawText,
                context: CompanionPersonality.memoryContext(from: rawText),
                errorDescription: nil
            )
        } catch {
            return CompanionMemorySnapshot(
                fileURL: fileURL,
                rawText: "",
                context: nil,
                errorDescription: error.localizedDescription
            )
        }
    }

    @discardableResult
    func ensureMemoryFile() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fm.fileExists(atPath: fileURL.path) {
            try CompanionPersonality.defaultMemoryFileText.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return fileURL
    }
}
