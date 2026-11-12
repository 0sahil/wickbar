import AppKit
import Combine
import Foundation
import WickbarCore

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0-dev"
    }
}

/// Owns config, all managed processes, the shell environment, crash recovery and the MCP server.
@MainActor
final class ProcessManager: ObservableObject {
    @Published private(set) var processes: [ManagedProcess] = []
    @Published private(set) var settings = AppSettings()
    @Published private(set) var shellSnapshot: ShellEnvironment.Snapshot?
    @Published private(set) var capturingEnvironment = false
    @Published private(set) var pendingRestore: [UUID] = []
    @Published private(set) var mcpState: HTTPServer.State = .stopped
    @Published private(set) var configError: String?
    @Published private(set) var launchAtLoginInfo = LaunchAtLoginInfo(enabled: false, status: "unknown")
    @Published private(set) var launchAtLoginError: String?
    /// Bumped on every status change so summary views refresh.
    @Published private(set) var statusTick = 0

    let store: ConfigStore
    let stateStore: RuntimeStateStore
    private var lastConfigData: Data?
    private var configLoadFailed = false
    private var watcher: DispatchSourceFileSystemObject?
    private var watchDebounce: DispatchWorkItem?
    private var httpServer: HTTPServer?
    private lazy var mcpServer = MCPServer(controller: self, version: AppInfo.version)
    private var mcpRetryCount = 0
    private var mcpRetryTask: Task<Void, Never>?
    private var bootstrapped = false
    private var lastWrittenRunning: [UUID]?

    init(directory: URL = ConfigStore.defaultDirectory) {
        store = ConfigStore(directory: directory)
        stateStore = RuntimeStateStore(directory: directory)
    }

    // MARK: Startup

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        // 1. Load config; mark state unclean (after reading the previous value).
        loadConfigAtLaunch()
        let previous = stateStore.load()
        stateStore.save(RuntimeState(cleanShutdown: false, runningIds: previous?.runningIds ?? []))
        refreshLaunchAtLogin()
        startWatchingConfig()
        Notifications.requestAuthorization()
        applyMCPSettings()

