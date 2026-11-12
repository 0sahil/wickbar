import Foundation

public struct ToolCallResult: Equatable, Sendable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public var jsonValue: JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }
}

/// Raised for an unknown tool name (a protocol error, not a tool error).
public struct UnknownToolError: Error {
    public let name: String
}

/// MCP tool definitions and their implementation against a `WickbarController`.
@MainActor
public enum MCPTools {
    public static let defaultLogLines = 200
    public static let maxLogLines = 5000

    // MARK: Definitions

    private static let commandRef: JSONValue = [
        "type": "string",
        "description": "The command's id (UUID) or its name (exact or case-insensitive).",
    ]
    private static let restartPolicySchema: JSONValue = [
        "type": "string", "enum": ["never", "onFailure", "always"],
        "description": "never | onFailure (restart on non-zero exit or signal) | always (restart on any exit not requested by the user).",
    ]
    private static let envSchema: JSONValue = [
        "type": "object", "additionalProperties": ["type": "string"],
        "description": "Extra environment variables (KEY: VALUE) layered over the user's login-shell environment.",
    ]

    private static func schema(_ props: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(props), "required": .array(required.map { .string($0) }),
         "additionalProperties": false]
    }

    private static func tool(_ name: String, _ description: String, _ inputSchema: JSONValue) -> JSONValue {
        ["name": .string(name), "description": .string(description), "inputSchema": inputSchema]
    }

    public static var definitions: [JSONValue] {
        let ref = ["command": commandRef]
        return [
            tool("list_commands", "List all saved commands with their config and live status (status, pid, uptime, last exit code, restart count).",
                 schema([:])),
            tool("get_command", "Get one command's config and live status.", schema(ref, required: ["command"])),
            tool("add_command", "Save a new long-running command (runs as `$SHELL -c <command>` in a PTY); optionally start it now.",
                 schema([
                    "name": ["type": "string", "description": "Unique display name, e.g. \"api server\"."],
                    "command": ["type": "string", "description": "Shell command line to run, e.g. \"npm run dev\"."],
                    "working_directory": ["type": "string", "description": "Working directory; supports ~. Default: home."],
                    "environment": envSchema,
                    "auto_start": ["type": "boolean", "description": "Start automatically when Wickbar launches. Default false."],
                    "restart_policy": restartPolicySchema,
                    "start_now": ["type": "boolean", "description": "Start the command immediately. Default false."],
                 ], required: ["name", "command"])),
            tool("update_command", "Change a saved command; restarts it if it is running and its command line, directory or environment changed.",
                 schema([
                    "command": commandRef,
                    "name": ["type": "string", "description": "New display name."],
                    "command_line": ["type": "string", "description": "New shell command line."],
                    "working_directory": ["type": "string", "description": "New working directory; supports ~."],
                    "environment": envSchema,
                    "auto_start": ["type": "boolean", "description": "Start automatically when Wickbar launches."],
                    "restart_policy": restartPolicySchema,
                 ], required: ["command"])),
            tool("remove_command", "Stop (if running) and delete a saved command.", schema(ref, required: ["command"])),
            tool("start_command", "Start a stopped or crashed command.", schema(ref, required: ["command"])),
            tool("stop_command", "Stop a command gracefully (SIGTERM to its process tree, SIGKILL after 5s).", schema(ref, required: ["command"])),
            tool("restart_command", "Stop (if running) and start a command again.", schema(ref, required: ["command"])),
            tool("start_all", "Start every command that is not already running.", schema([:])),
            tool("stop_all", "Stop every running command.", schema([:])),
            tool("get_logs", "Get a command's recent terminal output as plain text (ANSI escapes stripped).",
                 schema([
                    "command": commandRef,
                    "lines": ["type": "integer", "minimum": 1, "maximum": .int(maxLogLines),
                              "description": .string("Number of trailing lines to return (default \(defaultLogLines), max \(maxLogLines)).")],
                 ], required: ["command"])),
            tool("send_input", "Type text into a running command's terminal (e.g. answer a prompt).",
                 schema([
                    "command": commandRef,
                    "text": ["type": "string", "description": "Text to send."],
                    "press_enter": ["type": "boolean", "description": "Press Enter after the text. Default true."],
                 ], required: ["command", "text"])),
            tool("get_settings", "Get Wickbar's settings (auto-start, launch at login, crash restore, MCP port, config path).", schema([:])),
            tool("update_settings", "Change Wickbar's settings.",
                 schema([
                    "auto_start_on_launch": ["type": "boolean", "description": "Start auto-start commands when Wickbar launches."],
                    "launch_at_login": ["type": "boolean", "description": "Launch Wickbar when you log in."],
                    "restore_after_crash": ["type": "string", "enum": ["ask", "always", "never"],
                                            "description": "Whether to restore commands that were running if Wickbar quit unexpectedly."],
                 ])),
        ]
    }

    public static var toolNames: [String] { definitions.compactMap { $0["name"]?.stringValue } }

    // MARK: Call

    public static func call(name: String, arguments: [String: JSONValue], controller: WickbarController) async throws -> ToolCallResult {
        guard toolNames.contains(name) else { throw UnknownToolError(name: name) }
        do {
            return try await run(name: name, args: Args(arguments), controller: controller)
        } catch let e as WickbarError {
            return ToolCallResult(text: e.message, isError: true)
        } catch {
            return ToolCallResult(text: error.localizedDescription, isError: true)
        }
    }

    private struct Args {
        let raw: [String: JSONValue]
        init(_ raw: [String: JSONValue]) { self.raw = raw }

        func has(_ key: String) -> Bool {
            guard let v = raw[key] else { return false }
            return !v.isNull
        }

        func string(_ key: String) throws -> String? {
            guard let v = raw[key], !v.isNull else { return nil }
            guard let s = v.stringValue else { throw WickbarError("`\(key)` must be a string.") }
            return s
        }

        func requiredString(_ key: String) throws -> String {
            guard let s = try string(key) else { throw WickbarError("Missing required argument `\(key)`.") }
            return s
        }

        func bool(_ key: String) throws -> Bool? {
            guard let v = raw[key], !v.isNull else { return nil }
            if let b = v.boolValue { return b }
            if let s = v.stringValue?.lowercased(), s == "true" || s == "false" { return s == "true" }
            throw WickbarError("`\(key)` must be a boolean.")
        }

        func int(_ key: String) throws -> Int? {
            guard let v = raw[key], !v.isNull else { return nil }
            guard let i = v.intValue else { throw WickbarError("`\(key)` must be an integer.") }
            return i
        }

        func environment(_ key: String) throws -> [String: String]? {
            guard let v = raw[key], !v.isNull else { return nil }
            guard let o = v.objectValue else { throw WickbarError("`\(key)` must be an object of string values.") }
            var env: [String: String] = [:]
            for (k, val) in o {
                switch val {
                case .string(let s): env[k] = s
                case .int(let i): env[k] = String(i)
                case .double(let d): env[k] = String(d)
                case .bool(let b): env[k] = String(b)
                default: throw WickbarError("Environment value for `\(k)` must be a string.")
                }
            }
            return env
        }

        func restartPolicy(_ key: String) throws -> RestartPolicy? {
            guard let s = try string(key) else { return nil }
            guard let p = RestartPolicy(rawValue: s) else {
                throw WickbarError("`\(key)` must be one of: never, onFailure, always.")
            }
            return p
        }
    }

    private static func lookup(_ args: Args, _ controller: WickbarController) throws -> CommandConfig {
        let ref = try args.requiredString("command")
        switch CommandLookup.find(ref, in: controller.commandConfigs) {
        case .success(let c): return c
        case .failure(let e): throw e
        }
    }

    private static func json(_ value: JSONValue) -> ToolCallResult {
        ToolCallResult(text: value.encodedString(pretty: true))
    }

    private static func run(name: String, args: Args, controller: WickbarController) async throws -> ToolCallResult {
        switch name {
        case "list_commands":
            let list = controller.commandConfigs.map { describe($0, controller.runtimeInfo(for: $0.id)) }
            return json(["commands": .array(list)])

        case "get_command":
            let c = try lookup(args, controller)
            return json(describe(c, controller.runtimeInfo(for: c.id)))

        case "add_command":
            let name = try args.requiredString("name").trimmingCharacters(in: .whitespacesAndNewlines)
            let line = try args.requiredString("command").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw WickbarError("`name` must not be empty.") }
            guard !line.isEmpty else { throw WickbarError("`command` must not be empty.") }
            if CommandLookup.nameIsTaken(name, in: controller.commandConfigs) {
                throw WickbarError("A command named '\(name)' already exists. Use update_command to change it.")
            }
            let config = CommandConfig(
                name: name, command: line,
                workingDirectory: try args.string("working_directory") ?? "~",
                environment: try args.environment("environment") ?? [:],
                autoStart: try args.bool("auto_start") ?? false,
                restartPolicy: try args.restartPolicy("restart_policy") ?? .onFailure)
            let startNow = try args.bool("start_now") ?? false
            try controller.addCommand(config)
            var note = "Added '\(name)'."
            if startNow {
                try controller.startCommand(id: config.id)
                note += " Started."
            }
            return json(["message": .string(note), "command": describe(config, controller.runtimeInfo(for: config.id))])

        case "update_command":
            let old = try lookup(args, controller)
            var new = old
            if let n = try args.string("name") {
                let n = n.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !n.isEmpty else { throw WickbarError("`name` must not be empty.") }
                if CommandLookup.nameIsTaken(n, in: controller.commandConfigs, excluding: old.id) {
                    throw WickbarError("Another command is already named '\(n)'.")
                }
                new.name = n
            }
            if let l = try args.string("command_line") {
                let l = l.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !l.isEmpty else { throw WickbarError("`command_line` must not be empty.") }
                new.command = l
            }
            if let wd = try args.string("working_directory") { new.workingDirectory = wd }
            if let env = try args.environment("environment") { new.environment = env }
            if let a = try args.bool("auto_start") { new.autoStart = a }
            if let p = try args.restartPolicy("restart_policy") { new.restartPolicy = p }
            if new == old {
                return json(["message": "Nothing changed.", "command": describe(new, controller.runtimeInfo(for: new.id))])
            }
            let restarted = try await controller.updateCommand(new)
            let msg = restarted
                ? "Updated '\(new.name)' and restarted it because its command line, directory or environment changed."
                : "Updated '\(new.name)'."
            return json(["message": .string(msg), "restarted": .bool(restarted),
                         "command": describe(new, controller.runtimeInfo(for: new.id))])

        case "remove_command":
            let c = try lookup(args, controller)
            try await controller.removeCommand(id: c.id)
            return json(["message": .string("Removed '\(c.name)'.")])

        case "start_command":
            let c = try lookup(args, controller)
            let info = controller.runtimeInfo(for: c.id)
            if info.status.hasProcess {
                return json(["message": .string("'\(c.name)' is already \(info.status.rawValue)."), "command": describe(c, info)])
            }
            try controller.startCommand(id: c.id)
            return json(["message": .string("Started '\(c.name)'."), "command": describe(c, controller.runtimeInfo(for: c.id))])

        case "stop_command":
            let c = try lookup(args, controller)
            let info = controller.runtimeInfo(for: c.id)
            if !info.status.isActive {
                return json(["message": .string("'\(c.name)' is not running."), "command": describe(c, info)])
            }
            await controller.stopCommand(id: c.id)
            return json(["message": .string("Stopped '\(c.name)'."), "command": describe(c, controller.runtimeInfo(for: c.id))])

        case "restart_command":
            let c = try lookup(args, controller)
            try await controller.restartCommand(id: c.id)
            return json(["message": .string("Restarted '\(c.name)'."), "command": describe(c, controller.runtimeInfo(for: c.id))])

        case "start_all":
            controller.startAll()
            let list = controller.commandConfigs.map { describe($0, controller.runtimeInfo(for: $0.id)) }
            return json(["message": "Started all commands.", "commands": .array(list)])

        case "stop_all":
            await controller.stopAll()
            let list = controller.commandConfigs.map { describe($0, controller.runtimeInfo(for: $0.id)) }
            return json(["message": "Stopped all commands.", "commands": .array(list)])

        case "get_logs":
            let c = try lookup(args, controller)
            let lines = min(max(try args.int("lines") ?? defaultLogLines, 1), maxLogLines)
            let text = controller.logs(for: c.id, lines: lines)
            return ToolCallResult(text: text.isEmpty ? "(no output yet)" : text)

        case "send_input":
            let c = try lookup(args, controller)
            let text = try args.requiredString("text")
            let enter = try args.bool("press_enter") ?? true
            guard controller.runtimeInfo(for: c.id).status.hasProcess else {
                throw WickbarError("'\(c.name)' is not running.")
            }
            try controller.sendInput(to: c.id, text: enter ? text + "\r" : text)
            return ToolCallResult(text: "Sent \(text.count) characters\(enter ? " + Enter" : "") to '\(c.name)'.")

        case "get_settings":
            return json(settingsJSON(controller))

        case "update_settings":
            var restore: RestoreAfterCrash?
            if let r = try args.string("restore_after_crash") {
                guard let v = RestoreAfterCrash(rawValue: r) else {
                    throw WickbarError("`restore_after_crash` must be one of: ask, always, never.")
                }
                restore = v
            }
            let auto = try args.bool("auto_start_on_launch")
            let login = try args.bool("launch_at_login")
            if auto != nil || restore != nil {
                try controller.updateSettings(autoStartOnLaunch: auto, restoreAfterCrash: restore)
            }
            if let login {
                try controller.setLaunchAtLogin(login)
            }
            return json(settingsJSON(controller))

        default:
            throw UnknownToolError(name: name)
        }
    }

    // MARK: Serialization

    public static func describe(_ c: CommandConfig, _ info: CommandRuntimeInfo, now: Date = Date()) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(c.id.uuidString),
            "name": .string(c.name),
            "command": .string(c.command),
            "working_directory": .string(c.workingDirectory),
            "environment": .object(c.environment.mapValues { .string($0) }),
            "auto_start": .bool(c.autoStart),
            "restart_policy": .string(c.restartPolicy.rawValue),
            "status": .string(info.status.rawValue),
            "restart_count": .int(info.restartCount),
            "pid": info.pid.map { .int(Int($0)) } ?? .null,
            "last_exit_code": info.lastExitCode.map { .int(Int($0)) } ?? .null,
            "last_exit_was_signal": .bool(info.lastExitWasSignal),
        ]
        if let started = info.startedAt, info.status.hasProcess {
            o["uptime_seconds"] = .int(max(0, Int(now.timeIntervalSince(started))))
            o["started_at"] = .string(ISO8601DateFormatter().string(from: started))
        } else {
            o["uptime_seconds"] = .null
        }
        return .object(o)
    }

    private static func settingsJSON(_ controller: WickbarController) -> JSONValue {
        let s = controller.appSettings
        let login = controller.launchAtLogin
        return [
            "auto_start_on_launch": .bool(s.autoStartOnLaunch),
            "launch_at_login": .bool(login.enabled),
            "launch_at_login_status": .string(login.status),
            "restore_after_crash": .string(s.restoreAfterCrash.rawValue),
            "mcp_enabled": .bool(s.mcpEnabled),
            "mcp_port": .int(s.mcpPort),
            "config_path": .string(controller.configPath),
        ]
    }
}
