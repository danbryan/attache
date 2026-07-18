import AttacheCore
import Combine
import Foundation

/// Connection state for one configured MCP server, surfaced for a Settings
/// pane to bind to.
enum MCPServerStatus: Equatable {
    /// The entry exists but is turned off (`"enabled": false`) or invalid.
    case disabled
    /// Enabled and valid, but not connected yet (lazy connect).
    case idle
    case connecting
    case connected(toolCount: Int)
    case failed(String)
}

/// The app-wide registry of MCP servers. Reads a Claude-compatible `mcp.json`
/// from the Attaché app-support directory, watches it for changes, connects
/// lazily (never at launch for a server nobody has a grant for), caches each
/// server's tool descriptors, and dispatches tool calls to the right client.
///
/// Main-thread-only, like `TwoWayCoordinator`; `@unchecked Sendable` reflects
/// that contract. All mutable state is read and written on the main thread; the
/// only work that leaves it is `await client.connect()` / `client.callTool`,
/// after which results are folded back in on the main actor.
final class MCPServerRegistry: ObservableObject, @unchecked Sendable {
    /// Results longer than this are truncated with a trailing note before they
    /// re-enter the conversation, to protect the context budget.
    static let maxResultCharacters = 16_000

    @Published private(set) var configuredServers: [MCPServerConfig] = []
    @Published private(set) var statuses: [String: MCPServerStatus] = [:]
    @Published private(set) var validationErrors: [String: String] = [:]
    /// Servers found in other installed harnesses that are not already
    /// configured here (filtered by connection identity). Populated by
    /// `refreshDetection()`.
    @Published private(set) var detectedServers: [MCPDetectedServer] = []
    /// True while a detection pass is running, so the pane can show progress.
    @Published private(set) var isDetecting = false

    /// Reads the installed harnesses' configs off the main actor. Injected so
    /// tests can supply candidates without touching the filesystem; the app sets
    /// it to a real `MCPHarnessProber`.
    var detectHarnessServers: () -> [MCPDetectedServer] = { [] }

    private let configURL: URL
    private let watchesFile: Bool

    /// Valid, enabled servers by name, the ones eligible to connect.
    private var servers: [String: MCPServerConfig] = [:]
    /// Sanitized server token -> configured server name, so a namespaced tool
    /// name resolves back to its concrete server.
    private var sanitizedToName: [String: String] = [:]
    private var clients: [String: MCPClient] = [:]
    private var toolCache: [String: [MCPToolDescriptor]] = [:]
    private var connectTasks: [String: Task<[MCPToolDescriptor], Error>] = [:]

    private var watchSource: DispatchSourceFileSystemObject?
    private var watchDescriptor: Int32 = -1
    private var reloadWorkItem: DispatchWorkItem?

    static func defaultConfigURL() -> URL {
        AttacheAppSupport.supportDirectory().appendingPathComponent("mcp.json")
    }

    /// The file the Settings pane reads and writes. Exposed so the pane can
    /// open it in the default editor and round-trip edits through
    /// `MCPConfigEditor`.
    var configFileURL: URL { configURL }

    /// The current on-disk config bytes, or empty when the file is absent.
    func currentConfigData() -> Data {
        (try? Data(contentsOf: configURL)) ?? Data()
    }

