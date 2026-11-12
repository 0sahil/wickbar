import Foundation

/// Thread-safe byte ring buffer holding a command's raw PTY output (~2 MB, trimmed from the front).
/// Subscribers (terminal views) receive the existing contents on attach, then every new chunk.
public final class OutputBuffer: @unchecked Sendable {
    public typealias Subscriber = (ArraySlice<UInt8>) -> Void

    public let capacity: Int
    private let lock = NSLock()
    private var storage: [UInt8] = []
    private var subscribers: [UUID: Subscriber] = [:]

    public init(capacity: Int = 2 * 1024 * 1024) {
        self.capacity = max(1024, capacity)
        storage.reserveCapacity(min(self.capacity, 256 * 1024))
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }

    public func snapshot() -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    public var endsWithNewline: Bool {
        lock.lock(); defer { lock.unlock() }
        return storage.isEmpty || storage.last == 0x0A
    }

    public func append(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        storage.append(contentsOf: bytes)
        // Let the array grow 25% past capacity before trimming, so trimming (a memmove) is amortized.
        if storage.count > capacity + capacity / 4 {
            trimLocked()
        }
        for sub in subscribers.values { sub(bytes) }
    }

    public func append(_ bytes: [UInt8]) { append(bytes[...]) }
    public func append(_ text: String) { append(Array(text.utf8)[...]) }

    /// Appends a dim separator line such as `── started 12:01:03 ──`, starting on a fresh line.
    public func appendSeparator(_ text: String) {
        var line = endsWithNewline ? "" : "\r\n"
        line += "\u{1B}[0m\u{1B}[2m── \(text) ──\u{1B}[0m\r\n"
        append(line)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll(keepingCapacity: true)
    }

    /// Registers a subscriber; it is synchronously handed the current contents first (under the lock,
    /// so no bytes are lost or duplicated between snapshot and stream).
    @discardableResult
    public func attach(_ subscriber: @escaping Subscriber) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let token = UUID()
        if !storage.isEmpty { subscriber(storage[...]) }
        subscribers[token] = subscriber
        return token
    }

    public func detach(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        subscribers[token] = nil
    }

    /// Plain-text tail (ANSI stripped, `\r` handled), last `lines` lines.
    public func plainTextTail(lines: Int) -> String {
        ANSIText.lastLines(snapshot(), count: lines)
    }

    private func trimLocked() {
        var drop = storage.count - capacity
        // Prefer cutting at a line boundary so the head of the buffer is not a half escape sequence.
        let searchEnd = min(storage.count, drop + 4096)
        if let nl = storage[drop..<searchEnd].firstIndex(of: 0x0A) {
            drop = nl + 1
        }
        storage.removeFirst(drop)
    }
}

/// Converts raw terminal output to plain text.
public enum ANSIText {
    private enum State { case normal, esc, escIntermediate, csi, string, stringEsc }

    /// Removes CSI / OSC / DCS / other escape sequences and non-printing control characters.
    /// Keeps `\n`, `\r`, `\t` and backspace (handled later by `lines`).
    public static func stripEscapes(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var state = State.normal
        for s in text.unicodeScalars {
            let v = s.value
            switch state {
            case .normal:
                switch v {
                case 0x1B: state = .esc
                case 0x9B: state = .csi
                case 0x9D, 0x90, 0x98, 0x9E, 0x9F: state = .string
                case 0x0A, 0x0D, 0x09, 0x08: out.append(s)
                case 0..<0x20, 0x7F, 0x80..<0xA0: break
                default: out.append(s)
                }
            case .esc:
                state = afterEsc(v)
            case .escIntermediate:
                if v == 0x1B { state = .esc } else if !(0x20...0x2F).contains(v) { state = .normal }
            case .csi:
                if v == 0x1B { state = .esc } else if (0x40...0x7E).contains(v) { state = .normal }
                // parameters / intermediates / stray controls are dropped
            case .string:
                if v == 0x07 || v == 0x9C { state = .normal } else if v == 0x1B { state = .stringEsc }
            case .stringEsc:
                state = v == 0x5C ? .normal : afterEsc(v)
            }
        }
        return String(out)
    }

    private static func afterEsc(_ v: UInt32) -> State {
        switch v {
        case 0x5B: return .csi                         // [
        case 0x5D, 0x50, 0x58, 0x5E, 0x5F: return .string // ] P X ^ _
        case 0x1B: return .esc
        case 0x20...0x2F: return .escIntermediate      // e.g. ESC ( B
        default: return .normal                        // two-byte sequence (ESC 7, ESC =, ...)
        }
    }

    /// Splits into lines. Per line: CRLF endings are ignored, only text after the last `\r` is kept
    /// (progress bars), and backspaces erase the previous character.
    public static func lines(_ text: String) -> [String] {
        // Work on unicode scalars: in Swift "\r\n" is a single Character, which would defeat splitting.
        let scalars = Array(stripEscapes(text).unicodeScalars)
        var result: [String] = []
        var start = 0
        func finish(_ end: Int) {
            var e = end
            while e > start && scalars[e - 1] == "\r" { e -= 1 }
            var s = start
            if let cr = scalars[s..<e].lastIndex(of: "\r") { s = cr + 1 }
            var line = String.UnicodeScalarView()
            for sc in scalars[s..<e] {
                if sc == "\u{8}" {
                    if !line.isEmpty { line.removeLast() }
                } else {
                    line.append(sc)
                }
            }
            result.append(String(line))
        }
        for (i, sc) in scalars.enumerated() where sc == "\n" {
            finish(i)
            start = i + 1
        }
        if start < scalars.count { finish(scalars.count) }
        return result
    }

    public static func lines(_ bytes: [UInt8]) -> [String] {
        lines(String(decoding: bytes, as: UTF8.self))
    }

    public static func lastLines(_ bytes: [UInt8], count: Int) -> String {
        let all = lines(bytes)
        return all.suffix(max(0, count)).joined(separator: "\n")
    }
}
