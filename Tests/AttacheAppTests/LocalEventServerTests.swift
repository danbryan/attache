import XCTest
import Darwin
@testable import AttacheApp

final class LocalEventServerTests: XCTestCase {
    private var server: LocalEventServer!
    private let token = "test-token-abc123"
    private var receivedBodies: [Data] = []

    override func setUpWithError() throws {
        receivedBodies = []
        // Port 0 lets the OS pick a free port; boundPort reports it.
        server = try LocalEventServer(port: 0, token: token) { [weak self] body in
            self?.receivedBodies.append(body)
        } commandHandler: { _ in true }
        server.start()
    }

    override func tearDown() {
        server.stop()
        server = nil
    }

    func testEventWithValidTokenAccepted() throws {
        let (status, _) = try request(
            method: "POST", path: "/events",
            headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"],
            body: #"{"source":"codex","title":"Hi","text":"There"}"#
        )
        XCTAssertEqual(status, 202)
        // The handler ran on the server queue; give it a beat to record the body.
        let deadline = Date().addingTimeInterval(1)
        while receivedBodies.isEmpty && Date() < deadline { usleep(5000) }
        XCTAssertEqual(receivedBodies.count, 1)
    }

    func testEventWithoutTokenRejected() throws {
        let (status, body) = try request(
            method: "POST", path: "/events",
            headers: ["Content-Type": "application/json"],
            body: #"{"source":"codex","title":"Hi","text":"There"}"#
        )
        XCTAssertEqual(status, 401)
        XCTAssertTrue(body.contains("event-token"))
        XCTAssertTrue(receivedBodies.isEmpty)
    }

    func testEventWithWrongTokenRejected() throws {
        let (status, _) = try request(
            method: "POST", path: "/events",
            headers: ["Authorization": "Bearer not-the-token"],
            body: #"{"source":"codex"}"#
        )
        XCTAssertEqual(status, 401)
        XCTAssertTrue(receivedBodies.isEmpty)
    }

    func testOversizedDeclaredLengthRejectedWith413() throws {
        // Declare a body far larger than the cap but send a tiny one: the server
        // must 413 on the declared length without waiting for the body.
        let (status, _) = try request(
            method: "POST", path: "/events",
            headers: ["Authorization": "Bearer \(token)", "Content-Length": "9999999999"],
            body: "{}", overrideContentLength: true
        )
        XCTAssertEqual(status, 413)
    }

    func testOriginHeaderRejectedWith403() throws {
        // A browser-originated (cross-origin/DNS-rebinding) request carries Origin.
        let (status, _) = try request(
            method: "POST", path: "/events",
            headers: ["Authorization": "Bearer \(token)", "Origin": "http://evil.example"],
            body: #"{"source":"codex"}"#
        )
        XCTAssertEqual(status, 403)
        XCTAssertTrue(receivedBodies.isEmpty)
    }

    func testHealthOpenWithoutToken() throws {
        let (status, body) = try request(method: "GET", path: "/health", headers: [:], body: nil)
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.contains("\"status\":\"ok\""))
    }

    // MARK: - Minimal loopback HTTP client

    private func request(
        method: String,
        path: String,
        headers: [String: String],
        body: String?,
        overrideContentLength: Bool = false
    ) throws -> (status: Int, body: String) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = server.boundPort.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.connect(fd, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0, "connect to loopback server failed")

        var request = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(server.boundPort)\r\n"
        for (key, value) in headers where key.lowercased() != "content-length" {
            request += "\(key): \(value)\r\n"
        }
        let bodyBytes = Array((body ?? "").utf8)
        if overrideContentLength, let declared = headers["Content-Length"] {
            request += "Content-Length: \(declared)\r\n"
        } else if body != nil {
            request += "Content-Length: \(bodyBytes.count)\r\n"
        }
        request += "\r\n"
        var outBytes = Array(request.utf8)
        outBytes.append(contentsOf: bodyBytes)
        // Write every byte, then half-close so the server sees a definite
        // end-of-request instead of waiting on its receive timeout.
        outBytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < outBytes.count {
                let n = Darwin.write(fd, base.advanced(by: written), outBytes.count - written)
                if n > 0 { written += n } else if n < 0 && errno == EINTR { continue } else { break }
            }
        }
        Darwin.shutdown(fd, SHUT_WR)

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 { response.append(chunk, count: n) } else { break }
        }
        let text = String(data: response, encoding: .utf8) ?? ""
        let statusLine = text.components(separatedBy: "\r\n").first ?? ""
        let statusCode = statusLine.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        let responseBody = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        return (statusCode, responseBody)
    }
}
