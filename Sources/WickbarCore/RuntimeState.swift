import Foundation

/// `state.json`: used to detect unclean shutdowns and restore what was running.
public struct RuntimeState: Codable, Equatable, Sendable {
    public var cleanShutdown: Bool
    public var runningIds: [UUID]

    public init(cleanShutdown: Bool = true, runningIds: [UUID] = []) {
        self.cleanShutdown = cleanShutdown
        self.runningIds = runningIds
    }

    enum CodingKeys: String, CodingKey { case cleanShutdown, runningIds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cleanShutdown = (try? c.decode(Bool.self, forKey: .cleanShutdown)) ?? true
        runningIds = (try? c.decode([UUID].self, forKey: .runningIds)) ?? []
    }
}

public final class RuntimeStateStore {
    public let url: URL

    public init(directory: URL = ConfigStore.defaultDirectory) {
        url = directory.appendingPathComponent("state.json")
    }

    public func load() -> RuntimeState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RuntimeState.self, from: data)
    }

    public func save(_ state: RuntimeState) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(state) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
