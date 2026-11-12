import Foundation
import Network

/// Minimal HTTP/1.1 server on Network.framework, bound to 127.0.0.1 only.
public final class HTTPServer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case listening(port: Int)
        case failed(String)
    }

    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    public let port: Int
    private let handler: Handler
    private let queue = DispatchQueue(label: "wickbar.http")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    /// Called on the main queue.
    public var onStateChange: ((State) -> Void)?

    public init(port: Int, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    public func start() {
        report(.starting)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0, port <= 65535 else {
            report(.failed("Invalid port \(port)"))
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = false
        params.acceptLocalOnly = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            report(.failed("Could not listen on 127.0.0.1:\(port): \(error.localizedDescription)"))
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.report(.listening(port: self.port))
            case .failed(let err), .waiting(let err):
                let msg: String
                if case .posix(let code) = err, code == .EADDRINUSE {
                    msg = "Port \(self.port) is already in use."
                } else {
                    msg = "Listener error on port \(self.port): \(err.localizedDescription)"
                }
                listener?.cancel()
                self.report(.failed(msg))
            case .cancelled, .setup:
                break
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
    }

    public func stop() {
        queue.sync {
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
            for c in connections.values { c.close() }
            connections.removeAll()
        }
        report(.stopped)
    }

    private func report(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
    }

    private func accept(_ nw: NWConnection) {
        // Belt and braces: only loopback peers.
        if case .hostPort(let host, _) = nw.endpoint {
            let h = "\(host)"
            if !(h.hasPrefix("127.") || h == "::1" || h.hasPrefix("::ffff:127.") || h == "localhost") {
                nw.cancel()
                return
            }
        }
        let conn = HTTPConnection(nw, queue: queue, handler: handler)
        let key = ObjectIdentifier(conn)
        connections[key] = conn
        conn.onClose = { [weak self] in self?.connections[key] = nil }
        conn.start()
    }
}

/// One keep-alive connection. All state is confined to the server queue.
final class HTTPConnection: @unchecked Sendable {
    private let nw: NWConnection
    private let queue: DispatchQueue
    private let handler: HTTPServer.Handler
    private var parser = HTTPRequestParser()
    private var handling = false
    private var sentContinue = false
    private var closed = false
    private var peerFinished = false
    private var idleTimer: DispatchWorkItem?
    var onClose: (() -> Void)?

    init(_ nw: NWConnection, queue: DispatchQueue, handler: @escaping HTTPServer.Handler) {
        self.nw = nw
        self.queue = queue
        self.handler = handler
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        nw.start(queue: queue)
        armIdleTimer()
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        idleTimer?.cancel()
        nw.stateUpdateHandler = nil
        nw.cancel()
        onClose?()
        onClose = nil
    }

    private func armIdleTimer() {
        idleTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.handling else { return }
            self.close()
        }
        idleTimer = item
        queue.asyncAfter(deadline: .now() + 120, execute: item)
    }

    private func receive() {
        guard !closed else { return }
        nw.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.parser.append(data)
                self.armIdleTimer()
            }
            if isComplete || error != nil { self.peerFinished = true }
            self.processBuffer()
        }
    }

    private func processBuffer() {
        guard !closed, !handling else { return }
        switch parser.next() {
        case .incomplete:
            if peerFinished { close(); return }
            if parser.headExpectsContinue() && !sentContinue {
                sentContinue = true
                nw.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            }
            receive()
        case .error(let status, let message):
            send(HTTPResponse.text(message + "\n", status: status), keepAlive: false)
        case .request(let req):
            handling = true
            sentContinue = false
            let handler = self.handler
            Task {
                let resp = await handler(req)
                self.queue.async {
                    self.handling = false
                    self.send(resp, keepAlive: req.keepAlive && !self.peerFinished)
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, keepAlive: Bool) {
        guard !closed else { return }
        nw.send(content: response.serialized(keepAlive: keepAlive), completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            self.queue.async {
                if !keepAlive || err != nil {
                    self.close()
                } else {
                    self.processBuffer()
                }
            }
        })
    }
}
