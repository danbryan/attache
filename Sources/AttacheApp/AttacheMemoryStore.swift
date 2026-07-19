import AttacheCore
import Foundation

struct AttacheMemorySnapshot {
    var fileURL: URL
    var rawText: String
    var context: String?
    var errorDescription: String?

    var statusText: String {
        if let errorDescription {
            return "Memory unavailable: \(errorDescription)"
        }
        let count = AttachePersonality.parsedMemoryEntries(from: rawText).count
        return "Memory: \(count) saved preference\(count == 1 ? "" : "s")"
    }
}

final class AttacheMemoryStore {
    let fileURL: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let override = environment["ATTACHE_MEMORY_FILE"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fileURL = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            fileURL = AttacheAppSupport.supportDirectory()
                .appendingPathComponent("AttacheMemory.md")
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? hardenMemoryFilePermissions()
        }
    }

    func loadSnapshot() -> AttacheMemorySnapshot {
        do {
            try ensureMemoryFile()
            let rawText = try String(contentsOf: fileURL, encoding: .utf8)
            return AttacheMemorySnapshot(
                fileURL: fileURL,
                rawText: rawText,
                context: AttachePersonality.memoryContext(from: rawText),
                errorDescription: nil
            )
        } catch {
            return AttacheMemorySnapshot(
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
            guard fm.createFile(
                atPath: fileURL.path,
                contents: Data(AttachePersonality.defaultMemoryFileText.utf8),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
            }
        }
        try hardenMemoryFilePermissions()
        return fileURL
    }

    private func hardenMemoryFilePermissions() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        let initialAttributes = try fm.attributesOfItem(atPath: fileURL.path)
        guard initialAttributes[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSFilePathErrorKey: fileURL.path])
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        let attributes = try fm.attributesOfItem(atPath: fileURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        guard permissions & 0o777 == 0o600 else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: fileURL.path])
        }
    }
}
