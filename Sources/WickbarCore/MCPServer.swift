import Foundation

/// MCP over Streamable HTTP (JSON responses only) + JSON-RPC 2.0 dispatch.
@MainActor
public final class MCPServer {
    public static let latestProtocolVersion = "2025-06-18"
    public static let supportedProtocolVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
    public static let endpointPath = "/mcp"

    public weak var controller: WickbarController?
    public let version: String
    public private(set) var sessionIds: Set<String> = []

    public init(controller: WickbarController, version: String) {
        self.controller = controller
        self.version = version
    }

    // MARK: HTTP layer

    public func handleHTTP(_ req: HTTPRequest) async -> HTTPResponse {
        if let reject = Self.validateHostAndOrigin(req) { return reject }
        guard req.path == Self.endpointPath else {
            return .text("Not found. The MCP endpoint is POST \(Self.endpointPath)\n", status: 404)
        }
        guard req.method == "POST" else {
            return .text("Method not allowed. Use POST \(Self.endpointPath) (no SSE stream is offered).\n", status: 405,
                         extraHeaders: [("Allow", "POST")])
        }
        if let ct = req.header("content-type"), !ct.lowercased().contains("json") {
            return .text("Content-Type must be application/json\n", status: 415)
        }
        let (status, body, sessionId) = await handleBody(req.body)
        var headers: [(String, String)] = []
        if let sessionId { headers.append(("Mcp-Session-Id", sessionId)) }
        guard let body else { return HTTPResponse(status: status, headers: headers) }
        return .json(body, status: status, extraHeaders: headers)
    }

    private static let localHosts: Set<String> = ["127.0.0.1", "localhost", "[::1]", "::1"]

    /// DNS-rebinding protection: Host must be a loopback name; Origin (if any) must be a loopback origin.
    public static func validateHostAndOrigin(_ req: HTTPRequest) -> HTTPResponse? {
        guard let host = req.header("host"), localHosts.contains(hostName(host).lowercased()) else {
            return .text("Forbidden: invalid Host header\n", status: 403)
        }
        if let origin = req.header("origin") {
            guard let url = URL(string: origin), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let h = url.host?.lowercased(), localHosts.contains(h) || localHosts.contains("[\(h)]") else {
                return .text("Forbidden: origin not allowed\n", status: 403)
            }
        }
        return nil
    }

    /// Strips the port from a Host header value (handles `[::1]:9425`).
    static func hostName(_ host: String) -> String {
        let h = host.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("[") {
            if let close = h.firstIndex(of: "]") { return String(h[...close]) }
            return h
        }
        if let colon = h.lastIndex(of: ":"), h.filter({ $0 == ":" }).count == 1 { return String(h[..<colon]) }
        return h
    }

    // MARK: JSON-RPC layer

    /// Returns (HTTP status, JSON body or nil for 202, session id header to send).
    public func handleBody(_ data: Data) async -> (Int, JSONValue?, String?) {
        let message: JSONValue
        do {
            message = try JSONValue.parse(data)
        } catch {
            return (400, Self.errorResponse(id: .null, code: -32700, message: "Parse error: \(error.localizedDescription)"), nil)
        }
        var newSession: String?
        if case .array(let batch) = message {
            if batch.isEmpty {
                return (400, Self.errorResponse(id: .null, code: -32600, message: "Invalid Request: empty batch"), nil)
            }
            var responses: [JSONValue] = []
            for item in batch {
                let (resp, sid) = await dispatch(item)
                if let resp { responses.append(resp) }
                if let sid { newSession = sid }
            }
            return responses.isEmpty ? (202, nil, newSession) : (200, .array(responses), newSession)
        }
        let (resp, sid) = await dispatch(message)
        guard let resp else { return (202, nil, sid) }
        return (200, resp, sid)
    }

    /// Dispatches one JSON-RPC message. Returns nil for notifications and client responses.
    public func dispatch(_ message: JSONValue) async -> (JSONValue?, String?) {
        guard case .object(let obj) = message else {
            return (Self.errorResponse(id: .null, code: -32600, message: "Invalid Request"), nil)
        }
        let id = obj["id"]
        guard let method = obj["method"]?.stringValue else {
            // A response from the client (result/error) — accept and ignore.
            if obj["result"] != nil || obj["error"] != nil { return (nil, nil) }
            return (Self.errorResponse(id: id ?? .null, code: -32600, message: "Invalid Request: missing method"), nil)
        }
        let isNotification = id == nil
        if isNotification || method.hasPrefix("notifications/") {
            return (nil, nil)
        }
        let params = obj["params"]?.objectValue ?? [:]
        let rid = id ?? .null

        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue
            let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil } ?? Self.latestProtocolVersion
            let sid = UUID().uuidString
            sessionIds.insert(sid)
            let result: JSONValue = [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "wickbar", "title": "Wickbar", "version": .string(self.version)],
                "instructions": "Wickbar keeps long-running terminal commands (dev servers, tunnels, agents) alive on this Mac. Use list_commands to see them; refer to a command by its name or id.",
            ]
            return (Self.resultResponse(id: rid, result: result), sid)

        case "ping":
            return (Self.resultResponse(id: rid, result: [:]), nil)

        case "tools/list":
            return (Self.resultResponse(id: rid, result: ["tools": .array(MCPTools.definitions)]), nil)

        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return (Self.errorResponse(id: rid, code: -32602, message: "Invalid params: missing tool name"), nil)
            }
            guard let controller else {
                return (Self.errorResponse(id: rid, code: -32603, message: "Wickbar is shutting down"), nil)
            }
            let args = params["arguments"]?.objectValue ?? [:]
            do {
                let result = try await MCPTools.call(name: name, arguments: args, controller: controller)
                return (Self.resultResponse(id: rid, result: result.jsonValue), nil)
            } catch let e as UnknownToolError {
                return (Self.errorResponse(id: rid, code: -32602,
                                           message: "Unknown tool: \(e.name). Available: \(MCPTools.toolNames.joined(separator: ", "))"), nil)
            } catch {
                return (Self.errorResponse(id: rid, code: -32603, message: error.localizedDescription), nil)
            }

        case "resources/list":
            return (Self.resultResponse(id: rid, result: ["resources": []]), nil)
        case "prompts/list":
            return (Self.resultResponse(id: rid, result: ["prompts": []]), nil)

        default:
            return (Self.errorResponse(id: rid, code: -32601, message: "Method not found: \(method)"), nil)
        }
    }

    public static func resultResponse(id: JSONValue, result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    public static func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }
}