    /// Write new config bytes and reload. Creates the support directory if
    /// needed. The file watcher would also pick the change up, but an explicit
    /// reload keeps the published state correct even when watching is off.
    func writeConfigData(_ data: Data) throws {
        let directory = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: configURL, options: .atomic)
        reload()
    }

    /// Create the scaffold file if it is absent, then return its URL so a
    /// caller can open it. Never overwrites an existing file.
    @discardableResult
    func ensureConfigFileExists() -> URL {
        if !FileManager.default.fileExists(atPath: configURL.path) {
            try? writeConfigData(MCPConfigEditor.scaffold())
        }
        return configURL
    }

    /// Begin a lazy connect for every valid, enabled server. Used by the tool
    /// picker so idle servers connect and their tools appear when it opens.
    @MainActor
    func connectConfiguredServers() {
        for serverName in servers.keys {
            Task { await self.ensureConnected(serverName: serverName) }
        }
    }

    init(configURL: URL = MCPServerRegistry.defaultConfigURL(), watchesFile: Bool = true) {
        self.configURL = configURL
        self.watchesFile = watchesFile
        reload()
        if watchesFile { startWatching() }
    }

    deinit {
        watchSource?.cancel()
        if watchDescriptor >= 0 { close(watchDescriptor) }
    }

    // MARK: Configuration

    /// Re-read the config file, tearing down servers that were removed or whose
    /// definition changed. Call on the main thread.
    func reload() {
        let parsed = MCPConfigFile.read(from: configURL)
        var newValid: [String: MCPServerConfig] = [:]
        var newSanitized: [String: String] = [:]
        var newValidationErrors: [String: String] = [:]
        var newStatuses: [String: MCPServerStatus] = [:]

        for server in parsed.servers {
            if let error = server.validationError {
                newValidationErrors[server.name] = error
                newStatuses[server.name] = .disabled
                continue
            }
            if !server.isEnabled {
                newStatuses[server.name] = .disabled
                continue
            }
            newValid[server.name] = server
            newSanitized[MCPToolNamespace.sanitize(serverName: server.name)] = server.name
        }

        // Tear down servers that are gone or whose definition changed.
        for (name, oldServer) in servers where newValid[name] != oldServer {
            teardownServer(name)
        }

        // Preserve live status for unchanged, already-connected servers.
        for (name, server) in newValid {
            if servers[name] == server, let existing = statuses[name],
               case .connected = existing {
                newStatuses[name] = existing
            } else if servers[name] == server, let existing = statuses[name],
                      case .failed = existing {
                newStatuses[name] = existing
            } else {
                newStatuses[name] = .idle
            }
        }

        servers = newValid
        sanitizedToName = newSanitized
        configuredServers = parsed.servers
        validationErrors = newValidationErrors
        statuses = newStatuses
    }

    private func teardownServer(_ name: String) {
        connectTasks[name]?.cancel()
        connectTasks[name] = nil
        toolCache[name] = nil
        let client = clients[name]
        clients[name] = nil
        if let client {
            Task { await client.close() }
        }
    }

    // MARK: Harness detection and import

    /// Run a detection pass off the main actor, then publish the candidates that
    /// are not already configured here (compared by connection identity, so a
    /// server that was imported under a suffixed name still drops out).
    func refreshDetection() {
        guard !isDetecting else { return }
        isDetecting = true
        let detect = detectHarnessServers
        Task { @MainActor [weak self] in
            let candidates = await Task.detached { detect() }.value
            self?.publishDetected(candidates)
        }
    }

    @MainActor
    private func publishDetected(_ candidates: [MCPDetectedServer]) {
        let configured = configuredServers.filter(\.isValid)
        let filtered = candidates.filter { candidate in
            !configured.contains { Self.sameConnection($0, candidate.config) }
        }
        detectedServers = filtered.sorted {
            if $0.harness.displayName != $1.harness.displayName {
                return $0.harness.displayName < $1.harness.displayName
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        isDetecting = false
    }

    private static func sameConnection(_ lhs: MCPServerConfig, _ rhs: MCPServerConfig) -> Bool {
        lhs.transport == rhs.transport
            && lhs.command == rhs.command
            && lhs.args == rhs.args
            && lhs.env == rhs.env
            && lhs.url == rhs.url
            && lhs.headers == rhs.headers
    }

    /// Merge the given detected servers into `mcp.json` and reload. Returns the
    /// map of detected name -> imported name so the caller can report results.
    @discardableResult
    func importDetected(_ detected: [MCPDetectedServer]) throws -> [String: String] {
        let (data, imported) = MCPConfigEditor.importServers(detected, into: currentConfigData())
        try writeConfigData(data)
        refreshDetection()
        return imported
    }

    // MARK: Tool discovery and dispatch

    /// Every cached tool across connected servers, deterministically ordered.
    /// Returns only what is already connected; call `ensureConnected` /
    /// `prepareTools` first to warm servers a personality has grants for.
    func availableTools() -> [MCPToolDescriptor] {
        toolCache.values.flatMap { $0 }.sorted { $0.namespacedName < $1.namespacedName }
    }

    @MainActor
    func descriptor(forNamespacedName namespacedName: String) -> MCPToolDescriptor? {
        for descriptors in toolCache.values {
            if let match = descriptors.first(where: { $0.namespacedName == namespacedName }) {
                return match
            }
        }
        return nil
    }

    /// Ensure the servers backing these namespaced tool names are connected and
    /// their schemas cached. Best-effort: failures leave the server `.failed`
    /// and are simply not offered.
    func prepareTools(forNamespacedNames names: [String]) async {
        let serverNames: Set<String> = await MainActor.run {
            Set(names.compactMap { self.serverName(forNamespacedName: $0) })
        }
        for serverName in serverNames {
            await ensureConnected(serverName: serverName)
        }
    }

    func ensureConnected(serverName: String) async {
        let task = await MainActor.run { self.beginConnectIfNeeded(serverName: serverName) }
        guard let task else { return }
        _ = try? await task.value
    }

    /// Force a fresh connect + `tools/list` for one server now, even if it was
    /// already connected or previously failed. Drives the per-row Test button:
    /// on success the status becomes `.connected(toolCount:)`, on failure
    /// `.failed(reason)`, both bound live by the Settings pane.
    func testServer(name: String) async {
        await MainActor.run { self.resetForTest(serverName: name) }
        await ensureConnected(serverName: name)
    }

    @MainActor
    private func resetForTest(serverName: String) {
        connectTasks[serverName]?.cancel()
        connectTasks[serverName] = nil
        toolCache[serverName] = nil
        if let client = clients[serverName] {
            clients[serverName] = nil
            Task { await client.close() }
        }
        if servers[serverName] != nil {
            statuses[serverName] = .connecting
        }
    }

    func callTool(namespacedName: String, argumentsJSON: String) async throws -> String {
        let serverName: String? = await MainActor.run { self.serverName(forNamespacedName: namespacedName) }
        guard let serverName else {
            throw MCPClientError.serverError(
                method: "tools/call",
                message: "no server for \(namespacedName)"
            )
        }
        await ensureConnected(serverName: serverName)
        let resolved: (MCPClient, MCPToolDescriptor)? = await MainActor.run {
            guard let client = self.clients[serverName],
                  let descriptor = self.descriptor(forNamespacedName: namespacedName) else { return nil }
            return (client, descriptor)
        }
        guard let (client, descriptor) = resolved else {
            throw MCPClientError.serverError(
                method: "tools/call",
                message: "tool \(namespacedName) is not available"
            )
        }
        let raw = try await client.callTool(name: descriptor.toolName, argumentsJSON: argumentsJSON)
        return Self.truncate(raw)
    }

    // MARK: Connection bookkeeping (main thread)

    @MainActor
    private func beginConnectIfNeeded(serverName: String) -> Task<[MCPToolDescriptor], Error>? {
        guard let config = servers[serverName] else { return nil }
        if toolCache[serverName] != nil { return nil }
        if let existing = connectTasks[serverName] { return existing }

        let client: MCPClient
        if let existing = clients[serverName] {
            client = existing
        } else {
            do {
                client = try MCPClient(config: config)
            } catch {
                statuses[serverName] = .failed(readable(error))
                return nil
            }
            clients[serverName] = client
        }
        statuses[serverName] = .connecting
        let task = Task<[MCPToolDescriptor], Error> { [weak self] in
            do {
                let descriptors = try await client.connect()
                await MainActor.run { self?.finishConnect(serverName, descriptors: descriptors) }
                return descriptors
            } catch {
                await MainActor.run { self?.failConnect(serverName, error: error) }
                throw error
            }
        }
        connectTasks[serverName] = task
        return task
    }

    @MainActor
    private func finishConnect(_ serverName: String, descriptors: [MCPToolDescriptor]) {
        connectTasks[serverName] = nil
        guard servers[serverName] != nil else { return } // torn down mid-connect
        toolCache[serverName] = descriptors
        statuses[serverName] = .connected(toolCount: descriptors.count)
    }

    @MainActor
    private func failConnect(_ serverName: String, error: Error) {
        connectTasks[serverName] = nil
        guard servers[serverName] != nil else { return }
        statuses[serverName] = .failed(readable(error))
        AttacheLog.mcp.info(
            "mcp connect failed server=\(serverName, privacy: .public)"
        )
    }

    private func serverName(forNamespacedName namespacedName: String) -> String? {
        guard let parsed = MCPToolNamespace.parse(namespacedName) else { return nil }
        return sanitizedToName[parsed.server]
    }

    private func readable(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    static func truncate(_ text: String) -> String {
        guard text.count > maxResultCharacters else { return text }
        let head = text.prefix(maxResultCharacters)
        return String(head) + "\n\n[Result truncated by Attaché at \(maxResultCharacters) characters.]"
    }

    // MARK: File watching

    private func startWatching() {
        let descriptor = open(configURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReloadAndRearm()
        }
        source.setCancelHandler { [weak self] in
            if let self, self.watchDescriptor >= 0 {
                close(self.watchDescriptor)
                self.watchDescriptor = -1
            }
        }
        watchDescriptor = descriptor
        watchSource = source
        source.resume()
    }

    private func scheduleReloadAndRearm() {
        reloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reload()
            // An editor that replaces the file (rename/delete) invalidates the
            // old descriptor, so re-arm the watch on the new inode.
            self.watchSource?.cancel()
            self.watchSource = nil
            self.startWatching()
        }
        reloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}
