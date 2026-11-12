import Foundation

/// The on-disk config document (`config.json`).
public struct ConfigFile: Codable, Equatable, Sendable {
    public var settings: AppSettings
    public var commands: [CommandConfig]

    public init(settings: AppSettings = AppSettings(), commands: [CommandConfig] = []) {
        self.settings = settings
        self.commands = commands
    }

    enum CodingKeys: String, CodingKey { case settings, commands }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = (try c.decodeIfPresent(AppSettings.self, forKey: .settings)) ?? AppSettings()
        commands = (try c.decodeIfPresent([CommandConfig].self, forKey: .commands)) ?? []
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try enc.encode(self)
        data.append(0x0A)
        return data
    }

    public static func decode(_ data: Data) throws -> ConfigFile {
        try JSONDecoder().decode(ConfigFile.self, from: data)
    }
}

/// Reads and writes `config.json` (atomically, pretty-printed, sorted keys).
public final class ConfigStore {
    public let directory: URL
    public var configURL: URL { directory.appendingPathComponent("config.json") }

    /// `~/Library/Application Support/Wickbar`, or `$WICKBAR_CONFIG_DIR` when set (for development,
    /// demos and running a second copy side by side without touching your real config).
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["WICKBAR_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Wickbar", isDirectory: true)
    }

    public init(directory: URL = ConfigStore.defaultDirectory) {
        self.directory = directory
    }

    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Loads the config, creating an empty one if the file is missing.
    public func loadOrCreate() throws -> ConfigFile {
        try ensureDirectory()
        if !FileManager.default.fileExists(atPath: configURL.path) {
            let empty = ConfigFile()
            try save(empty)
            return empty
        }
        return try load()
    }

    public func load() throws -> ConfigFile {
        try ConfigFile.decode(Data(contentsOf: configURL))
    }

    public func rawData() -> Data? {
        try? Data(contentsOf: configURL)
    }

    /// Writes atomically. Returns the bytes written so callers can ignore their own change events.
    @discardableResult
    public func save(_ config: ConfigFile) throws -> Data {
        try ensureDirectory()
        let data = try config.encoded()
        try data.write(to: configURL, options: .atomic)
        return data
    }
}
