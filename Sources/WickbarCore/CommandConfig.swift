import Foundation

public enum RestartPolicy: String, Codable, CaseIterable, Sendable {
    case never
    case onFailure
    case always

    public var displayName: String {
        switch self {
        case .never: return "Never"
        case .onFailure: return "On failure"
        case .always: return "Always"
        }
    }
}

/// A saved command. Decoding is lenient so hand-edited files with missing keys still load.
public struct CommandConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var command: String
    public var workingDirectory: String
    public var environment: [String: String]
    public var autoStart: Bool
    public var restartPolicy: RestartPolicy

    public init(id: UUID = UUID(), name: String, command: String, workingDirectory: String = "~",
                environment: [String: String] = [:], autoStart: Bool = false,
                restartPolicy: RestartPolicy = .onFailure) {
        self.id = id
        self.name = name
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.autoStart = autoStart
        self.restartPolicy = restartPolicy
    }

    enum CodingKeys: String, CodingKey {
        case id, name, command, workingDirectory, environment, autoStart, restartPolicy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        command = try c.decode(String.self, forKey: .command)
        name = (try? c.decode(String.self, forKey: .name)) ?? command
        workingDirectory = (try? c.decode(String.self, forKey: .workingDirectory)) ?? "~"
        environment = (try? c.decode([String: String].self, forKey: .environment)) ?? [:]
        autoStart = (try? c.decode(Bool.self, forKey: .autoStart)) ?? false
        restartPolicy = (try? c.decode(RestartPolicy.self, forKey: .restartPolicy)) ?? .onFailure
    }

    /// True if fields that affect the running process differ (command line, cwd, env).
    public func runtimeDiffers(from other: CommandConfig) -> Bool {
        command != other.command || workingDirectory != other.workingDirectory || environment != other.environment
    }

    /// `workingDirectory` with `~` expanded; empty means the home directory.
    public func resolvedWorkingDirectory(home: String = NSHomeDirectory()) -> String {
        Self.expandTilde(workingDirectory, home: home)
    }

    public static func expandTilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return home + String(trimmed.dropFirst(1)) }
        return trimmed
    }
}

/// Parses `KEY=VALUE` lines (blank lines and `#` comments ignored).
public enum EnvironmentText {
    public static func parse(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            var key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("export ") { key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard !key.isEmpty else { continue }
            env[key] = String(line[line.index(after: eq)...])
        }
        return env
    }

    public static func format(_ env: [String: String]) -> String {
        env.keys.sorted().map { "\($0)=\(env[$0]!)" }.joined(separator: "\n")
    }
}
