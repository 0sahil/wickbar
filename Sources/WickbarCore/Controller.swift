import Foundation

public enum CommandStatus: String, Codable, Sendable {
    case stopped, starting, running, stopping, crashed, restarting

    public var isActive: Bool {
        switch self {
        case .starting, .running, .stopping, .restarting: return true
        case .stopped, .crashed: return false
        }
    }

    /// True while there is (or should be) a live process.
    public var hasProcess: Bool { self == .starting || self == .running || self == .stopping }
}

public struct CommandRuntimeInfo: Equatable, Sendable {
    public var status: CommandStatus
    public var pid: Int32?
    public var startedAt: Date?
    public var lastExitCode: Int32?
    public var lastExitWasSignal: Bool
    public var restartCount: Int

    public init(status: CommandStatus = .stopped, pid: Int32? = nil, startedAt: Date? = nil,
                lastExitCode: Int32? = nil, lastExitWasSignal: Bool = false, restartCount: Int = 0) {
        self.status = status
        self.pid = pid
        self.startedAt = startedAt
        self.lastExitCode = lastExitCode
        self.lastExitWasSignal = lastExitWasSignal
        self.restartCount = restartCount
    }
}

public struct LaunchAtLoginInfo: Equatable, Sendable {
    public var enabled: Bool
    public var status: String
    public init(enabled: Bool, status: String) {
        self.enabled = enabled
        self.status = status
    }
}

public struct WickbarError: LocalizedError, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Everything the MCP tools need from the app. Implemented by the app's ProcessManager and by test mocks.
@MainActor
public protocol WickbarController: AnyObject {
    var commandConfigs: [CommandConfig] { get }
    func runtimeInfo(for id: UUID) -> CommandRuntimeInfo
    func addCommand(_ config: CommandConfig) throws
    /// Saves the new definition. Returns true if the command was running and got restarted.
    func updateCommand(_ config: CommandConfig) async throws -> Bool
    func removeCommand(id: UUID) async throws
    func startCommand(id: UUID) throws
    func stopCommand(id: UUID) async
    func restartCommand(id: UUID) async throws
    func startAll()
    func stopAll() async
    func logs(for id: UUID, lines: Int) -> String
    func sendInput(to id: UUID, text: String) throws

    var appSettings: AppSettings { get }
    var launchAtLogin: LaunchAtLoginInfo { get }
    func updateSettings(autoStartOnLaunch: Bool?, restoreAfterCrash: RestoreAfterCrash?) throws
    func setLaunchAtLogin(_ enabled: Bool) throws
    var configPath: String { get }
}

public enum CommandLookup {
    /// Finds a command by id (UUID string), exact name, or case-insensitive name.
    public static func find(_ reference: String, in commands: [CommandConfig]) -> Result<CommandConfig, WickbarError> {
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else { return .failure(WickbarError("Missing `command` (an id or name).")) }
        if let uuid = UUID(uuidString: ref), let match = commands.first(where: { $0.id == uuid }) {
            return .success(match)
        }
        if let exact = commands.first(where: { $0.name == ref }) {
            return .success(exact)
        }
        let ci = commands.filter { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
        if ci.count == 1 { return .success(ci[0]) }
        if ci.count > 1 {
            return .failure(WickbarError("'\(ref)' matches \(ci.count) commands; use the id instead: "
                + ci.map { $0.id.uuidString }.joined(separator: ", ")))
        }
        let names = commands.map { $0.name }
        let known = names.isEmpty ? "No commands are configured." : "Known commands: " + names.joined(separator: ", ")
        return .failure(WickbarError("No command named or with id '\(ref)'. \(known)"))
    }

    public static func nameIsTaken(_ name: String, in commands: [CommandConfig], excluding id: UUID? = nil) -> Bool {
        commands.contains { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
