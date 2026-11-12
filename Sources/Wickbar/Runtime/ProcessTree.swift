import Darwin
import Foundation

/// Process-tree helpers used to stop a command and everything it spawned.
enum ProcessTree {
    /// Direct children of `pid` (via libproc). Uses `proc_listpids(PROC_PPID_ONLY)`, which reports
    /// bytes consistently (`proc_listchildpids` returns a pid count, which is easy to misread).
    static func children(of pid: pid_t) -> [pid_t] {
        list(type: UInt32(PROC_PPID_ONLY), info: UInt32(pid))
    }

    private static func list(type: UInt32, info: UInt32) -> [pid_t] {
        let estimate = proc_listpids(type, info, nil, 0)
        guard estimate > 0 else { return [] }
        // Leave headroom for processes spawned between the two calls.
        var buf = [pid_t](repeating: 0, count: Int(estimate) / MemoryLayout<pid_t>.size + 32)
        let bytes = buf.withUnsafeMutableBytes { raw -> Int32 in
            proc_listpids(type, info, raw.baseAddress, Int32(raw.count))
        }
        guard bytes > 0 else { return [] }
        return Array(buf.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    /// All descendants of `pid` (breadth-first, excluding `pid`).
    static func descendants(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var seen: Set<pid_t> = [pid]
        var queue = [pid]
        while !queue.isEmpty {
            let p = queue.removeFirst()
            for c in children(of: p) where !seen.contains(c) {
                seen.insert(c)
                result.append(c)
                queue.append(c)
            }
        }
        return result
    }

    /// Members of a process group (catches children re-parented to launchd after their parent exited).
    static func members(ofGroup pgid: pid_t) -> [pid_t] {
        list(type: UInt32(PROC_PGRP_ONLY), info: UInt32(pgid))
    }

    /// True if the pid exists and is not a zombie.
    static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0 && errno == ESRCH { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        if r == size && info.pbi_status == UInt32(SZOMB) { return false }
        return true
    }

    /// Everything that belongs to a command rooted at `root` whose process group is `pgid`.
    static func collect(root: pid_t, pgid: pid_t) -> Set<pid_t> {
        var all = Set<pid_t>()
        if root > 0 {
            all.insert(root)
            all.formUnion(descendants(of: root))
        }
        if pgid > 1 {
            for m in members(ofGroup: pgid) {
                all.insert(m)
                all.formUnion(descendants(of: m))
            }
        }
        all.remove(getpid())
        all.remove(0)
        all.remove(1)
        return all
    }

    /// Sends `sig` to the process group and to every pid in `pids`.
    static func signal(_ sig: Int32, pgid: pid_t, pids: Set<pid_t>) {
        if pgid > 1 && pgid != getpgrp() { kill(-pgid, sig) }
        for p in pids where p > 1 && p != getpid() { kill(p, sig) }
    }

    /// SIGTERM the tree, wait up to `grace` seconds, then SIGKILL survivors. Runs async on the main actor
    /// without blocking it. Returns once everything is gone (or after the SIGKILL sweep).
    @MainActor
    static func terminate(root: pid_t, pgid: pid_t, grace: TimeInterval = 5) async {
        var targets = collect(root: root, pgid: pgid)
        guard !targets.isEmpty else { return }
        signal(SIGTERM, pgid: pgid, pids: targets)
        // A stopped (SIGTSTP'd) process won't handle SIGTERM until continued.
        signal(SIGCONT, pgid: pgid, pids: targets)
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            // Pick up anything spawned during shutdown.
            targets.formUnion(collect(root: 0, pgid: pgid))
            targets = targets.filter(isAlive)
            if targets.isEmpty { return }
        }
        targets.formUnion(collect(root: 0, pgid: pgid))
        for p in targets { targets.formUnion(descendants(of: p)) }
        signal(SIGKILL, pgid: pgid, pids: targets.filter(isAlive))
        // Give the kernel a moment to deliver.
        for _ in 0..<10 {
            if targets.filter(isAlive).isEmpty { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
