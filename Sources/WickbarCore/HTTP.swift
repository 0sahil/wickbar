import Foundation

public struct HTTPRequest: Sendable {
    public var method: String
    public var target: String
    public var version: String
    /// Header names are lower-cased.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, target: String, version: String = "HTTP/1.1", headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body
    }

    public var path: String {
        String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Whether the connection should stay open after the response.
    public var keepAlive: Bool {
        let conn = header("connection")?.lowercased() ?? ""
        if version == "HTTP/1.0" { return conn.contains("keep-alive") }
        return !conn.contains("close")
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ value: JSONValue, status: Int = 200, extraHeaders: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")] + extraHeaders, body: value.encoded())
    }

    public static func text(_ text: String, status: Int, extraHeaders: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")] + extraHeaders, body: Data(text.utf8))
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    public static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        default: return "Status \(status)"
        }
    }

    public func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\n"
        for (k, v) in headers where k.lowercased() != "content-length" && k.lowercased() != "connection" {
            head += "\(k): \(v)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

/// Incremental HTTP/1.1 request parser: feed it bytes as they arrive; it handles partial reads,
/// Content-Length and chunked bodies, and pipelined requests.
public struct HTTPRequestParser {
    public enum Result {
        case incomplete
        case request(HTTPRequest)
        case error(status: Int, message: String)
    }

    public static let maxHeaderBytes = 64 * 1024
    public static let maxBodyBytes = 8 * 1024 * 1024

    public private(set) var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) { buffer.append(data) }

    /// If the head is complete and the client sent `Expect: 100-continue`, returns true (once per request).
    public func headExpectsContinue() -> Bool {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self).lowercased()
        return head.contains("\r\nexpect: 100-continue")
    }

    /// Tries to take one complete request off the front of the buffer.
    public mutating func next() -> Result {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maxHeaderBytes { return .error(status: 431, message: "Headers too large") }
            return .incomplete
        }
        let headData = buffer[buffer.startIndex..<headEnd.lowerBound]
        let head = String(decoding: headData, as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        // Tolerate leading blank lines between pipelined requests.
        while lines.first == "" { lines.removeFirst() }
        guard let requestLine = lines.first else { return .error(status: 400, message: "Empty request") }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            return .error(status: 400, message: "Malformed request line")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .error(status: 400, message: "Malformed header") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] { headers[name] = existing + ", " + value } else { headers[name] = value }
        }
        let bodyStart = headEnd.upperBound
        var body = Data()
        var consumedEnd = bodyStart

        if let te = headers["transfer-encoding"], te.lowercased().contains("chunked") {
            switch Self.decodeChunked(buffer, from: bodyStart) {
            case .incomplete: return .incomplete
            case .invalid: return .error(status: 400, message: "Malformed chunked body")
            case .tooLarge: return .error(status: 413, message: "Body too large")
            case .done(let b, let end):
                body = b
                consumedEnd = end
            }
        } else if let cl = headers["content-length"] {
            guard let length = Int(cl.trimmingCharacters(in: .whitespaces)), length >= 0 else {
                return .error(status: 400, message: "Invalid Content-Length")
            }
            if length > Self.maxBodyBytes { return .error(status: 413, message: "Body too large") }
            guard buffer.endIndex - bodyStart >= length else { return .incomplete }
            body = Data(buffer[bodyStart..<(bodyStart + length)])
            consumedEnd = bodyStart + length
        }

        buffer = Data(buffer[consumedEnd...])
        return .request(HTTPRequest(method: String(parts[0]).uppercased(), target: String(parts[1]),
                                    version: String(parts[2]), headers: headers, body: body))
    }

    private enum ChunkResult { case incomplete, invalid, tooLarge, done(Data, Int) }

    private static func decodeChunked(_ buf: Data, from start: Int) -> ChunkResult {
        var pos = start
        var out = Data()
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = buf.range(of: crlf, in: pos..<buf.endIndex) else { return .incomplete }
            let sizeLine = String(decoding: buf[pos..<lineEnd.lowerBound], as: UTF8.self)
            let sizeHex = sizeLine.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeHex, radix: 16), size >= 0 else { return .invalid }
            pos = lineEnd.upperBound
            if size == 0 {
                // Skip trailers until an empty line.
                while true {
                    guard let tEnd = buf.range(of: crlf, in: pos..<buf.endIndex) else { return .incomplete }
                    let empty = tEnd.lowerBound == pos
                    pos = tEnd.upperBound
                    if empty { return .done(out, pos) }
                }
            }
            if out.count + size > maxBodyBytes { return .tooLarge }
            guard buf.endIndex - pos >= size + 2 else { return .incomplete }
            out.append(buf[pos..<(pos + size)])
            pos += size
            guard buf[pos] == 0x0D, buf[pos + 1] == 0x0A else { return .invalid }
            pos += 2
        }
    }
}
