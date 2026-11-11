import Foundation
import Network
import WebKit

/// Only an app-local CONNECT tunnel; TLS and hostname verification remain in Apple networking.
@MainActor final class AppNetworkRouting {
    static let shared = AppNetworkRouting()
    private let deployment: AppConfiguration
    private let makeListener: (NWParameters, NWEndpoint.Port) throws -> NWListener
    private var listener: NWListener?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var startupTimeout: Task<Void, Never>?
    private var preferredPort: NWEndpoint.Port?
    private(set) var port: UInt16?
    private let tunnels: TunnelPool

    init(configuration: AppConfiguration = .current,
         listenerFactory: @escaping (NWParameters, NWEndpoint.Port) throws -> NWListener = { try NWListener(using: $0, on: $1) },
         connectionLimit: Int = 48) {
        deployment = configuration
        makeListener = listenerFactory
        tunnels = TunnelPool(overrides: configuration.connectOverrides, limit: max(1, connectionLimit))
    }

    func start() async throws {
        try Task.checkCancellation()
        guard !deployment.connectOverrides.isEmpty else { return }
        if listener != nil, port != nil { return }
        let ticket = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters[ticket] = continuation
                if listener == nil { openListener() }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.waiters.removeValue(forKey: ticket)?.resume(throwing: CancellationError()) }
        })
        try Task.checkCancellation()
    }

    /// Recover on foreground or manual retry without disrupting current requests.
    /// Callers apply configure again if the listener needed a replacement.
    func recover() async throws {
        try Task.checkCancellation()
        await tunnels.prune()
        if let listener, let port, let endpoint = NWEndpoint.Port(rawValue: port) {
            let reachable = await canConnect(to: endpoint)
            try Task.checkCancellation()
            if !reachable, self.listener === listener { invalidate(NWError.posix(.ECONNREFUSED)) }
        }
        try await start()
    }

    func resetConnections() async { await tunnels.reset() }

    private func canConnect(to port: NWEndpoint.Port) async -> Bool {
        let probe = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        return await withCheckedContinuation { continuation in
            var complete = false
            func finish(_ reachable: Bool) {
                guard !complete else { return }
                complete = true
                probe.stateUpdateHandler = nil
                probe.cancel()
                continuation.resume(returning: reachable)
            }
            probe.stateUpdateHandler = { state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready: finish(true)
                    case .failed, .waiting, .cancelled: finish(false)
                    default: break
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { finish(false) }
            probe.start(queue: .main)
        }
    }

    private func openListener(usePreferredPort: Bool = true) {
        let requestedPort = usePreferredPort ? preferredPort ?? .any : .any
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: requestedPort)
            let server = try makeListener(parameters, requestedPort)
            listener = server
            let pool = tunnels
            let generation = UUID()
            pool.activate(generation)
            server.newConnectionHandler = { connection in pool.accept(connection, generation: generation) }
            server.stateUpdateHandler = { [weak self, weak server] state in
                MainActor.assumeIsolated {
                    guard let self, let server, self.listener === server else { return }
                    switch state {
                    case .ready:
                        guard let value = server.port else { return }
                        self.port = value.rawValue
                        self.preferredPort = value
                        self.startupTimeout?.cancel(); self.startupTimeout = nil
                        self.finishWaiters()
                    case .failed(let error):
                        if requestedPort != .any, error == .posix(.EADDRINUSE) {
                            self.listener = nil; self.port = nil; server.cancel()
                            self.openListener(usePreferredPort: false)
                        } else { self.invalidate(error) }
                    case .waiting(let error):
                        if self.port != nil { self.invalidate(error) }
                    case .cancelled: self.invalidate(NWError.posix(.ECANCELED))
                    case .setup: break
                    @unknown default: break
                    }
                }
            }
            startupTimeout?.cancel()
            startupTimeout = Task { [weak self, weak server] in
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                guard let self, let server, self.listener === server else { return }
                self.invalidate(NWError.posix(.ETIMEDOUT))
            }
            server.start(queue: .main)
        } catch {
            if requestedPort != .any, let error = error as? NWError, error == .posix(.EADDRINUSE) {
                openListener(usePreferredPort: false)
            } else { invalidate(error) }
        }
    }

    private func finishWaiters(_ error: Error? = nil) {
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending {
            if let error { waiter.resume(throwing: error) }
            else { waiter.resume() }
        }
    }

    private func invalidate(_ error: Error) {
        let previous = listener
        listener = nil; port = nil
        startupTimeout?.cancel(); startupTimeout = nil
        tunnels.activate(nil)
        previous?.cancel()
        finishWaiters(error)
    }

    private var proxyConfigurations: [ProxyConfiguration] {
        guard !deployment.connectOverrides.isEmpty, let port, let value = NWEndpoint.Port(rawValue: port) else { return [] }
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: value), tlsOptions: nil)
        proxy.matchDomains = deployment.connectOverrides.keys.sorted()
        proxy.allowFailover = true
        return [proxy]
    }

    func configure(_ configuration: URLSessionConfiguration) {
        configuration.proxyConfigurations = proxyConfigurations
    }
    func configure(_ store: WKWebsiteDataStore) {
        store.proxyConfigurations = proxyConfigurations
    }
}

