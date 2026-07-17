import AttacheCore
import Foundation

/// Typed, readable errors from the minimal MCP client.
enum MCPClientError: Error, LocalizedError, Equatable {
    case launchFailed(String)
    case timeout(method: String)
    case transportClosed
    case httpStatus(Int)
    case invalidResponse
    case malformedResponse(method: String)
    case noMatchingResponse
    case serverError(method: String, message: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let reason):
            return "Could not launch the MCP server (\(reason))."
        case .timeout(let method):
            return "The MCP server did not respond to \(method) in time."
        case .transportClosed:
            return "The MCP connection was closed."
        case .httpStatus(let code):
            return "The MCP server returned HTTP \(code)."
        case .invalidResponse:
            return "The MCP server returned a response Attaché could not read."
        case .malformedResponse(let method):
            return "The MCP server returned a malformed \(method) response."
        case .noMatchingResponse:
            return "The MCP server did not return a response for the request."
        case .serverError(let method, let message):
            return "The MCP server rejected \(method): \(message)"
        }
    }
}

/// One transport a client can speak JSON-RPC over. The client owns request-id
/// assignment; a transport only needs to deliver a message and return the
/// response object whose `id` matches.
protocol MCPTransport: AnyObject {
    func sendRequest(_ message: [String: Any], id: Int, timeout: TimeInterval) async throws -> [String: Any]
    func sendNotification(_ message: [String: Any]) async throws
    func close()
}

/// A minimal MCP client: JSON-RPC 2.0 `initialize`, `notifications/initialized`,
/// `tools/list` (cursor pagination), and `tools/call`. Dependency-free. Timeouts
/// are enforced by the transport; the client never blocks indefinitely.
actor MCPClient {
    static let requestedProtocolVersion = "2025-06-18"
    static let connectTimeout: TimeInterval = 10
    static let callTimeout: TimeInterval = 30
    static let maxToolListPages = 50

    private let config: MCPServerConfig
    private let transport: MCPTransport
    private var nextID = 0
    private var initialized = false
    private(set) var negotiatedProtocolVersion: String?

    init(config: MCPServerConfig) throws {
        self.config = config
        switch config.transport {
        case .stdio:
            self.transport = try StdioMCPTransport(config: config)
        case .http, .streamableHTTP, .sse:
            self.transport = try StreamableHTTPMCPTransport(config: config)
        }
    }

    /// Test seam: inject a transport directly.
    init(config: MCPServerConfig, transport: MCPTransport) {
        self.config = config
        self.transport = transport
    }

    /// Initialize (if needed) and return the server's tools.
    func connect() async throws -> [MCPToolDescriptor] {
        try await initializeIfNeeded()
        return try await listTools()
    }

    func callTool(name: String, argumentsJSON: String) async throws -> String {
        try await initializeIfNeeded()
        var arguments: [String: Any] = [:]
        if let data = argumentsJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            arguments = object
        }
        let result = try await rpcRequest(
            method: "tools/call",
            params: ["name": name, "arguments": arguments],
            timeout: Self.callTimeout
        )
        return Self.renderToolResult(result)
    }

    func close() {
        transport.close()
        initialized = false
    }

    // MARK: JSON-RPC

    private func initializeIfNeeded() async throws {
        guard !initialized else { return }
        let params: [String: Any] = [
            "protocolVersion": Self.requestedProtocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Attache", "version": AttacheAppSupport.appVersion]
        ]
        let result = try await rpcRequest(
            method: "initialize",
            params: params,
            timeout: Self.connectTimeout
        )
        // Accept whatever protocol version the server echoes; fall back to the
        // version we requested when the server omits it.
        negotiatedProtocolVersion = (result["protocolVersion"] as? String)
            ?? Self.requestedProtocolVersion
        try await transport.sendNotification([
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        ])
        initialized = true
    }

    private func listTools() async throws -> [MCPToolDescriptor] {
        var descriptors: [MCPToolDescriptor] = []
        var cursor: String?
        var pages = 0
        repeat {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let result = try await rpcRequest(
                method: "tools/list",
                params: params.isEmpty ? nil : params,
                timeout: Self.connectTimeout
            )
            let tools = (result["tools"] as? [[String: Any]]) ?? []
            for tool in tools {
                if let descriptor = Self.descriptor(from: tool, serverName: config.name) {
                    descriptors.append(descriptor)
                }
            }
            cursor = result["nextCursor"] as? String
            pages += 1
        } while cursor != nil && pages < Self.maxToolListPages
        return descriptors
    }

    private func rpcRequest(
        method: String,
        params: [String: Any]?,
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        let response = try await transport.sendRequest(message, id: id, timeout: timeout)
        if let error = response["error"] as? [String: Any] {
            let text = (error["message"] as? String) ?? "unknown error"
            throw MCPClientError.serverError(method: method, message: text)
        }
        guard let result = response["result"] as? [String: Any] else {
            throw MCPClientError.malformedResponse(method: method)
        }
        return result
    }

    // MARK: Result shaping

    static func descriptor(from tool: [String: Any], serverName: String) -> MCPToolDescriptor? {
        guard let name = (tool["name"] as? String), !name.isEmpty else { return nil }
        let description = (tool["description"] as? String) ?? ""
        var schemaJSON = ""
        if let schema = tool["inputSchema"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            schemaJSON = text
        }
        var isReadOnly = false
        if let annotations = tool["annotations"] as? [String: Any],
           let hint = annotations["readOnlyHint"] as? Bool {
            isReadOnly = hint
        }
        return MCPToolDescriptor(
            serverName: serverName,
            toolName: name,
            description: description,
            schemaJSON: schemaJSON,
            isReadOnly: isReadOnly
        )
    }

    /// Concatenate text content parts; non-text parts become a short
    /// placeholder so a lookup can still report that an image or resource came
    /// back without shipping binary data into the transcript.
    static func renderToolResult(_ result: [String: Any]) -> String {
        let content = (result["content"] as? [[String: Any]]) ?? []
        var parts: [String] = []
        for item in content {
            let type = (item["type"] as? String) ?? ""
            switch type {
            case "text":
                if let text = item["text"] as? String { parts.append(text) }
            case "resource":
                if let resource = item["resource"] as? [String: Any],
                   let text = resource["text"] as? String {
                    parts.append(text)
                } else {
                    parts.append("[resource content]")
                }
            case "":
                parts.append("[content]")
            default:
                parts.append("[\(type) content]")
            }
        }
        let combined = parts.joined(separator: "\n")
        if let isError = result["isError"] as? Bool, isError {
            return combined.isEmpty ? "The tool reported an error." : combined
        }
        return combined
    }
}

