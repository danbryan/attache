import Foundation
import AttacheCore
import Darwin
import Security

final class LocalEventServer {
    typealias EventHandler = (Data) -> Void
    typealias CommandHandler = (LocalCardCommand) -> Bool

    /// Largest request body the server will read. A declared Content-Length above
    /// this is rejected before the body is read (413), so a huge declared length
    /// can't spin the read loop.
    static let maxBodyBytes = 1_000_000
    /// Cap on connections being handled at once, so a flood of slow connections
    /// can't exhaust file descriptors (local-only DoS).
    static let maxConcurrentConnections = 16

    private let requestedPort: UInt16
    /// The port actually bound. Equals `requestedPort` unless 0 was requested, in
    /// which case the OS picked one (used by tests).
    let boundPort: UInt16
    private let token: String
    private let eventHandler: EventHandler
    private let commandHandler: CommandHandler
    private let queue = DispatchQueue(label: "com.bryanlabs.attache.events", attributes: .concurrent)
    private let socketFD: Int32
    private var acceptSource: DispatchSourceRead?

    private let connectionLock = NSLock()
    private var activeConnections = 0

    init(port: UInt16, token: String, eventHandler: @escaping EventHandler, commandHandler: @escaping CommandHandler) throws {
        self.requestedPort = port
        self.token = token
        self.eventHandler = eventHandler
        self.commandHandler = commandHandler

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw Self.posixError()
        }
        socketFD = fd

