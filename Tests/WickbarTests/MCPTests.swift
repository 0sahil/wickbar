import XCTest
@testable import WickbarCore

/// In-memory controller standing in for the app's ProcessManager.
@MainActor
final class MockController: WickbarController {
    var commandConfigs: [CommandConfig] = []
    var infos: [UUID: CommandRuntimeInfo] = [:]
    var logsText: [UUID: String] = [:]
    var sentInput: [(UUID, String)] = []
    var appSettings = AppSettings()
    var launchAtLogin = LaunchAtLoginInfo(enabled: false, status: "disabled")
    var configPath = "/tmp/wickbar/config.json"
    var restarts: [UUID] = []

    func runtimeInfo(for id: UUID) -> CommandRuntimeInfo { infos[id] ?? CommandRuntimeInfo() }

    func addCommand(_ config: CommandConfig) throws { commandConfigs.append(config) }

    func updateCommand(_ config: CommandConfig) async throws -> Bool {
        guard let i = commandConfigs.firstIndex(where: { $0.id == config.id }) else { throw WickbarError("nope") }
        let restart = runtimeInfo(for: config.id).status.hasProcess && config.runtimeDiffers(from: commandConfigs[i])
        commandConfigs[i] = config
        if restart { restarts.append(config.id) }
        return restart
    }

    func removeCommand(id: UUID) async throws {
        infos[id] = nil
        commandConfigs.removeAll { $0.id == id }
    }

    func startCommand(id: UUID) throws {
        infos[id] = CommandRuntimeInfo(status: .running, pid: 4242, startedAt: Date().addingTimeInterval(-5))
    }

    func stopCommand(id: UUID) async { infos[id] = CommandRuntimeInfo(status: .stopped, lastExitWasSignal: true) }

    func restartCommand(id: UUID) async throws {
        restarts.append(id)
        try startCommand(id: id)
    }

    func startAll() { for c in commandConfigs { try? startCommand(id: c.id) } }
    func stopAll() async { for c in commandConfigs { await stopCommand(id: c.id) } }

    func logs(for id: UUID, lines: Int) -> String {
        (logsText[id] ?? "").split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    func sendInput(to id: UUID, text: String) throws { sentInput.append((id, text)) }

    func updateSettings(autoStartOnLaunch: Bool?, restoreAfterCrash: RestoreAfterCrash?) throws {
        if let a = autoStartOnLaunch { appSettings.autoStartOnLaunch = a }
        if let r = restoreAfterCrash { appSettings.restoreAfterCrash = r }
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        launchAtLogin = LaunchAtLoginInfo(enabled: enabled, status: enabled ? "enabled" : "disabled")
    }
}

@MainActor
final class MCPTests: XCTestCase {
    var controller: MockController!
    var server: MCPServer!

    override func setUp() async throws {
        controller = MockController()
        server = MCPServer(controller: controller, version: "9.9.9")
    }

    private func rpc(_ method: String, id: Int = 1, params: JSONValue? = nil) async -> JSONValue {
        var msg: [String: JSONValue] = ["jsonrpc": "2.0", "id": .int(id), "method": .string(method)]
        if let params { msg["params"] = params }
        let (resp, _) = await server.dispatch(.object(msg))
        return resp ?? .null
    }

    private func call(_ tool: String, _ args: [String: JSONValue] = [:]) async -> (text: String, isError: Bool) {
        let resp = await rpc("tools/call", params: ["name": .string(tool), "arguments": .object(args)])
        let result = resp["result"]
        let text = result?["content"]?.arrayValue?.first?["text"]?.stringValue ?? "<no text: \(resp.encodedString())>"
        return (text, result?["isError"]?.boolValue ?? false)
    }

    private func callJSON(_ tool: String, _ args: [String: JSONValue] = [:]) async throws -> JSONValue {
        let r = await call(tool, args)
        XCTAssertFalse(r.isError, r.text)
        return try JSONValue.parse(Data(r.text.utf8))
    }

    // MARK: JSON-RPC