        // 2. Capture the shell environment, then 3. auto-start and 4. crash recovery.
        reloadShellEnvironment { [weak self] in
            guard let self else { return }
            var started = Set<UUID>()
            if self.settings.autoStartOnLaunch {
                for p in self.processes where p.config.autoStart {
                    try? p.start()
                    started.insert(p.id)
                }
            }
            if let previous, !previous.cleanShutdown {
                let toRestore = previous.runningIds.filter { id in
                    !started.contains(id) && self.process(id) != nil
                }
                if !toRestore.isEmpty {
                    switch self.settings.restoreAfterCrash {
                    case .always:
                        for id in toRestore { try? self.process(id)?.start() }
                    case .ask:
                        self.pendingRestore = toRestore
                    case .never:
                        break
                    }
                }
            }
            self.writeRuntimeState(force: true)
        }
    }

    private func loadConfigAtLaunch() {
        do {
            let config = try store.loadOrCreate()
            lastConfigData = store.rawData()
            settings = config.settings
            processes = config.commands.map(makeProcess)
        } catch {
            configLoadFailed = true
            configError = "Could not read \(store.configURL.path): \(error.localizedDescription). Fix the file; Wickbar reloads it automatically."
        }
    }

    private func makeProcess(_ config: CommandConfig) -> ManagedProcess {
        let p = ManagedProcess(config: config)
        p.launchContext = { [weak self] in
            let snap = self?.shellSnapshot ?? ShellEnvironment.fallback(shell: ShellEnvironment.loginShell, note: "not captured yet")
            return (snap.shell, snap.environment)
        }
        p.onStatusChange = { [weak self] proc, old, new in
            self?.statusChanged(proc, from: old, to: new)
        }
        return p
    }

    func process(_ id: UUID) -> ManagedProcess? { processes.first { $0.id == id } }

    // MARK: Shell environment

    func reloadShellEnvironment(completion: (() -> Void)? = nil) {
        capturingEnvironment = true
        Task.detached(priority: .userInitiated) {
            let snap = ShellEnvironment.capture()
            await MainActor.run { [weak self] in
                self?.shellSnapshot = snap
                self?.capturingEnvironment = false
                completion?()
            }
        }
    }

    // MARK: Status bookkeeping

    private func statusChanged(_ p: ManagedProcess, from old: CommandStatus, to new: CommandStatus) {
        statusTick &+= 1
        writeRuntimeState()
        if new == .crashed && old != .crashed {
            let code = p.lastExitCode.map { "exit code \($0)" } ?? (p.lastExitWasSignal ? "killed by a signal" : "failed to start")
            Notifications.post(title: "\(p.config.name) crashed",
                               body: p.gaveUp ? "Gave up restarting after repeated failures (\(code))." : "Exited unexpectedly (\(code)).")
        } else if new == .restarting && p.restartCount == 0 {
            let code = p.lastExitCode.map { "exit code \($0)" } ?? "killed by a signal"
            Notifications.post(title: "\(p.config.name) exited", body: "Exited (\(code)); restarting.")
        }
    }

    var activeIds: [UUID] { processes.filter { $0.status.isActive }.map(\.id) }

    private func writeRuntimeState(force: Bool = false, clean: Bool = false) {
        var ids = activeIds
        for id in pendingRestore where !ids.contains(id) { ids.append(id) }
        if !force && !clean && ids == lastWrittenRunning { return }
        lastWrittenRunning = ids
        stateStore.save(RuntimeState(cleanShutdown: clean, runningIds: ids))
    }

    // MARK: Crash restore banner

    func restorePending() {
        let ids = pendingRestore
        pendingRestore = []
        for id in ids { try? process(id)?.start() }
        writeRuntimeState(force: true)
    }

    func dismissRestore() {
        pendingRestore = []
        writeRuntimeState(force: true)
    }

    // MARK: Config persistence & file watching

    private func persist() {
        do {
            if configLoadFailed, FileManager.default.fileExists(atPath: store.configURL.path) {
                let backup = store.directory.appendingPathComponent("config.invalid-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.copyItem(at: store.configURL, to: backup)
                configLoadFailed = false
            }
            lastConfigData = try store.save(ConfigFile(settings: settings, commands: processes.map(\.config)))
            configError = nil
        } catch {
            configError = "Could not save config: \(error.localizedDescription)"
        }
    }

    private func startWatchingConfig() {
        try? store.ensureDirectory()
        let fd = open(store.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            self?.scheduleConfigReload()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func scheduleConfigReload() {
        watchDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.reloadConfigFromDisk() }
        }
        watchDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func reloadConfigFromDisk() {
        guard let data = store.rawData() else { return }  // deleted: keep current state; next save recreates it
        guard data != lastConfigData else { return }
        do {
            let config = try ConfigFile.decode(data)
            lastConfigData = data
            configLoadFailed = false
            configError = nil
            apply(config)
        } catch {
            configError = "config.json is invalid (\(error.localizedDescription)). Keeping the previous configuration."
        }
    }

    /// Applies an externally edited config without disturbing unchanged running commands.
    private func apply(_ config: ConfigFile) {
        let oldSettings = settings
        settings = config.settings
        if oldSettings.mcpEnabled != settings.mcpEnabled || oldSettings.mcpPort != settings.mcpPort {
            applyMCPSettings()
        }
        var next: [ManagedProcess] = []
        let newIds = Set(config.commands.map(\.id))
        for c in config.commands {
            if let existing = process(c.id) {
                let needsRestart = existing.isRunning && c.runtimeDiffers(from: existing.config)
                existing.config = c
                if needsRestart {
                    Task { try? await existing.restart() }
                }
                next.append(existing)
            } else {
                next.append(makeProcess(c))
            }
        }
        for removed in processes where !newIds.contains(removed.id) {
            Task { await removed.stop() }
        }
        processes = next
        pendingRestore.removeAll { !newIds.contains($0) }
        writeRuntimeState()
    }

    // MARK: UI-facing operations

    func start(_ id: UUID) {
        do { try process(id)?.start() } catch { NSSound.beep() }
    }

    func stop(_ id: UUID) {
        guard let p = process(id) else { return }
        Task { await p.stop() }
    }

    func restart(_ id: UUID) {
        guard let p = process(id) else { return }
        Task { try? await p.restart() }
    }

    func startAllCommands() {
        for p in processes where !p.status.hasProcess { try? p.start() }
    }

    func stopAllCommands() async {
        await withTaskGroup(of: Void.self) { group in
            for p in processes where p.status.isActive {
                group.addTask { await p.stop() }
            }
        }
    }

    /// Adds or replaces (by id) a command from the editor. Restarts it if running and its runtime fields changed.
    func save(_ config: CommandConfig) {
        if let existing = process(config.id) {
            let needsRestart = existing.isRunning && config.runtimeDiffers(from: existing.config)
            existing.config = config
            persist()
            objectWillChange.send()
            if needsRestart { Task { try? await existing.restart() } }
        } else {
            processes.append(makeProcess(config))
            persist()
        }
    }

    func duplicate(_ id: UUID) -> UUID? {
        guard let p = process(id) else { return nil }
        var copy = p.config
        copy.id = UUID()
        var name = "\(p.config.name) copy"
        var n = 2
        while CommandLookup.nameIsTaken(name, in: processes.map(\.config)) {
            name = "\(p.config.name) copy \(n)"
            n += 1
        }
        copy.name = name
        copy.autoStart = false
        processes.append(makeProcess(copy))
        persist()
        return copy.id
    }

    func delete(_ id: UUID) {
        guard let p = process(id) else { return }
        processes.removeAll { $0.id == id }
        pendingRestore.removeAll { $0 == id }
        persist()
        Task { await p.stop() }
    }

    func move(from source: IndexSet, to destination: Int) {
        processes.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func setAutoStartOnLaunch(_ v: Bool) {
        settings.autoStartOnLaunch = v
        persist()
    }

    func setRestoreAfterCrash(_ v: RestoreAfterCrash) {
        settings.restoreAfterCrash = v
        persist()
    }

    func setMCPEnabled(_ v: Bool) {
        settings.mcpEnabled = v
        persist()
        applyMCPSettings()
    }

    func setMCPPort(_ port: Int) {
        guard (1...65535).contains(port), port != settings.mcpPort else { return }
        settings.mcpPort = port
        persist()
        applyMCPSettings()
    }

    func refreshLaunchAtLogin() {
        launchAtLoginInfo = LoginItem.info
    }

    func setLaunchAtLoginFromUI(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    // MARK: Summary for the menu bar icon

    var runningCount: Int { processes.filter { $0.status.hasProcess }.count }
    var crashedCount: Int { processes.filter { $0.status == .crashed }.count }
    var hasProblem: Bool { crashedCount > 0 || mcpErrorMessage != nil }

    var mcpErrorMessage: String? {
        if case .failed(let msg) = mcpState { return msg }
        return nil
    }

    var mcpEndpoint: String { "http://127.0.0.1:\(settings.mcpPort)/mcp" }

    // MARK: MCP server lifecycle

    func applyMCPSettings() {
        mcpRetryTask?.cancel()
        mcpRetryTask = nil
        httpServer?.onStateChange = nil
        httpServer?.stop()
        httpServer = nil
        mcpState = .stopped
        mcpRetryCount = 0
        guard settings.mcpEnabled else { return }
        startHTTPServer()
    }

    private func startHTTPServer() {
        let mcp = mcpServer
        let server = HTTPServer(port: settings.mcpPort) { req in
            await mcp.handleHTTP(req)
        }
        server.onStateChange = { [weak self, weak server] state in
            guard let self, let server, self.httpServer === server else { return }
            self.mcpState = state
            if case .failed = state { self.scheduleMCPRetry() }
            if case .listening = state { self.mcpRetryCount = 0 }
        }
        httpServer = server
        server.start()
    }

    /// The port may be briefly busy (e.g. a previous instance shutting down): retry a few times.
    private func scheduleMCPRetry() {
        guard mcpRetryCount < 5, mcpRetryTask == nil else { return }
        mcpRetryCount += 1
        mcpRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled, self.settings.mcpEnabled else { return }
            self.mcpRetryTask = nil
            if case .failed(let msg) = self.mcpState {
                self.httpServer?.onStateChange = nil
                self.httpServer?.stop()
                self.httpServer = nil
                self.startHTTPServer()
                self.mcpState = .failed(msg)  // keep showing the error until it succeeds
            }
        }
    }

    // MARK: Quit

    /// Stops everything (bounded ~6s), then records a clean shutdown.
    func shutdown() async {
        watcher?.cancel()
        httpServer?.stop()
        let wasRunning = activeIds
        // Wait for whichever comes first: all commands stopped, or the ~6s budget.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var resumed = false
            let finish = { if !resumed { resumed = true; cont.resume() } }
            let timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                finish()
            }
            Task { @MainActor in
                await self.stopAllCommands()
                timer.cancel()
                finish()
            }
        }
        // Anything still alive gets SIGKILLed so nothing is orphaned.
        for p in processes where p.pid != nil {
            let root = p.pid!
            ProcessTree.signal(SIGKILL, pgid: root, pids: ProcessTree.collect(root: root, pgid: root))
        }
        stateStore.save(RuntimeState(cleanShutdown: true, runningIds: wasRunning))
    }
}

