import AppKit
import SwiftUI
import WickbarCore

/// Add / edit sheet.
struct CommandEditor: View {
    let original: CommandConfig?
    let onSave: (CommandConfig) -> Void

    @EnvironmentObject var manager: ProcessManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var command = ""
    @State private var workingDirectory = "~"
    @State private var environmentText = ""
    @State private var autoStart = false
    @State private var restartPolicy: RestartPolicy = .onFailure
    @State private var loaded = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedCommand: String { command.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameTaken: Bool {
        CommandLookup.nameIsTaken(trimmedName, in: manager.commandConfigs, excluding: original?.id)
    }
    private var validationMessage: String? {
        if trimmedName.isEmpty { return "Name is required." }
        if nameTaken { return "Another command already uses this name." }
        if trimmedCommand.isEmpty { return "Command is required." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original == nil ? "Add Command" : "Edit Command")
                .font(.title2.weight(.semibold))

            Form {
                TextField("Name", text: $name, prompt: Text("api server"))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Command")
                    TextEditor(text: $command)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 70, maxHeight: 140)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    Text("Runs as `$SHELL -c \"…\"` with your login-shell environment, inside a terminal (PTY).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    TextField("Working directory", text: $workingDirectory, prompt: Text("~"))
                    Button("Choose…", action: chooseFolder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Environment")
                    TextEditor(text: $environmentText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 50, maxHeight: 110)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    Text("One KEY=VALUE per line.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Start automatically when Wickbar launches", isOn: $autoStart)

                Picker("Restart", selection: $restartPolicy) {
                    Text("Never").tag(RestartPolicy.never)
                    Text("On failure (non-zero exit or signal)").tag(RestartPolicy.onFailure)
                    Text("Always (any exit you didn't request)").tag(RestartPolicy.always)
                }
            }
            .formStyle(.columns)

            HStack {
                if let msg = validationMessage, loaded, !(trimmedName.isEmpty && trimmedCommand.isEmpty) {
                    Label(msg, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(original == nil ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationMessage != nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let c = original else { return }
        name = c.name
        command = c.command
        workingDirectory = c.workingDirectory
        environmentText = EnvironmentText.format(c.environment)
        autoStart = c.autoStart
        restartPolicy = c.restartPolicy
    }

    private func save() {
        guard validationMessage == nil else { return }
        var c = original ?? CommandConfig(name: trimmedName, command: trimmedCommand)
        c.name = trimmedName
        c.command = trimmedCommand
        let wd = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        c.workingDirectory = wd.isEmpty ? "~" : wd
        c.environment = EnvironmentText.parse(environmentText)
        c.autoStart = autoStart
        c.restartPolicy = restartPolicy
        onSave(c)
        dismiss()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: CommandConfig.expandTilde(workingDirectory))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = NSHomeDirectory()
        let path = url.path
        workingDirectory = path == home ? "~" : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
    }
}