// MARK: - stdio transport

/// Launches an MCP server subprocess and speaks newline-delimited JSON-RPC over
/// its stdin/stdout. Non-JSON stdout lines are skipped; stderr is logged. The
/// process is killed on close or deinit.
final class StdioMCPTransport: MCPTransport, @unchecked Sendable {
    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let serverName: String

    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var buffer = Data()
    private var launched = false
    private var closed = false

    init(config: MCPServerConfig) throws {
        guard let command = config.command, !command.isEmpty else {
            throw MCPClientError.launchFailed("no command configured")
        }
        self.serverName = config.name
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in config.env { environment[key] = value }
        process.environment = environment
        // Resolve the command through env so a bare name like "npx" is found on
        // PATH, matching how a shell would launch it.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + config.args
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
    }

    deinit { close() }

    private func launchIfNeeded() throws {
        lock.lock()
        if closed { lock.unlock(); throw MCPClientError.transportClosed }
        if launched { lock.unlock(); return }
        launched = true
        lock.unlock()

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ingest(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let name = self?.serverName ?? "?"
            AttacheLog.mcp.info("mcp stderr server=\(name, privacy: .public) bytes=\(text.count)")
        }
        process.terminationHandler = { [weak self] _ in
            self?.failAllPending(with: MCPClientError.transportClosed)
        }
        do {
            try process.run()
        } catch {
            failAllPending(with: MCPClientError.launchFailed(error.localizedDescription))
            throw MCPClientError.launchFailed(error.localizedDescription)
        }
    }

