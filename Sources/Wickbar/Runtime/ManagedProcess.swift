import Foundation
import SwiftTerm
import WickbarCore

/// One saved command and its live process (PTY via SwiftTerm's LocalProcess).
@MainActor
final class ManagedProcess: ObservableObject, Identifiable {
    nonisolated let id: UUID
    @Published var config: CommandConfig
    @Published private(set) var status: CommandStatus = .stopped
    @Published private(set) var pid: pid_t?
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastExitCode: Int32?
    @Published private(set) var lastExitWasSignal = false
    @Published private(set) var restartCount = 0
    /// True when the restart policy gave up after too many failures.
    @Published private(set) var gaveUp = false
    /// Bumped when output is cleared so terminal views can be recreated.
    @Published private(set) var outputGeneration = 0

    let output = OutputBuffer()

    /// Supplies the shell + environment to launch with.
    var launchContext: () -> (shell: String, environment: [String: String]) = {
        (ShellEnvironment.loginShell, ProcessInfo.processInfo.environment)
    }
    /// Called whenever status changes (for state.json / menu icon / notifications).
    var onStatusChange: ((ManagedProcess, CommandStatus, CommandStatus) -> Void)?

    private var process: LocalProcess?
    private var bridge: ProcessBridge?
    private var runGeneration = 0
    private var userRequestedStop = false
    /// True if the last stop was requested by the user (vs. the process exiting on its own).
    var stoppedByUser: Bool { userRequestedStop }
    private var restartTask: Task<Void, Never>?
    private var promoteTask: Task<Void, Never>?
    private var backoff: TimeInterval = 1
    private var recentFailures: [Date] = []
    private var exitWaiters: [(UUID, CheckedContinuation<Void, Never>)] = []
    private var stopInFlight = false

    static let maxBackoff: TimeInterval = 30
    static let failureWindow: TimeInterval = 60
    static let maxFailuresInWindow = 5
    static let stableRunDuration: TimeInterval = 60

    init(config: CommandConfig) {
        self.id = config.id
        self.config = config
    }

    var runtimeInfo: CommandRuntimeInfo {
        CommandRuntimeInfo(status: status, pid: pid, startedAt: startedAt, lastExitCode: lastExitCode,
                           lastExitWasSignal: lastExitWasSignal, restartCount: restartCount)
    }

    var isRunning: Bool { status.hasProcess }

    // MARK: Start

    /// Starts the command. Throws if the working directory is invalid.
    func start() throws {
        switch status {
        case .starting, .running, .stopping:
            return
        case .restarting:
            restartTask?.cancel()
            restartTask = nil
        case .stopped, .crashed:
            // A manual start resets the crash-loop accounting.
            backoff = 1
            recentFailures.removeAll()
            restartCount = 0
        }
        try launch()
    }

    private func launch() throws {
        gaveUp = false
        let cwd = config.resolvedWorkingDirectory()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            output.appendSeparator("cannot start: working directory \(cwd) does not exist")
            setStatus(.crashed)
            throw WickbarError("Working directory '\(cwd)' does not exist.")
        }

        let ctx = launchContext()
        var env = ctx.environment
        for (k, v) in config.environment { env[k] = v }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["PWD"] = cwd
        env["WICKBAR"] = "1"
        env["WICKBAR_COMMAND"] = config.name
        let envList = env.map { "\($0.key)=\($0.value)" }

        runGeneration += 1
        let generation = runGeneration
        let bridge = ProcessBridge(buffer: output, size: bridgeSize)
        bridge.onExit = { [weak self] code in
            Task { @MainActor in self?.processExited(generation: generation, exitCode: code) }
        }
        let proc = LocalProcess(delegate: bridge, dispatchQueue: DispatchQueue(label: "wickbar.proc.\(config.name)"))
        // We do our own tree-wide termination; keep SwiftTerm's deinit escalation short as a last resort.
        proc.killEscalationDelay = 1

