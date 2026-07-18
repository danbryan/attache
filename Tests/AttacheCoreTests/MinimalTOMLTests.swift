import XCTest
@testable import AttacheCore

final class MinimalTOMLTests: XCTestCase {
    func testSimpleTableWithString() {
        let toml = MinimalTOML.parse("""
        [server]
        command = "node"
        """)
        XCTAssertEqual(toml["server"], .table(["command": .string("node")]))
    }

    func testDottedTableHeadersNest() {
        let toml = MinimalTOML.parse("""
        [mcp_servers.fantastical]
        command = "node"
        args = ["/path/index.js"]

        [mcp_servers.fantastical.env]
        EXCLUDED = "Work, Personal"
        """)
        guard case .table(let servers)? = toml["mcp_servers"],
              case .table(let fantastical)? = servers["fantastical"] else {
            return XCTFail("expected nested tables")
        }
        XCTAssertEqual(fantastical["command"], .string("node"))
        XCTAssertEqual(fantastical["args"], .array([.string("/path/index.js")]))
        XCTAssertEqual(fantastical["env"], .table(["EXCLUDED": .string("Work, Personal")]))
    }

    func testInlineTableEnv() {
        let toml = MinimalTOML.parse(#"""
        [s]
        env = { API_KEY = "abc123", REGION = "us-east" }
        """#)
        guard case .table(let s)? = toml["s"] else { return XCTFail("no table") }
        XCTAssertEqual(s["env"], .table(["API_KEY": .string("abc123"), "REGION": .string("us-east")]))
    }

    func testCommentsAreStripped() {
        let toml = MinimalTOML.parse("""
        # a leading comment
        [s]
        command = "run" # trailing comment
        url = "" # empty
        """)
        guard case .table(let s)? = toml["s"] else { return XCTFail("no table") }
        XCTAssertEqual(s["command"], .string("run"))
    }

    func testHashInsideStringIsNotAComment() {
        let toml = MinimalTOML.parse(#"""
        [s]
        token = "abc#not-a-comment"
        """#)
        guard case .table(let s)? = toml["s"] else { return XCTFail("no table") }
        XCTAssertEqual(s["token"], .string("abc#not-a-comment"))
    }

    func testEqualsAndBracketsInsideQuotedString() {
        let toml = MinimalTOML.parse(#"""
        [s]
        args = ["--flag=value", "a[b]c", "x=y#z"]
        """#)
        guard case .table(let s)? = toml["s"] else { return XCTFail("no table") }
        XCTAssertEqual(s["args"], .array([.string("--flag=value"), .string("a[b]c"), .string("x=y#z")]))
    }

    func testEscapeSequencesInBasicString() {
        let toml = MinimalTOML.parse(#"""
        [s]
        path = "C:\\Users\\dan"
        quoted = "say \"hi\""
        newline = "a\nb"
        """#)
        guard case .table(let s)? = toml["s"] else { return XCTFail("no table") }
        XCTAssertEqual(s["path"], .string(#"C:\Users\dan"#))
        XCTAssertEqual(s["quoted"], .string(#"say "hi""#))
        XCTAssertEqual(s["newline"], .string("a\nb"))
    }

    func testLiteralStringHasNoEscapes() {
        let toml = MinimalTOML.parse(#"""
        [s]
        path = 'C:\Users\dan'
        """#)
        guard case .table(let s)? = toml["s"] else { return XCTFail("no table") }
        XCTAssertEqual(s["path"], .string(#"C:\Users\dan"#))
    }

    func testBooleanAndInteger() {
        let toml = MinimalTOML.parse("""
        [s]
        enabled = false
        retries = 3
        """)
        guard case .table(let s)? = toml["s"] else { return XCTFail("no table") }
        XCTAssertEqual(s["enabled"], .boolean(false))
        XCTAssertEqual(s["retries"], .integer(3))
    }

    func testMultilineArrayIsJoined() {
        let toml = MinimalTOML.parse("""
        [s]
        args = [
          "a",
          "b",
          "c",
        ]
        """)
        guard case .table(let s)? = toml["s"] else { return XCTFail("no table") }
        XCTAssertEqual(s["args"], .array([.string("a"), .string("b"), .string("c")]))
    }

    func testHeaderSubtableForHTTPHeaders() {
        let toml = MinimalTOML.parse(#"""
        [mcp_servers.remote]
        url = "https://example.com/mcp"

        [mcp_servers.remote.http_headers]
        Authorization = "Bearer token-value"
        """#)
        guard case .table(let servers)? = toml["mcp_servers"],
              case .table(let remote)? = servers["remote"] else {
            return XCTFail("expected nested tables")
        }
        XCTAssertEqual(remote["url"], .string("https://example.com/mcp"))
        XCTAssertEqual(remote["http_headers"], .table(["Authorization": .string("Bearer token-value")]))
    }

    func testEmptyInputIsEmptyTable() {
        XCTAssertTrue(MinimalTOML.parse("").isEmpty)
        XCTAssertTrue(MinimalTOML.parse("# only a comment\n").isEmpty)
    }
}