private final class TunnelPool {
    private let queue = DispatchQueue(label: "xyz.loibaks.animesync.tunnels")
    private let overrides: [String: String]
    private let limit: Int
    private var generation: UUID?
    private var connections: [UUID: ConnectTunnel] = [:]
    init(overrides: [String: String], limit: Int) { self.overrides = overrides; self.limit = limit }
    func activate(_ generation: UUID?) {
        queue.async {
            self.generation = generation
            self.cancelConnections()
        }
    }
    func accept(_ connection: NWConnection, generation: UUID) {
        queue.async {
            guard self.generation == generation, self.connections.count < self.limit else { connection.cancel(); return }
            let id = UUID()
            let tunnel = ConnectTunnel(client: connection, queue: self.queue, overrides: self.overrides) { [weak self] in self?.connections.removeValue(forKey: id) }
            self.connections[id] = tunnel; tunnel.start()
        }
    }
    func reset() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.cancelConnections()
                continuation.resume()
            }
        }
    }
    func prune() async {
        await withCheckedContinuation { continuation in
            queue.async {
                for connection in Array(self.connections.values) where connection.expired { connection.cancel() }
                continuation.resume()
            }
        }
    }
    private func cancelConnections() {
        let previous = Array(connections.values)
        connections.removeAll()
        previous.forEach { $0.cancel() }
    }
}

private final class ConnectTunnel {
    private let client: NWConnection
    private var upstream: NWConnection?
    private let queue: DispatchQueue
    private let overrides: [String: String]
    private let finished: () -> Void
    private var buffer = Data()
    private var closed = false
    private var ended = 0
    private let started = Date()
    private var lastActivity = Date()
    private var timer: DispatchSourceTimer?
    private var connectDeadline: DispatchWorkItem?
    var expired: Bool {
        let now = Date()
        return (connectDeadline != nil && now.timeIntervalSince(started) >= 3) || now.timeIntervalSince(lastActivity) > 90
    }
    init(client: NWConnection, queue: DispatchQueue, overrides: [String: String], finished: @escaping () -> Void) { self.client = client; self.queue = queue; self.overrides = overrides; self.finished = finished }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in guard let self, self.expired else { return }; self.finish() }
        self.timer = timer; timer.resume()
        let deadline = DispatchWorkItem { [weak self] in self?.finish() }
        connectDeadline = deadline
        queue.asyncAfter(deadline: .now() + 3, execute: deadline)
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
            guard let host = self.overrides[target.host] else { self.finish(); return }
            guard let port = NWEndpoint.Port(rawValue: target.port) else { self.finish(); return }
            let upstream = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            self.upstream = upstream
            upstream.stateUpdateHandler = { [weak self] state in
                guard let self, !self.closed else { return }
                switch state {
                case .ready:
                    self.connectDeadline?.cancel(); self.connectDeadline = nil
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
        connectDeadline?.cancel(); connectDeadline = nil
        timer?.cancel(); timer = nil; client.cancel(); upstream?.cancel(); finished()
    }
    func cancel() { finish() }
}
