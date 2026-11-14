import AppKit
import SwiftUI
import WickbarCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            MCPSettings()
                .tabItem { Label("MCP", systemImage: "point.3.connected.trianglepath.dotted") }
        }
        .frame(width: 560)
        .onAppear { WindowActivation.opened() }
        .onDisappear { WindowActivation.closed() }
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var manager: ProcessManager
    @EnvironmentObject var updater: Updater

    var body: some View {
        Form {
            Section {
                Toggle("Launch Wickbar at login", isOn: Binding(
                    get: { manager.launchAtLoginInfo.enabled },
                    set: { manager.setLaunchAtLoginFromUI($0) }))
                HStack {
                    Text("Status: \(manager.launchAtLoginInfo.status)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if manager.launchAtLoginInfo.status.contains("approval") {
                        Button("Open Login Items…") { LoginItem.openSystemSettings() }
                            .controlSize(.small)
                    }
                }
                if let err = manager.launchAtLoginError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Toggle("Auto-start commands when Wickbar launches", isOn: Binding(
                    get: { manager.settings.autoStartOnLaunch },
                    set: { manager.setAutoStartOnLaunch($0) }))
                Picker("Restore after crash", selection: Binding(
                    get: { manager.settings.restoreAfterCrash },
                    set: { manager.setRestoreAfterCrash($0) })) {
                    ForEach(RestoreAfterCrash.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("If Wickbar quits unexpectedly, restore the commands that were running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }))
                    .disabled(!updater.isAvailable)
                Text(updater.isAvailable
                     ? "Wickbar \(updater.currentVersion)"
                     : "Updates are only available when Wickbar runs from an .app bundle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Reload shell environment") { manager.reloadShellEnvironment() }
                        .disabled(manager.capturingEnvironment)
                    if manager.capturingEnvironment { ProgressView().controlSize(.small) }
                }
                if let snap = manager.shellSnapshot {
                    Text(snap.capturedFromShell
                         ? "Captured from \(snap.shell) at \(snap.capturedAt.formatted(date: .omitted, time: .standard)) (\(snap.environment.count) variables)."
                         : "Using fallback environment: \(snap.note ?? "")")
                        .font(.caption)
                        .foregroundStyle(snap.capturedFromShell ? Color.secondary : Color.orange)
                    Text("PATH: \(snap.environment["PATH"] ?? "")")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Text("Commands run with your login shell's environment. Reload after changing your shell profile; running commands keep their old environment until restarted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text(manager.configPath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: manager.configPath)])
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("Config file")
            }
        }
        .formStyle(.grouped)
        .onAppear { manager.refreshLaunchAtLogin() }
    }
}

private struct MCPSettings: View {
    @EnvironmentObject var manager: ProcessManager
    @State private var portText = ""

    var body: some View {
        Form {
            Section {
                Toggle("Enable MCP server", isOn: Binding(
                    get: { manager.settings.mcpEnabled },
                    set: { manager.setMCPEnabled($0) }))
                HStack {
                    TextField("Port", text: $portText)
                        .frame(width: 160)
                        .onSubmit(applyPort)
                    Button("Apply", action: applyPort)
                        .disabled(Int(portText) == manager.settings.mcpPort || Int(portText).map { !(1...65535).contains($0) } ?? true)
                }
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText).font(.callout)
                }
                CopyRow(label: "Endpoint", text: manager.mcpEndpoint)
            } footer: {
                Text("Listens on 127.0.0.1 only. Requests from non-localhost browser origins are rejected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Claude Code") {
                CopyRow(label: nil, text: "claude mcp add --transport http wickbar \(manager.mcpEndpoint)")
            }
            Section("Hermes (config.yaml)") {
                CopyRow(label: nil, text: """
                mcp_servers:
                  wickbar:
                    url: \(manager.mcpEndpoint)
                """)
            }
            Section("Generic JSON (mcpServers)") {
                CopyRow(label: nil, text: """
                {
                  "mcpServers": {
                    "wickbar": {
                      "type": "http",
                      "url": "\(manager.mcpEndpoint)"
                    }
                  }
                }
                """)
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(manager.settings.mcpPort) }
        .onChange(of: manager.settings.mcpPort) { _, new in portText = String(new) }
    }

    private func applyPort() {
        guard let p = Int(portText.trimmingCharacters(in: .whitespaces)), (1...65535).contains(p) else { return }
        manager.setMCPPort(p)
    }

    private var statusText: String {
        switch manager.mcpState {
        case .stopped: return manager.settings.mcpEnabled ? "Stopped" : "Disabled"
        case .starting: return "Starting…"
        case .listening(let port): return "Listening on 127.0.0.1:\(port)"
        case .failed(let msg): return "Error: \(msg)"
        }
    }

    private var statusColor: Color {
        switch manager.mcpState {
        case .listening: return .green
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .gray
        }
    }
}

private struct CopyRow: View {
    let label: String?
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            if let label { Text(label).foregroundStyle(.secondary) }
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            .controlSize(.small)
        }
    }
}
