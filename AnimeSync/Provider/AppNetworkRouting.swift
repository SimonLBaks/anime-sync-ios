import Foundation
import Network
import WebKit

/// Only an app-local CONNECT tunnel; TLS and hostname verification remain in Apple networking.
@MainActor final class AppNetworkRouting {
    static let shared = AppNetworkRouting()
    private let queue = DispatchQueue(label: "xyz.loibaks.animesync.routing")
    private var listener: NWListener?
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private(set) var port: UInt16?
    private let tunnels = TunnelPool()

    func start() async throws {
        if port != nil { return }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
            guard listener == nil else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let server = try NWListener(using: parameters, on: .any)
                listener = server
                let pool = tunnels
                server.newConnectionHandler = { connection in pool.accept(connection) }
                server.stateUpdateHandler = { [weak self, weak server] state in
                    Task { @MainActor in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let value = server?.port?.rawValue else { return }
                            self.port = value
                            let pending = self.waiters; self.waiters.removeAll()
                            pending.forEach { $0.resume() }
                        case .failed(let error):
                            self.listener?.cancel(); self.listener = nil; self.port = nil
                            let pending = self.waiters; self.waiters.removeAll()
                            pending.forEach { $0.resume(throwing: error) }
                        default: break
                        }
                    }
                }
                server.start(queue: queue)
            } catch {
                listener = nil
                let pending = waiters; waiters.removeAll()
                pending.forEach { $0.resume(throwing: error) }
            }
        }
    }
    func configure(_ configuration: URLSessionConfiguration) {
        guard let port, let value = NWEndpoint.Port(rawValue: port) else { return }
        configuration.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: value), tlsOptions: nil)]
    }
    func configure(_ store: WKWebsiteDataStore) {
        guard let port, let value = NWEndpoint.Port(rawValue: port) else { return }
        store.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: value), tlsOptions: nil)]
    }
}

private final class TunnelPool {
    private let queue = DispatchQueue(label: "xyz.loibaks.animesync.tunnels")
    private var connections: [UUID: ConnectTunnel] = [:]
    func accept(_ connection: NWConnection) {
        queue.async {
            guard self.connections.count < 48 else { connection.cancel(); return }
            let id = UUID()
            let tunnel = ConnectTunnel(client: connection, queue: self.queue) { [weak self] in self?.connections.removeValue(forKey: id) }
            self.connections[id] = tunnel; tunnel.start()
        }
    }
}

private final class ConnectTunnel {
    private let client: NWConnection
    private var upstream: NWConnection?
    private let queue: DispatchQueue
    private let finished: () -> Void
    private var buffer = Data()
    private var closed = false
    private var ended = 0
    private var lastActivity = Date()
    private var timer: DispatchSourceTimer?
    init(client: NWConnection, queue: DispatchQueue, finished: @escaping () -> Void) { self.client = client; self.queue = queue; self.finished = finished }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in guard let self else { return }; if Date().timeIntervalSince(self.lastActivity) > 90 { self.finish() } }
        self.timer = timer; timer.resume()
        client.stateUpdateHandler = { [weak self] state in
            switch state { case .ready: self?.readConnect(); case .failed, .cancelled: self?.finish(); default: break }
        }
        client.start(queue: queue)
    }
    private func readConnect() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            self.lastActivity = Date()
            if let data { self.buffer.append(data) }
            guard self.buffer.count <= 16384, error == nil, !done else { self.finish(); return }
            let marker = Data("\r\n\r\n".utf8)
            guard let range = self.buffer.range(of: marker) else { self.readConnect(); return }
            guard let head = String(data: self.buffer[..<range.lowerBound], encoding: .utf8),
                  let first = head.components(separatedBy: "\r\n").first else { self.finish(); return }
            let parts = first.split(separator: " ")
            guard parts.count == 3, parts[0] == "CONNECT", parts[2].hasPrefix("HTTP/1."),
                  let target = Self.authority(String(parts[1])) else { self.finish(); return }
            let remainder = Data(self.buffer[range.upperBound...]); self.buffer.removeAll()
            let host = AppConfiguration.current.connectHost(for: target.host)
            guard let port = NWEndpoint.Port(rawValue: target.port) else { self.finish(); return }
            let upstream = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            self.upstream = upstream
            upstream.stateUpdateHandler = { [weak self] state in
                guard let self, !self.closed else { return }
                switch state {
                case .ready:
                    self.client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { [weak self] error in
                        guard let self, error == nil else { self?.finish(); return }
                        if !remainder.isEmpty { upstream.send(content: remainder, completion: .contentProcessed { [weak self] error in if error != nil { self?.finish() } }) }
                        self.pipe(self.client, upstream); self.pipe(upstream, self.client)
                    })
                case .failed, .cancelled: self.finish()
                default: break
                }
            }
            upstream.start(queue: self.queue)
        }
    }
    static func authority(_ raw: String) -> (host: String, port: UInt16)? {
        guard let parts = URLComponents(string: "https://" + raw), parts.user == nil, parts.password == nil,
              parts.path.isEmpty, parts.query == nil, parts.fragment == nil,
              let host = parts.host?.lowercased(), !host.isEmpty, let port = parts.port, [443, 8443].contains(port),
              host.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil,
              !["localhost", "127.0.0.1", "0.0.0.0"].contains(host) else { return nil }
        return (host, UInt16(port))
    }
    private func pipe(_ source: NWConnection, _ target: NWConnection) {
        guard !closed else { return }
        source.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if error != nil { self.finish(); return }
            if let data, !data.isEmpty {
                self.lastActivity = Date()
                target.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if error != nil { self.finish() }
                    else if done { self.halfClose(target) }
                    else { self.pipe(source, target) }
                })
            } else if done { self.halfClose(target) }
            else { self.pipe(source, target) }
        }
    }
    private func halfClose(_ target: NWConnection) {
        ended += 1
        target.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in if self?.ended == 2 { self?.finish() } })
    }
    private func finish() {
        guard !closed else { return }; closed = true
        timer?.cancel(); timer = nil; client.cancel(); upstream?.cancel(); finished()
    }
}
