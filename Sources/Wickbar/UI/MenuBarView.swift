import SwiftUI
import WickbarCore

/// The menu bar icon: flame / flame.fill, or a warning symbol with a count when something crashed.
struct MenuBarLabel: View {
    @ObservedObject var manager: ProcessManager

    var body: some View {
        let _ = manager.statusTick
        if manager.crashedCount > 0 {
            HStack(spacing: 2) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("\(manager.crashedCount)")
            }
            .accessibilityLabel("Wickbar: \(manager.crashedCount) crashed")
        } else {
            Image(systemName: manager.runningCount > 0 ? "flame.fill" : "flame")
                .accessibilityLabel("Wickbar: \(manager.runningCount) running")
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var manager: ProcessManager
    @EnvironmentObject var ui: UIState
    @EnvironmentObject var updater: Updater
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !manager.pendingRestore.isEmpty {
                RestoreBanner()
                    .padding(10)
                Divider()
            }
            if let err = manager.configError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
                Divider()
            }
            if let err = manager.mcpErrorMessage {
                Label("MCP: \(err)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
                Divider()
            }

            if manager.processes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "flame")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No commands yet")
                        .font(.headline)
                    Text("Save a long-running command (dev server, tunnel, agent) and Wickbar keeps it alive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Add command…") { openMain(add: true) }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(manager.processes) { p in
                            MenuCommandRow(process: p) { openMain(select: p.id) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if let version = updater.pendingUpdateVersion {
                    MenuButton(title: "Update available: \(version)", systemImage: "arrow.down.circle") {
                        updater.checkForUpdates()
                    }
                }
                MenuButton(title: "Open Wickbar", systemImage: "macwindow") { openMain() }
                if !manager.processes.isEmpty {
                    MenuButton(title: "Add command…", systemImage: "plus") { openMain(add: true) }
                    MenuButton(title: "Start all", systemImage: "play.fill") { manager.startAllCommands() }
                    MenuButton(title: "Stop all", systemImage: "stop.fill") {
                        Task { await manager.stopAllCommands() }
                    }
                }
                MenuButton(title: "Settings…", systemImage: "gearshape") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                if updater.isAvailable {
                    MenuButton(title: "Check for Updates…", systemImage: "arrow.triangle.2.circlepath") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
                Divider().padding(.vertical, 4)
                MenuButton(title: "Quit Wickbar", systemImage: "power") { AppDelegate.quit() }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 320)
    }

    private func openMain(select: UUID? = nil, add: Bool = false) {
        if let select { ui.selection = select }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        if add {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                ui.editorRequest = EditorRequest(config: nil)
            }
        }
    }
}

struct RestoreBanner: View {
    @EnvironmentObject var manager: ProcessManager

    var body: some View {
        let n = manager.pendingRestore.count
        VStack(alignment: .leading, spacing: 6) {
            Label("Restore \(n) command\(n == 1 ? "" : "s") that \(n == 1 ? "was" : "were") running before Wickbar stopped unexpectedly?",
                  systemImage: "arrow.counterclockwise.circle.fill")
                .font(.callout)
            Text(manager.pendingRestore.compactMap { manager.process($0)?.config.name }.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Restore") { manager.restorePending() }
                    .buttonStyle(.borderedProminent)
                Button("Dismiss") { manager.dismissRestore() }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
    }
}

private struct MenuCommandRow: View {
    @ObservedObject var process: ManagedProcess
    @EnvironmentObject var manager: ProcessManager
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: process.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(process.config.name)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Format.summary(process, now: ctx.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 4)
            if process.status.isActive {
                IconButton(systemImage: "arrow.clockwise", help: "Restart") { manager.restart(process.id) }
                IconButton(systemImage: "stop.fill", help: "Stop") { manager.stop(process.id) }
            } else {
                IconButton(systemImage: "play.fill", help: "Start") { manager.start(process.id) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .help("Click to show output")
        .contextMenu {
            Button("Show Output") { open() }
        }
    }
}

struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

private struct MenuButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let highlighted = hovering && isEnabled
        Button(action: action) {
            HStack {
                Image(systemName: systemImage)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(highlighted ? Color.accentColor.opacity(0.85) : .clear))
            .foregroundStyle(highlighted ? Color.white : isEnabled ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .onHover { hovering = $0 }
    }
}