    func testInitializeEchoesSupportedVersion() async {
        let resp = await rpc("initialize", params: ["protocolVersion": "2025-03-26", "capabilities": [:],
                                                    "clientInfo": ["name": "test", "version": "1"]])
        XCTAssertEqual(resp["jsonrpc"], "2.0")
        XCTAssertEqual(resp["id"], 1)
        XCTAssertEqual(resp["result"]?["protocolVersion"], "2025-03-26")
        XCTAssertEqual(resp["result"]?["serverInfo"]?["name"], "wickbar")
        XCTAssertEqual(resp["result"]?["serverInfo"]?["version"], "9.9.9")
        XCTAssertNotNil(resp["result"]?["capabilities"]?["tools"])
    }

    func testInitializeFallsBackForUnknownVersion() async {
        let resp = await rpc("initialize", params: ["protocolVersion": "1999-01-01"])
        XCTAssertEqual(resp["result"]?["protocolVersion"], .string(MCPServer.latestProtocolVersion))
        XCTAssertEqual(MCPServer.latestProtocolVersion, "2025-06-18")
    }

    func testInitializeReturnsSessionHeader() async {
        let req = HTTPRequest(method: "POST", target: "/mcp",
                              headers: ["Host": "127.0.0.1:9425", "Content-Type": "application/json"],
                              body: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#.utf8))
        let resp = await server.handleHTTP(req)
        XCTAssertEqual(resp.status, 200)
        XCTAssertNotNil(resp.header("Mcp-Session-Id"))
        XCTAssertEqual(resp.header("Content-Type"), "application/json")
    }

    func testNotificationsReturn202() async {
        let (status, body, _) = await server.handleBody(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        XCTAssertEqual(status, 202)
        XCTAssertNil(body)
    }

    func testPing() async {
        let resp = await rpc("ping", id: 7)
        XCTAssertEqual(resp["id"], 7)
        XCTAssertEqual(resp["result"], .object([:]))
    }

    func testUnknownMethod() async {
        let resp = await rpc("does/not/exist")
        XCTAssertEqual(resp["error"]?["code"], -32601)
    }

    func testParseError() async {
        let (status, body, _) = await server.handleBody(Data("{not json".utf8))
        XCTAssertEqual(status, 400)
        XCTAssertEqual(body?["error"]?["code"], -32700)
    }

    func testBatch() async {
        let batch = #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":"b","method":"tools/list"}]"#
        let (status, body, _) = await server.handleBody(Data(batch.utf8))
        XCTAssertEqual(status, 200)
        let arr = body?.arrayValue ?? []
        XCTAssertEqual(arr.count, 2)
        XCTAssertEqual(arr[0]["id"], 1)
        XCTAssertEqual(arr[1]["id"], "b")
    }

    func testBatchOfOnlyNotificationsIs202() async {
        let (status, body, _) = await server.handleBody(Data(#"[{"jsonrpc":"2.0","method":"notifications/initialized"}]"#.utf8))
        XCTAssertEqual(status, 202)
        XCTAssertNil(body)
    }

    func testToolsListHasSchemasForAllTools() async {
        let resp = await rpc("tools/list")
        let tools = resp["result"]?["tools"]?.arrayValue ?? []
        let names = Set(tools.compactMap { $0["name"]?.stringValue })
        XCTAssertEqual(names, ["list_commands", "get_command", "add_command", "update_command", "remove_command",
                               "start_command", "stop_command", "restart_command", "start_all", "stop_all",
                               "get_logs", "send_input", "get_settings", "update_settings"])
        for t in tools {
            XCTAssertEqual(t["inputSchema"]?["type"], "object", "\(t)")
            XCTAssertFalse(t["description"]?.stringValue?.isEmpty ?? true)
        }
    }

    func testUnknownToolIsProtocolError() async {
        let resp = await rpc("tools/call", params: ["name": "explode", "arguments": [:]])
        XCTAssertEqual(resp["error"]?["code"], -32602)
    }

    // MARK: Tools

    func testAddListStartLogsStopRemove() async throws {
        let added = try await callJSON("add_command", ["name": "ticker", "command": "while true; do date; sleep 1; done",
                                                       "start_now": true, "environment": ["A": "1"]])
        XCTAssertEqual(added["command"]?["status"], "running")
        XCTAssertEqual(controller.commandConfigs.count, 1)
        let id = controller.commandConfigs[0].id
        XCTAssertEqual(controller.commandConfigs[0].environment, ["A": "1"])

        let list = try await callJSON("list_commands")
        let first = list["commands"]?.arrayValue?.first
        XCTAssertEqual(first?["name"], "ticker")
        XCTAssertEqual(first?["pid"], 4242)
        XCTAssertNotNil(first?["uptime_seconds"]?.intValue)

        controller.logsText[id] = "a\nb\nc"
        let logs = await call("get_logs", ["command": "TICKER", "lines": 2])
        XCTAssertEqual(logs.text, "b\nc")
        XCTAssertFalse(logs.isError)

        let stopped = try await callJSON("stop_command", ["command": .string(id.uuidString)])
        XCTAssertEqual(stopped["command"]?["status"], "stopped")

        _ = try await callJSON("remove_command", ["command": "ticker"])
        XCTAssertTrue(controller.commandConfigs.isEmpty)
    }

    func testAddRejectsDuplicateNameAndEmptyFields() async {
        controller.commandConfigs = [CommandConfig(name: "API", command: "x")]
        let dup = await call("add_command", ["name": "api", "command": "y"])
        XCTAssertTrue(dup.isError)
        XCTAssertTrue(dup.text.contains("already exists"))
        let empty = await call("add_command", ["name": "  ", "command": "y"])
        XCTAssertTrue(empty.isError)
        let missing = await call("add_command", ["name": "z"])
        XCTAssertTrue(missing.isError)
        let badPolicy = await call("add_command", ["name": "z", "command": "y", "restart_policy": "sometimes"])
        XCTAssertTrue(badPolicy.isError)
    }

    func testUpdateRestartsOnlyWhenRuntimeFieldsChange() async throws {
        let c = CommandConfig(name: "srv", command: "old")
        controller.commandConfigs = [c]
        try controller.startCommand(id: c.id)

        let renamed = try await callJSON("update_command", ["command": "srv", "name": "server", "auto_start": true])
        XCTAssertEqual(renamed["restarted"], false)
        XCTAssertEqual(controller.commandConfigs[0].name, "server")
        XCTAssertTrue(controller.commandConfigs[0].autoStart)

        let changed = try await callJSON("update_command", ["command": "server", "command_line": "new"])
        XCTAssertEqual(changed["restarted"], true)
        XCTAssertTrue(changed["message"]?.stringValue?.contains("restarted") ?? false)
        XCTAssertEqual(controller.commandConfigs[0].command, "new")
        XCTAssertEqual(controller.restarts, [c.id])
    }

    func testToolErrorsAreResultsWithIsError() async {
        let r = await call("get_command", ["command": "nope"])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("No command"))
    }

    func testSendInputAppendsEnter() async throws {
        let c = CommandConfig(name: "repl", command: "cat")
        controller.commandConfigs = [c]
        let notRunning = await call("send_input", ["command": "repl", "text": "hi"])
        XCTAssertTrue(notRunning.isError)
        try controller.startCommand(id: c.id)
        _ = await call("send_input", ["command": "repl", "text": "hi"])
        _ = await call("send_input", ["command": "repl", "text": "raw", "press_enter": false])
        XCTAssertEqual(controller.sentInput.map(\.1), ["hi\r", "raw"])
    }

    func testGetLogsClampsLines() async {
        let c = CommandConfig(name: "x", command: "y")
        controller.commandConfigs = [c]
        controller.logsText[c.id] = (1...6000).map(String.init).joined(separator: "\n")
        let r = await call("get_logs", ["command": "x", "lines": 100000])
        XCTAssertEqual(r.text.split(separator: "\n").count, MCPTools.maxLogLines)
        let d = await call("get_logs", ["command": "x"])
        XCTAssertEqual(d.text.split(separator: "\n").count, MCPTools.defaultLogLines)
    }

    func testSettingsTools() async throws {
        let s = try await callJSON("update_settings", ["auto_start_on_launch": false, "restore_after_crash": "always",
                                                       "launch_at_login": true])
        XCTAssertEqual(s["auto_start_on_launch"], false)
        XCTAssertEqual(s["restore_after_crash"], "always")
        XCTAssertEqual(s["launch_at_login"], true)
        let bad = await call("update_settings", ["restore_after_crash": "maybe"])
        XCTAssertTrue(bad.isError)
        let g = try await callJSON("get_settings")
        XCTAssertEqual(g["mcp_port"], 9425)
    }

    func testStartAllStopAll() async throws {
        controller.commandConfigs = [CommandConfig(name: "a", command: "x"), CommandConfig(name: "b", command: "y")]
        let started = try await callJSON("start_all")
        XCTAssertEqual(started["commands"]?.arrayValue?.compactMap { $0["status"]?.stringValue }, ["running", "running"])
        let stopped = try await callJSON("stop_all")
        XCTAssertEqual(stopped["commands"]?.arrayValue?.compactMap { $0["status"]?.stringValue }, ["stopped", "stopped"])
    }

    // MARK: HTTP security

    private func post(_ headers: [String: String], method: String = "POST", path: String = "/mcp") async -> HTTPResponse {
        await server.handleHTTP(HTTPRequest(method: method, target: path, headers: headers,
                                            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)))
    }

    func testOriginValidation() async {
        let ok = await post(["Host": "127.0.0.1:9425", "Origin": "http://localhost:3000"])
        XCTAssertEqual(ok.status, 200)
        let evil = await post(["Host": "127.0.0.1:9425", "Origin": "http://evil.com"])
        XCTAssertEqual(evil.status, 403)
        let sneaky = await post(["Host": "127.0.0.1:9425", "Origin": "http://localhost.evil.com"])
        XCTAssertEqual(sneaky.status, 403)
        let null = await post(["Host": "127.0.0.1:9425", "Origin": "null"])
        XCTAssertEqual(null.status, 403)
        let noOrigin = await post(["Host": "localhost:9425"])
        XCTAssertEqual(noOrigin.status, 200)
        let v6 = await post(["Host": "[::1]:9425", "Origin": "http://[::1]:9425"])
        XCTAssertEqual(v6.status, 200)
    }

    func testHostValidation() async {
        let rebinding = await post(["Host": "evil.com:9425"])
        XCTAssertEqual(rebinding.status, 403)
        let missing = await post([:])
        XCTAssertEqual(missing.status, 403)
    }

    func testMethodAndPath() async {
        let get = await post(["Host": "127.0.0.1:9425"], method: "GET")
        XCTAssertEqual(get.status, 405)
        let other = await post(["Host": "127.0.0.1:9425"], path: "/other")
        XCTAssertEqual(other.status, 404)
        let query = await post(["Host": "127.0.0.1:9425"], path: "/mcp?x=1")
        XCTAssertEqual(query.status, 200)
    }
}

final class CommandLookupTests: XCTestCase {
    let a = CommandConfig(name: "kanzo", command: "kanzo")
    let b = CommandConfig(name: "Hermes", command: "hermes dashboard --no-open")

    func testById() {
        XCTAssertEqual(try CommandLookup.find(b.id.uuidString, in: [a, b]).get(), b)
        XCTAssertEqual(try CommandLookup.find(b.id.uuidString.lowercased(), in: [a, b]).get(), b)
    }

    func testByExactAndCaseInsensitiveName() {
        XCTAssertEqual(try CommandLookup.find("kanzo", in: [a, b]).get(), a)
        XCTAssertEqual(try CommandLookup.find("hermes", in: [a, b]).get(), b)
        XCTAssertEqual(try CommandLookup.find("  HERMES ", in: [a, b]).get(), b)
    }

    func testExactBeatsCaseInsensitive() {
        let upper = CommandConfig(name: "API", command: "x")
        let lower = CommandConfig(name: "api", command: "y")
        XCTAssertEqual(try CommandLookup.find("api", in: [upper, lower]).get(), lower)
        if case .success = CommandLookup.find("Api", in: [upper, lower]) { XCTFail("should be ambiguous") }
    }

    func testMissing() {
        guard case .failure(let e) = CommandLookup.find("nope", in: [a, b]) else { return XCTFail() }
        XCTAssertTrue(e.message.contains("kanzo"))
        guard case .failure = CommandLookup.find("", in: [a]) else { return XCTFail() }
    }

    func testNameIsTaken() {
        XCTAssertTrue(CommandLookup.nameIsTaken("KANZO", in: [a, b]))
        XCTAssertFalse(CommandLookup.nameIsTaken("KANZO", in: [a, b], excluding: a.id))
    }
}
