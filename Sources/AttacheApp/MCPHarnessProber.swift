import AttacheCore
import Foundation

/// Reads the real on-disk MCP configs of the harnesses installed on this Mac and
/// hands their content to the pure parsers in `MCPHarnessImport`. This is the
/// only part of detection that touches the filesystem; it never writes anything.
///
/// Claude Code's project-scoped `.mcp.json` files are discovered by asking the
/// caller for the distinct working directories of indexed Claude Code sessions
/// (`projectPaths`), then checking each for a `.mcp.json`.
struct MCPHarnessProber {
    var environment: [String: String]
    var fileManager: FileManager
    /// Distinct Claude Code session working directories, used to find
    /// project-scoped `.mcp.json` files.
    var claudeProjectPaths: () -> [String]

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        claudeProjectPaths: @escaping () -> [String] = { [] }
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.claudeProjectPaths = claudeProjectPaths
    }

    /// Every server detected across all installed harnesses.
    func detectAll() -> [MCPDetectedServer] {
        detectClaude() + detectCodex() + detectOpencode() + detectGrok()
    }

    // MARK: Claude Code

    private func detectClaude() -> [MCPDetectedServer] {
        var results: [MCPDetectedServer] = []

        let globalURL = ClaudePaths.globalConfigJSONURL(
            environment: environment, fileManager: fileManager
        )
        if let data = try? Data(contentsOf: globalURL) {
            results += MCPHarnessImport.parseClaudeConfig(data, originPath: globalURL.path)
        }

        // Project-scoped .mcp.json at each distinct session working directory.
        var seenPaths = Set<String>()
        for project in claudeProjectPaths() {
            let projectURL = URL(fileURLWithPath: project, isDirectory: true)
                .appendingPathComponent(".mcp.json")
            guard seenPaths.insert(projectURL.path).inserted,
                  let data = try? Data(contentsOf: projectURL) else { continue }
            results += MCPHarnessImport.parseClaudeConfig(data, originPath: projectURL.path)
        }
        return results
    }

    // MARK: Codex

    private func detectCodex() -> [MCPDetectedServer] {
        let url = CodexPaths.configTOMLURL(environment: environment, fileManager: fileManager)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return MCPHarnessImport.parseCodexConfig(text, originPath: url.path)
    }

    // MARK: opencode

    private func detectOpencode() -> [MCPDetectedServer] {
        for url in OpencodePaths.configFileURLs(environment: environment, fileManager: fileManager) {
            guard let data = try? Data(contentsOf: url) else { continue }
            let detected = MCPHarnessImport.parseOpencodeConfig(data, originPath: url.path)
            if !detected.isEmpty { return detected }
        }
        return []
    }

    // MARK: Grok Build

    private func detectGrok() -> [MCPDetectedServer] {
        for url in GrokPaths.configTOMLURLs(environment: environment, fileManager: fileManager) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let detected = MCPHarnessImport.parseCodexConfig(
                text, originPath: url.path, harness: .grokBuild
            )
            if !detected.isEmpty { return detected }
        }
        return []
    }
}