// MARK: - WickbarController (MCP)

extension ProcessManager: WickbarController {
    var commandConfigs: [CommandConfig] { processes.map(\.config) }

    func runtimeInfo(for id: UUID) -> CommandRuntimeInfo {
        process(id)?.runtimeInfo ?? CommandRuntimeInfo()
    }

    func addCommand(_ config: CommandConfig) throws {
        if configLoadFailed { throw WickbarError(configError ?? "config.json is invalid; fix it first.") }
        processes.append(makeProcess(config))
        persist()
    }

    func updateCommand(_ config: CommandConfig) async throws -> Bool {
        guard let existing = process(config.id) else { throw WickbarError("Command not found.") }
        let needsRestart = existing.isRunning && config.runtimeDiffers(from: existing.config)
        existing.config = config
        persist()
        objectWillChange.send()
        if needsRestart { try await existing.restart() }
        return needsRestart
    }

    func removeCommand(id: UUID) async throws {
        guard let p = process(id) else { throw WickbarError("Command not found.") }
        await p.stop()
        processes.removeAll { $0.id == id }
        pendingRestore.removeAll { $0 == id }
        persist()
    }

    func startCommand(id: UUID) throws {
        guard let p = process(id) else { throw WickbarError("Command not found.") }
        try p.start()
    }

    func stopCommand(id: UUID) async {
        await process(id)?.stop()
    }

    func restartCommand(id: UUID) async throws {
        guard let p = process(id) else { throw WickbarError("Command not found.") }
        try await p.restart()
    }

    func startAll() { startAllCommands() }

    func stopAll() async { await stopAllCommands() }

    func logs(for id: UUID, lines: Int) -> String {
        process(id)?.output.plainTextTail(lines: lines) ?? ""
    }

    func sendInput(to id: UUID, text: String) throws {
        guard let p = process(id) else { throw WickbarError("Command not found.") }
        try p.sendText(text)
    }

    var appSettings: AppSettings { settings }

    var launchAtLogin: LaunchAtLoginInfo { LoginItem.info }

    func updateSettings(autoStartOnLaunch: Bool?, restoreAfterCrash: RestoreAfterCrash?) throws {
        if let a = autoStartOnLaunch { settings.autoStartOnLaunch = a }
        if let r = restoreAfterCrash { settings.restoreAfterCrash = r }
        persist()
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        defer { refreshLaunchAtLogin() }
        try LoginItem.setEnabled(enabled)
    }

    var configPath: String { store.configURL.path }
}
