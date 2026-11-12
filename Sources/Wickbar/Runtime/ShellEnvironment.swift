import Foundation

/// Captures the user's login-shell environment once, because GUI / login-item apps don't inherit the shell PATH.
final class ShellEnvironment: @unchecked Sendable {
    static let marker = "__WICKBAR_ENV__"

    struct Snapshot: Sendable {
        var shell: String
        var environment: [String: String]
        var capturedFromShell: Bool
        var capturedAt: Date
        var note: String?
    }

    /// The user's login shell from the password database, falling back to /bin/zsh.
    static var loginShell: String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        return "/bin/zsh"
    }

    /// Runs `<shell> -l -i -c 'printf MARKER; env -0'` with a timeout and parses the output.
    static func capture(timeout: TimeInterval = 10) -> Snapshot {
        let shell = loginShell
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-l", "-i", "-c", "printf '\(marker)'; env -0"]
        proc.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        var baseEnv = ProcessInfo.processInfo.environment
        baseEnv["HOME"] = NSHomeDirectory()
        baseEnv["TERM"] = baseEnv["TERM"] ?? "dumb"
        proc.environment = baseEnv
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice

        let collected = LockedData()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { collected.append(d) }
        }
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do {
            try proc.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            return fallback(shell: shell, note: "Could not run \(shell): \(error.localizedDescription)")
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            kill(-proc.processIdentifier, SIGKILL)
            proc.terminate()
            kill(proc.processIdentifier, SIGKILL)
            out.fileHandleForReading.readabilityHandler = nil
            return fallback(shell: shell, note: "Timed out capturing the environment from \(shell)")
        }
        // Drain whatever is left.
        out.fileHandleForReading.readabilityHandler = nil
        if let rest = try? out.fileHandleForReading.readToEnd() { collected.append(rest) }

        guard let env = parse(collected.data), env["PATH"] != nil else {
            return fallback(shell: shell, note: "Could not parse the environment printed by \(shell)")
        }
        return Snapshot(shell: shell, environment: sanitize(env), capturedFromShell: true, capturedAt: Date(), note: nil)
    }

    /// Parses NUL-separated `KEY=VALUE` records found after the marker (anything the rc files print before it is ignored).
    static func parse(_ data: Data) -> [String: String]? {
        guard let range = data.range(of: Data(marker.utf8), options: .backwards) else { return nil }
        let payload = data[range.upperBound...]
        var env: [String: String] = [:]
        for record in payload.split(separator: 0, omittingEmptySubsequences: true) {
            let s = String(decoding: record, as: UTF8.self)
            guard let eq = s.firstIndex(of: "="), eq != s.startIndex else { continue }
            env[String(s[..<eq])] = String(s[s.index(after: eq)...])
        }
        return env.isEmpty ? nil : env
    }

    /// Drops per-shell-instance variables that shouldn't leak into commands.
    static func sanitize(_ env: [String: String]) -> [String: String] {
        var e = env
        for key in ["_", "SHLVL", "PWD", "OLDPWD", "TERM_SESSION_ID", "ITERM_SESSION_ID", "TERM_PROGRAM",
                    "TERM_PROGRAM_VERSION", "WICKBAR_ENV_CAPTURE", "XPC_SERVICE_NAME", "__CFBundleIdentifier"] {
            e[key] = nil
        }
        return e
    }

    static func fallback(shell: String, note: String) -> Snapshot {
        var env = sanitize(ProcessInfo.processInfo.environment)
        let home = NSHomeDirectory()
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "\(home)/.cargo/bin", "\(home)/.local/bin"]
        var parts = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for p in extra.reversed() where !parts.contains(p) { parts.insert(p, at: 0) }
        for p in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !parts.contains(p) { parts.append(p) }
        env["PATH"] = parts.joined(separator: ":")
        env["HOME"] = home
        env["SHELL"] = shell
        if env["USER"] == nil { env["USER"] = NSUserName() }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return Snapshot(shell: shell, environment: env, capturedFromShell: false, capturedAt: Date(), note: note)
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ d: Data) { lock.lock(); storage.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
}
