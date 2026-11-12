import SwiftUI
import WickbarCore

struct CommandDetailView: View {
    @ObservedObject var process: ManagedProcess
    @EnvironmentObject var manager: ProcessManager
    @EnvironmentObject var ui: UIState

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(12)
            Divider()
            TerminalPane(process: process)
                .id("\(process.id)-\(process.outputGeneration)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(process.config.name)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StatusDot(status: process.status)
                    Text(process.config.name)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                }
                Text(process.config.command)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    HStack(spacing: 14) {
                        Text(process.status.label).foregroundStyle(process.status.color)
                        if let pid = process.pid { Text("pid \(pid)") }
                        if process.status.hasProcess, let s = process.startedAt {
                            Text("up \(Format.duration(ctx.date.timeIntervalSince(s)))")
                        } else if process.lastExitCode != nil || process.lastExitWasSignal {
                            Text(Format.exitText(process))
                        }
                        if process.restartCount > 0 { Text("\(process.restartCount) restart\(process.restartCount == 1 ? "" : "s")") }
                        Text(process.config.workingDirectory.isEmpty ? "~" : process.config.workingDirectory)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }
            Spacer()
            HStack(spacing: 6) {
                if process.status.isActive {
                    Button { manager.stop(process.id) } label: { Label("Stop", systemImage: "stop.fill") }
                } else {
                    Button { manager.start(process.id) } label: { Label("Start", systemImage: "play.fill") }
                        .keyboardShortcut("r", modifiers: [.command])
                }
                Button { manager.restart(process.id) } label: { Label("Restart", systemImage: "arrow.clockwise") }
                    .disabled(process.status == .stopping)
                Button { ui.editorRequest = EditorRequest(config: process.config) } label: { Label("Edit", systemImage: "pencil") }
                Button { process.clearOutput() } label: { Label("Clear", systemImage: "trash") }
                    .help("Clear output")
                    .keyboardShortcut("k", modifiers: [.command])
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.regular)
        }
    }
}