    private func ingest(_ data: Data) {
        var completed: [(CheckedContinuation<[String: Any], Error>, [String: Any])] = []
        lock.lock()
        buffer.append(data)
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[buffer.startIndex..<newlineIndex])
            buffer = Data(buffer[buffer.index(after: newlineIndex)...])
            if line.last == 0x0D { line = line.dropLast() } // tolerate CRLF framing
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue // skip non-JSON stdout lines
            }
            guard let id = object["id"] as? Int,
                  let continuation = pending.removeValue(forKey: id) else {
                continue // server notification or unmatched id
            }
            completed.append((continuation, object))
        }
        lock.unlock()
        for (continuation, object) in completed {
            continuation.resume(returning: object)
        }
    }

    func sendRequest(_ message: [String: Any], id: Int, timeout: TimeInterval) async throws -> [String: Any] {
        try launchIfNeeded()
        let payload = try Self.encode(message)
        return try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.lock.lock()
                    if self.closed {
                        self.lock.unlock()
                        continuation.resume(throwing: MCPClientError.transportClosed)
                        return
                    }
                    self.pending[id] = continuation
                    self.lock.unlock()
                    do {
                        try self.write(payload)
                    } catch {
                        self.lock.lock()
                        let stored = self.pending.removeValue(forKey: id)
                        self.lock.unlock()
                        stored?.resume(throwing: error)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                self.failPending(id: id, with: MCPClientError.timeout(method: "request"))
                throw MCPClientError.timeout(method: "request")
            }
            defer { group.cancelAll() }
            let value = try await group.next()!
            return value
        }
    }

    func sendNotification(_ message: [String: Any]) async throws {
        try launchIfNeeded()
        try write(try Self.encode(message))
    }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let toFail = pending
        pending.removeAll()
        lock.unlock()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        for (_, continuation) in toFail {
            continuation.resume(throwing: MCPClientError.transportClosed)
        }
    }

    private func write(_ data: Data) throws {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        if isClosed { throw MCPClientError.transportClosed }
        do {
            try inPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw MCPClientError.transportClosed
        }
    }

    private func failPending(id: Int, with error: Error) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    private func failAllPending(with error: Error) {
        lock.lock()
        let toFail = pending
        pending.removeAll()
        lock.unlock()
        for (_, continuation) in toFail {
            continuation.resume(throwing: error)
        }
    }

    private static func encode(_ message: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }
}

// MARK: - streamable HTTP transport

/// POSTs JSON-RPC messages to a URL. Handles both `application/json` and
/// `text/event-stream` (SSE) response bodies, replays the `Mcp-Session-Id`
/// header the server assigns, and treats a 202 with an empty body as a valid
/// response to a notification.
final class StreamableHTTPMCPTransport: MCPTransport, @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private let lock = NSLock()
    private var sessionID: String?

    init(config: MCPServerConfig, session: URLSession = .shared) throws {
        guard let url = config.url else {
            throw MCPClientError.launchFailed("no url configured")
        }
        self.url = url
        self.headers = config.headers
        self.session = session
    }

    func sendRequest(_ message: [String: Any], id: Int, timeout: TimeInterval) async throws -> [String: Any] {
        let (data, http) = try await post(message, timeout: timeout)
        guard (200..<300).contains(http.statusCode) else {
            throw MCPClientError.httpStatus(http.statusCode)
        }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/event-stream") {
            let text = String(decoding: data, as: UTF8.self)
            let messages = Self.parseSSE(text)
            if let match = messages.first(where: { ($0["id"] as? Int) == id }) {
                return match
            }
            throw MCPClientError.noMatchingResponse
        }
        guard !data.isEmpty else { throw MCPClientError.noMatchingResponse }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPClientError.invalidResponse
        }
        return object
    }

    func sendNotification(_ message: [String: Any]) async throws {
        let (_, http) = try await post(message, timeout: MCPClient.connectTimeout)
        guard (200..<300).contains(http.statusCode) else {
            throw MCPClientError.httpStatus(http.statusCode)
        }
    }

    func close() {
        lock.lock()
        sessionID = nil
        lock.unlock()
    }

    private func post(_ message: [String: Any], timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: max(1, timeout))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let currentSessionID = withLock { sessionID }
        if let currentSessionID {
            request.setValue(currentSessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw MCPClientError.timeout(method: (message["method"] as? String) ?? "request")
        } catch {
            throw MCPClientError.invalidResponse
        }
        guard let http = response as? HTTPURLResponse else {
            throw MCPClientError.invalidResponse
        }
        if let assigned = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !assigned.isEmpty {
            withLock { sessionID = assigned }
        }
        return (data, http)
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Parse a `text/event-stream` body into its JSON-RPC message objects.
    /// Accumulates `data:` lines per event (blank line terminates an event),
    /// joins them with newlines, and JSON-decodes each. Comment and non-data
    /// fields are ignored. Pure and side-effect free for unit testing.
    static func parseSSE(_ text: String) -> [[String: Any]] {
        var results: [[String: Any]] = []
        var dataLines: [String] = []

        func flush() {
            guard !dataLines.isEmpty else { return }
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll()
            if let data = payload.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                results.append(object)
            }
        }

        // Normalize line endings first: Swift treats "\r\n" as a single
        // Character, so splitting on "\n" alone never matches a CRLF line, and
        // SSE bodies are CRLF-terminated.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix(":") { continue }
            if line.hasPrefix("data:") {
                var value = String(line.dropFirst("data:".count))
                if value.hasPrefix(" ") { value.removeFirst() }
                dataLines.append(value)
            }
        }
        flush()
        return results
    }
}
