import Foundation
import ServiceManagement
import WickbarCore

/// Launch-at-login via SMAppService.mainApp. The service status is the source of truth (not config.json).
enum LoginItem {
    static var service: SMAppService { SMAppService.mainApp }

    static var info: LaunchAtLoginInfo {
        let s = service.status
        return LaunchAtLoginInfo(enabled: s == .enabled || s == .requiresApproval, status: describe(s))
    }

    static func describe(_ s: SMAppService.Status) -> String {
        switch s {
        case .enabled: return "enabled"
        case .notRegistered: return "disabled"
        case .requiresApproval: return "requires approval in System Settings › General › Login Items"
        case .notFound: return "unavailable (run Wickbar from an installed .app bundle)"
        @unknown default: return "unknown"
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled || service.status == .requiresApproval { try service.unregister() }
            }
        } catch {
            throw WickbarError("Could not \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)"
                + (Bundle.main.bundleURL.pathExtension == "app" ? "" : " (Wickbar must run from an .app bundle)"))
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