        var reuse: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let error = Self.posixError()
            Darwin.close(fd)
            throw error
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let error = Self.posixError()
            Darwin.close(fd)
            throw error
        }

        guard Darwin.listen(fd, SOMAXCONN) == 0 else {
            let error = Self.posixError()
            Darwin.close(fd)
            throw error
        }

        boundPort = Self.resolveBoundPort(fd: fd, requested: port)

        try Self.setNonBlocking(fd)
    }

    /// A fresh 32-byte base64url token, and the URL it was written to (0600). Call
    /// once per launch before constructing the server.
    static func provisionToken(fileManager: FileManager = .default) throws -> (token: String, url: URL) {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw Self.posixError() }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let url = AttacheAppSupport.eventTokenURL(fileManager: fileManager)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(token.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return (token, url)
    }

    private static func resolveBoundPort(fd: Int32, requested: UInt16) -> UInt16 {
        if requested != 0 { return requested }
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        return result == 0 ? UInt16(bigEndian: address.sin_port) : requested
    }

    deinit {
        stop()
    }

    func start() {
        guard acceptSource == nil else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptAvailableConnections()
        }
        source.setCancelHandler { [socketFD] in
            Darwin.close(socketFD)
        }
        acceptSource = source
        source.resume()
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
    }

    private func acceptAvailableConnections() {
        while true {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let clientFD = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.accept(socketFD, sockaddrPointer, &length)
                }
            }

            if clientFD < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR {
                    return
                }
                NSLog("\(AttacheAppSupport.appDisplayName) event listener accept failed: \(Self.posixError().localizedDescription)")
                return
            }

            // Refuse extra connections rather than let a flood exhaust FDs.
            guard reserveConnectionSlot() else {
                respond(on: clientFD, status: "503 Service Unavailable", body: #"{"error":"too many connections"}"#)
                Darwin.close(clientFD)
                continue
            }

            queue.async { [self] in
                defer { releaseConnectionSlot() }
                handle(clientFD: clientFD)
            }
        }
    }

    private func reserveConnectionSlot() -> Bool {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        guard activeConnections < Self.maxConcurrentConnections else { return false }
        activeConnections += 1
        return true
    }

    private func releaseConnectionSlot() {
        connectionLock.lock()
        activeConnections -= 1
        connectionLock.unlock()
    }

    private func handle(clientFD: Int32) {
        defer {
            Darwin.close(clientFD)
        }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // Read blocking (bounded by the timeout above): the accepted socket can
        // carry O_NONBLOCK, which would make read() return EAGAIN before the
        // client's request bytes arrive and 400 a valid request.
        let flags = fcntl(clientFD, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK) }

        var requestData = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        var checkedDeclaredLength = false
        while requestData.count <= Self.maxBodyBytes {
            let bytesRead = chunk.withUnsafeMutableBytes { buffer in
                Darwin.read(clientFD, buffer.baseAddress, buffer.count)
            }
            let readErrno = errno

            if bytesRead > 0 {
                requestData.append(chunk, count: bytesRead)
                // Once the header block is in, reject an over-large declared body
                // before reading it, so a bogus Content-Length can't stall us.
                if !checkedDeclaredLength,
                   let declared = HTTPRequest.declaredContentLength(in: requestData) {
                    checkedDeclaredLength = true
                    if declared > Self.maxBodyBytes {
                        respond(on: clientFD, status: "413 Payload Too Large", body: #"{"error":"body too large"}"#)
                        return
                    }
                }
                if let request = HTTPRequest(data: requestData) {
                    route(request, on: clientFD)
                    return
                }
            } else if bytesRead == 0 {
                // Client half-closed; make a final parse attempt before giving up.
                if let request = HTTPRequest(data: requestData) {
                    route(request, on: clientFD)
                    return
                }
                break
            } else if readErrno == EINTR {
                continue
            } else {
                respond(on: clientFD, status: "400 Bad Request", body: #"{"error":"invalid request"}"#)
                return
            }
        }

        respond(on: clientFD, status: "400 Bad Request", body: #"{"error":"invalid request"}"#)
    }

    /// Reject browser-originated requests (cross-origin or DNS-rebinding). Local
    /// tools post with a loopback Host and send no Origin header.
    private func isLocalRequest(_ request: HTTPRequest) -> Bool {
        if request.origin != nil { return false }
        guard let host = request.host?.lowercased() else { return true }
        let loopback = ["127.0.0.1", "localhost", "[::1]", "::1"]
        return loopback.contains(host) || loopback.contains { host == "\($0):\(boundPort)" }
    }

    /// Constant-time-ish comparison of the presented bearer token against ours.
    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard let header = request.authorization else { return false }
        let presented = header.hasPrefix("Bearer ") ? String(header.dropFirst("Bearer ".count)) : header
        let expected = token
        guard presented.utf8.count == expected.utf8.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(presented.utf8, expected.utf8) { difference |= a ^ b }
        return difference == 0
    }

    private func route(_ request: HTTPRequest, on clientFD: Int32) {
        guard isLocalRequest(request) else {
            respond(on: clientFD, status: "403 Forbidden", body: #"{"error":"forbidden"}"#)
            return
        }
        // /health is open so integrators can probe liveness; everything else
        // requires the per-launch token.
        if request.method == "GET", request.path == "/health" {
            respond(on: clientFD, status: "200 OK", body: #"{"status":"ok","bind":"127.0.0.1","port":\#(boundPort)}"#)
            return
        }
        guard isAuthorized(request) else {
            respond(on: clientFD, status: "401 Unauthorized", body: #"{"error":"missing or invalid token; read ~/Library/Application Support/Attache/event-token"}"#)
            return
        }
        if request.method == "POST", request.path == "/events" {
            if let rejectionBody = Self.schemaVersionRejectionBody(for: request.body) {
                respond(on: clientFD, status: "400 Bad Request", body: rejectionBody)
                return
            }
            eventHandler(request.body)
            respond(on: clientFD, status: "202 Accepted", body: #"{"status":"accepted"}"#)
        } else if request.method == "POST", let command = LocalCardCommand(method: request.method, path: request.path) {
            if commandHandler(command) {
                respond(on: clientFD, status: "202 Accepted", body: #"{"status":"accepted"}"#)
            } else {
                respond(on: clientFD, status: "404 Not Found", body: #"{"error":"card not found"}"#)
            }
        } else {
            respond(on: clientFD, status: "404 Not Found", body: #"{"error":"not found"}"#)
        }
    }

    /// JSON error body when `body` names a `schema_version` this server
    /// doesn't support, or nil otherwise (INF-359). This is the one place the
    /// server rejects a `POST /events` payload synchronously; every other
    /// malformed body still gets a 202 and is discarded further down the
    /// async pipeline (`AppModel.ingestEventData`), unchanged by this ticket.
    /// Uses `EventNormalizer` so the wire message stays identical to what
    /// `EventNormalizer.decode` throws for the same payload.
    private static func schemaVersionRejectionBody(for body: Data) -> String? {
        do {
            _ = try EventNormalizer.decode(data: body)
            return nil
        } catch EventNormalizerError.unsupportedSchemaVersion(let requested, let supported) {
            let message = EventNormalizerError
                .unsupportedSchemaVersion(requested: requested, supported: supported)
                .errorDescription ?? "unsupported schema_version"
            let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
            return #"{"error":"\#(escaped)"}"#
        } catch {
            return nil
        }
    }

    private func respond(on clientFD: Int32, status: String, body: String) {
        let response =
            """
            HTTP/1.1 \(status)\r
            Content-Type: application/json\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
        let bytes = Array(response.utf8)
        bytes.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(clientFD, base.advanced(by: written), bytes.count - written)
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    private static func setNonBlocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { throw posixError() }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw posixError()
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

enum LocalCardCommand: Equatable {
    case play(cardID: String)
    case markHeard(cardID: String)

    init?(method: String, path: String) {
        guard method == "POST" else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "cards" else { return nil }
        switch parts[2] {
        case "play":
            self = .play(cardID: parts[1])
        case "mark-heard":
            self = .markHeard(cardID: parts[1])
        default:
            return nil
        }
    }
}

private struct HTTPRequest {
    var method: String
    var path: String
    var host: String?
    var origin: String?
    var authorization: String?
    var body: Data

    init?(data: Data) {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }
        method = String(requestParts[0])
        path = String(requestParts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "content-length": contentLength = Int(parts[1]) ?? 0
            case "host": host = parts[1]
            case "origin": origin = parts[1]
            case "authorization": authorization = parts[1]
            default: break
            }
        }

        let bodyStart = headerRange.upperBound
        let bodyEnd = bodyStart + contentLength
        guard data.count >= bodyEnd else { return nil }
        body = data[bodyStart..<bodyEnd]
    }

    /// The declared Content-Length once the header block has arrived, or nil if
    /// headers are still incomplete. Lets the caller reject an oversized body
    /// before reading it.
    static func declaredContentLength(in data: Data) -> Int? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                return Int(parts[1])
            }
        }
        return nil
    }
}
