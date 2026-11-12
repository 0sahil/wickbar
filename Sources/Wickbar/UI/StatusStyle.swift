import SwiftUI
import WickbarCore

extension CommandStatus {
    var color: Color {
        switch self {
        case .running: return .green
        case .starting, .restarting, .stopping: return .yellow
        case .crashed: return .red
        case .stopped: return .gray
        }
    }

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running: return "Running"
        case .stopping: return "Stopping"
        case .crashed: return "Crashed"
        case .restarting: return "Restarting"
        }
    }
}

struct StatusDot: View {
    let status: CommandStatus
    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 8, height: 8)
            .help(status.label)
    }
}

enum Format {
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86400)d \((s % 86400) / 3600)h"
    }

    /// "up 3m 2s", "exited 1", "stopped", ...
    @MainActor
    static func summary(_ p: ManagedProcess, now: Date) -> String {
        switch p.status {
        case .running, .starting:
            if let start = p.startedAt { return "up \(duration(now.timeIntervalSince(start)))" }
            return p.status.label.lowercased()
        case .stopping: return "stopping…"
        case .restarting: return "restarting…"
        case .crashed:
            if p.gaveUp { return "gave up" }
            return exitText(p)
        case .stopped:
            if !p.stoppedByUser && (p.lastExitCode != nil || p.lastExitWasSignal) { return exitText(p) }
            return "stopped"
        }
    }

    @MainActor
    static func exitText(_ p: ManagedProcess) -> String {
        if let code = p.lastExitCode { return "exited \(code)" }
        if p.lastExitWasSignal { return "killed" }
        return "stopped"
    }
}
