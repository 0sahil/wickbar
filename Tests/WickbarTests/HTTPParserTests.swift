import XCTest
@testable import WickbarCore

final class HTTPParserTests: XCTestCase {
    func testPartialReadsAndContentLength() {
        var p = HTTPRequestParser()
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let raw = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:9425\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let bytes = Array(raw.utf8)
        // Feed one byte at a time; only the final byte should complete the request.
        for (i, byte) in bytes.enumerated() {
            p.append(Data([byte]))
            let r = p.next()
            if i < bytes.count - 1 {
                guard case .incomplete = r else { return XCTFail("completed early at byte \(i)") }
            } else {
                guard case .request(let req) = r else { return XCTFail("expected request") }
                XCTAssertEqual(req.method, "POST")
                XCTAssertEqual(req.path, "/mcp")
                XCTAssertEqual(req.header("HOST"), "127.0.0.1:9425")
                XCTAssertEqual(String(decoding: req.body, as: UTF8.self), body)
                XCTAssertTrue(req.keepAlive)
            }
        }
        XCTAssertTrue(p.buffer.isEmpty)
    }

    func testPipelinedRequests() {
        var p = HTTPRequestParser()
        p.append(Data("POST /a HTTP/1.1\r\nContent-Length: 2\r\n\r\nhiGET /b HTTP/1.1\r\nConnection: close\r\n\r\n".utf8))
        guard case .request(let a) = p.next() else { return XCTFail() }
        XCTAssertEqual(String(decoding: a.body, as: UTF8.self), "hi")
        guard case .request(let b) = p.next() else { return XCTFail() }
        XCTAssertEqual(b.method, "GET")
        XCTAssertFalse(b.keepAlive)
        guard case .incomplete = p.next() else { return XCTFail() }
    }

    func testChunkedBody() {
        var p = HTTPRequestParser()
        p.append(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n".utf8))
        guard case .incomplete = p.next() else { return XCTFail() }
        p.append(Data("6;ext=1\r\n world\r\n0\r\n\r\n".utf8))
        guard case .request(let r) = p.next() else { return XCTFail() }
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "hello world")
    }

    func testMalformed() {
        var p = HTTPRequestParser()
        p.append(Data("garbage\r\n\r\n".utf8))
        guard case .error(let status, _) = p.next() else { return XCTFail() }
        XCTAssertEqual(status, 400)
    }

    func testExpectContinue() {
        var p = HTTPRequestParser()
        p.append(Data("POST /mcp HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n".utf8))
        XCTAssertTrue(p.headExpectsContinue())
        guard case .incomplete = p.next() else { return XCTFail() }
    }

    func testResponseSerialization() {
        let r = HTTPResponse.json(["ok": true], extraHeaders: [("Mcp-Session-Id", "abc")])
        let text = String(decoding: r.serialized(keepAlive: true), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 11\r\n"))
        XCTAssertTrue(text.contains("Mcp-Session-Id: abc\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"ok\":true}"))
    }
}