        userRequestedStop = false
        output.appendSeparator("started \(Self.timeFormatter.string(from: Date()))")
        let result = proc.startProcessChecked(executable: ctx.shell, args: ["-c", config.command],
                                              environment: envList, currentDirectory: cwd)
        if case .failure(let err) = result {
            output.appendSeparator("failed to start: \(err)")
            setStatus(.crashed)
            throw WickbarError("Failed to start '\(config.name)': \(err)")
        }
        self.bridge = bridge
        self.process = proc
        pid = proc.shellPid > 0 ? proc.shellPid : nil
        startedAt = Date()
        setStatus(.starting)
        promoteTask?.cancel()
        promoteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !Task.isCancelled, self.runGeneration == generation, self.status == .starting else { return }
            self.setStatus(.running)
        }
    }

    // MARK: Exit handling

    private func processExited(generation: Int, exitCode: Int32?) {
        guard generation == runGeneration else { return }
        let rootPid = pid ?? 0
        let ranFor = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        process = nil
        bridge = nil
        pid = nil
        promoteTask?.cancel()
        lastExitCode = exitCode
        lastExitWasSignal = exitCode == nil

        // Clean up anything left in the command's process group (e.g. backgrounded children).
        if rootPid > 1 && !stopInFlight {
            let leftovers = ProcessTree.collect(root: 0, pgid: rootPid)
            if !leftovers.isEmpty {
                Task { await ProcessTree.terminate(root: 0, pgid: rootPid, grace: 3) }
            }
        }

        let exitText = exitCode.map { "exited (code \($0))" } ?? "exited (killed by signal)"
        if userRequestedStop {
            output.appendSeparator("stopped \(Self.timeFormatter.string(from: Date()))")
            setStatus(.stopped)
            resumeExitWaiters()
            return
        }
        output.appendSeparator("\(exitText) \(Self.timeFormatter.string(from: Date()))")
        resumeExitWaiters()

        let failed = exitCode != 0
        let shouldRestart: Bool
        switch config.restartPolicy {
        case .never: shouldRestart = false
        case .onFailure: shouldRestart = failed
        case .always: shouldRestart = true
        }
        guard shouldRestart else {
            setStatus(failed ? .crashed : .stopped)
            return
        }

        if ranFor > Self.stableRunDuration {
            backoff = 1
            recentFailures.removeAll()
        }
        let now = Date()
        recentFailures.append(now)
        recentFailures.removeAll { now.timeIntervalSince($0) > Self.failureWindow }
        if recentFailures.count >= Self.maxFailuresInWindow {
            output.appendSeparator("gave up after \(recentFailures.count) failures within \(Int(Self.failureWindow))s")
            gaveUp = true
            setStatus(.crashed)
            return
        }

        let delay = backoff
        backoff = min(backoff * 2, Self.maxBackoff)
        output.appendSeparator("restarting in \(Int(delay))s")
        setStatus(.restarting)
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.status == .restarting else { return }
            self.restartTask = nil
            self.restartCount += 1
            do { try self.launch() } catch { /* status already set to crashed */ }
        }
    }

    private func resumeExitWaiters() {
        let waiters = exitWaiters
        exitWaiters.removeAll()
        for w in waiters { w.1.resume() }
    }

    // MARK: Stop

    /// Gracefully stops: SIGTERM to the process group and all descendants, SIGKILL after 5s.
    func stop() async {
        restartTask?.cancel()
        restartTask = nil
        switch status {
        case .restarting, .crashed:
            userRequestedStop = true
            setStatus(.stopped)
            return
        case .stopped:
            return
        case .stopping:
            // Already stopping: wait for it.
            if process != nil { await waitForExit(timeout: 7) }
            return
        case .starting, .running:
            break
        }
        guard let proc = process else {
            setStatus(.stopped)
            return
        }
        userRequestedStop = true
        stopInFlight = true
        setStatus(.stopping)
        let root = proc.shellPid > 0 ? proc.shellPid : (pid ?? 0)
        await ProcessTree.terminate(root: root, pgid: root, grace: 5)
        // The exit callback normally arrives right after; don't hang if it doesn't.
        if process != nil { await waitForExit(timeout: 2) }
        stopInFlight = false
        if status == .stopping {
            // Exit callback never came (e.g. a descendant holds the PTY): force the state.
            runGeneration += 1
            process = nil
            bridge = nil
            pid = nil
            output.appendSeparator("stopped \(Self.timeFormatter.string(from: Date()))")
            setStatus(.stopped)
        }
    }

    func restart() async throws {
        await stop()
        try start()
    }

    private func waitForExit(timeout: TimeInterval) async {
        let token = UUID()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            exitWaiters.append((token, cont))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, let idx = self.exitWaiters.firstIndex(where: { $0.0 == token }) else { return }
                let waiter = self.exitWaiters.remove(at: idx)
                waiter.1.resume()
            }
        }
    }

    // MARK: I/O

    func send(_ bytes: [UInt8]) {
        guard let process, !bytes.isEmpty else { return }
        process.send(data: bytes[...])
    }

    func sendText(_ text: String) throws {
        guard process != nil else { throw WickbarError("'\(config.name)' is not running.") }
        send(Array(text.utf8))
    }

    private var bridgeSize = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)

    /// Called when an attached terminal view resizes.
    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        guard size.ws_col != bridgeSize.ws_col || size.ws_row != bridgeSize.ws_row else { return }
        bridgeSize = size
        bridge?.setSize(size)
        process?.updateWindowSize(&size)
    }

    func clearOutput() {
        output.clear()
        outputGeneration += 1
    }

    // MARK: Helpers

    private func setStatus(_ new: CommandStatus) {
        let old = status
        guard old != new else { return }
        status = new
        onStatusChange?(self, old, new)
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// LocalProcess delegate living on the process's delivery queue (not the main actor).
final class ProcessBridge: LocalProcessDelegate, @unchecked Sendable {
    private let buffer: OutputBuffer
    private let lock = NSLock()
    private var size: winsize
    var onExit: ((Int32?) -> Void)?

    init(buffer: OutputBuffer, size: winsize) {
        self.buffer = buffer
        self.size = size
    }

    func setSize(_ s: winsize) {
        lock.lock(); size = s; lock.unlock()
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        onExit?(exitCode)
    }

    func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        buffer.append("\r\nProcess launch failed: \(error)\r\n")
        onExit?(127)
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        buffer.append(slice)
    }

    func getWindowSize() -> winsize {
        lock.lock(); defer { lock.unlock() }
        return size
    }
}
