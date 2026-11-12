import Foundation

public enum RestoreAfterCrash: String, Codable, CaseIterable, Sendable {
    case ask
    case always
    case never

    public var displayName: String {
        switch self {
        case .ask: return "Ask"
        case .always: return "Always"
        case .never: return "Never"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let defaultPort = 9425

    public var autoStartOnLaunch: Bool
    public var mcpEnabled: Bool
    public var mcpPort: Int
    public var restoreAfterCrash: RestoreAfterCrash

    public init(autoStartOnLaunch: Bool = true, mcpEnabled: Bool = true, mcpPort: Int = AppSettings.defaultPort,
                restoreAfterCrash: RestoreAfterCrash = .ask) {
        self.autoStartOnLaunch = autoStartOnLaunch
        self.mcpEnabled = mcpEnabled
        self.mcpPort = mcpPort
        self.restoreAfterCrash = restoreAfterCrash
    }

    enum CodingKeys: String, CodingKey {
        case autoStartOnLaunch, mcpEnabled, mcpPort, restoreAfterCrash
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        autoStartOnLaunch = (try? c.decode(Bool.self, forKey: .autoStartOnLaunch)) ?? d.autoStartOnLaunch
        mcpEnabled = (try? c.decode(Bool.self, forKey: .mcpEnabled)) ?? d.mcpEnabled
        let port = (try? c.decode(Int.self, forKey: .mcpPort)) ?? d.mcpPort
        mcpPort = (1...65535).contains(port) ? port : d.mcpPort
        restoreAfterCrash = (try? c.decode(RestoreAfterCrash.self, forKey: .restoreAfterCrash)) ?? d.restoreAfterCrash
    }
}
