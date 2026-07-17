import XCTest
@testable import AttacheApp

final class MCPSSEParsingTests: XCTestCase {
    func testParsesJSONRPCResponseFromEventStream() {
        let fixture = """
        event: message
        data: {"jsonrpc":"2.0","id":7,"result":{"tools":[]}}

        event: message
        data: {"jsonrpc":"2.0","id":8,"result":{"content":[{"type":"text","text":"hi"}]}}

        """
        let messages = StreamableHTTPMCPTransport.parseSSE(fixture)
        XCTAssertEqual(messages.count, 2)
        let match = messages.first { ($0["id"] as? Int) == 8 }
        let result = match?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, "hi")
    }

    func testMultiLineDataAndCommentsAndCRLF() {
        let fixture = ": a comment line\r\ndata: {\"jsonrpc\":\"2.0\",\r\ndata: \"id\":1,\"result\":{}}\r\n\r\n"
        let messages = StreamableHTTPMCPTransport.parseSSE(fixture)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["id"] as? Int, 1)
    }

    func testIgnoresUnparseableData() {
        let fixture = "data: not json\n\ndata: {\"id\":2}\n\n"
        let messages = StreamableHTTPMCPTransport.parseSSE(fixture)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["id"] as? Int, 2)
    }
}
