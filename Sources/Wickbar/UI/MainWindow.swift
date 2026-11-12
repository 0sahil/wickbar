import SwiftUI
import WickbarCore

struct MainWindow: View {
    @EnvironmentObject var manager: ProcessManager
    @EnvironmentObject var ui: UIState

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if !manager.pendingRestore.isEmpty {
                    RestoreBanner().padding(10)
                }
                if let err = manager.configError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                if let id = ui.selection, let p = manager.process(id) {
                    CommandDetailView(process: p)
                        .id(p.id)
                } else {
                    EmptyDetail()
                }
            }
        }
        .sheet(item: $ui.editorRequest) { req in
            CommandEditor(original: req.config) { saved in
                manager.save(saved)
                ui.selection = saved.id
            }
            .environmentObject(manager)
        }
        .onAppear {
            WindowActivation.opened()
            if ui.selection == nil { ui.selection = manager.processes.first?.id }
        }
        .onDisappear { WindowActivation.closed() }
        .frame(minWidth: 720, minHeight: 420)
    }
}

private struct EmptyDetail: View {
    @EnvironmentObject var manager: ProcessManager
    @EnvironmentObject var ui: UIState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "flame")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(manager.processes.isEmpty ? "No commands yet" : "Select a command")
                .font(.title2)
            if manager.processes.isEmpty {
                Text("Add a long-running command like `npm run dev` or `tailscale serve 3000`.")
                    .foregroundStyle(.secondary)
                Button("Add command…") { ui.editorRequest = EditorRequest(config: nil) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Sidebar: View {
    @EnvironmentObject var manager: ProcessManager
    @EnvironmentObject var ui: UIState
    @State private var pendingDelete: ManagedProcess?

    var body: some View {
        List(selection: $ui.selection) {
            ForEach(manager.processes) { p in
                SidebarRow(process: p)
                    .tag(p.id)
                    .contextMenu { contextMenu(for: p) }
            }
            .onMove { manager.move(from: $0, to: $1) }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button {
                    ui.editorRequest = EditorRequest(config: nil)
                } label: {
                    Label("Add command", systemImage: "plus")
                }
                .help("Add command")
            }
        }
        .confirmationDialog("Delete “\(pendingDelete?.config.name ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let p = pendingDelete {
                    if ui.selection == p.id { ui.selection = nil }
                    manager.delete(p.id)
                }
                pendingDelete = nil
            }
        } message: {
            Text("The command is stopped and removed from Wickbar.")
        }
    }

    @ViewBuilder
    private func contextMenu(for p: ManagedProcess) -> some View {
        if p.status.isActive {
            Button("Stop") { manager.stop(p.id) }
            Button("Restart") { manager.restart(p.id) }
        } else {
            Button("Start") { manager.start(p.id) }
        }
        Divider()
        Button("Edit…") { ui.editorRequest = EditorRequest(config: p.config) }
        Button("Duplicate") {
            if let id = manager.duplicate(p.id) { ui.selection = id }
        }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = p }
    }
}

private struct SidebarRow: View {
    @ObservedObject var process: ManagedProcess

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: process.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(process.config.name).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Format.summary(process, now: ctx.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 2)
    }
}
