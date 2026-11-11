import Foundation
import Network
import WebKit
import XCTest
@testable import AnimeSync

@MainActor final class NetworkRoutingTests: XCTestCase {
    private final class SocketClose {
        let expectation: XCTestExpectation
        var occurred = false
        init(_ expectation: XCTestExpectation) { self.expectation = expectation }
    }

    private func deployment() throws -> AppConfiguration {
        try AppConfiguration.decode(Data(#"{"homeURL":"https://home.example","tailnetURL":"https://tailnet.example:8443","connectOverrides":{"home.example":"192.168.254.1"}}"#.utf8))
    }

    private func waitForInvalidation(_ routing: AppNetworkRouting) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while routing.port != nil && clock.now < deadline {
            try await clock.sleep(until: clock.now.advanced(by: .milliseconds(20)))
        }
        XCTAssertNil(routing.port)
    }

    private func client(port: UInt16) async throws -> NWConnection {
        let endpoint = try XCTUnwrap(NWEndpoint.Port(rawValue: port))
        let connection = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
        let ready = expectation(description: "Loopback connection ready")
        connection.stateUpdateHandler = { [weak connection] state in
            guard case .ready = state else { return }
            connection?.stateUpdateHandler = nil
            ready.fulfill()
        }
        connection.start(queue: .main)
        await fulfillment(of: [ready], timeout: 2)
        return connection
    }

    private func observeClose(_ client: NWConnection) -> SocketClose {
        let closed = SocketClose(expectation(description: "Loopback connection closed"))
        client.receive(minimumIncompleteLength: 1, maximumLength: 512) { _, _, complete, error in
            guard complete || error != nil else { return }
            Task { @MainActor in closed.occurred = true; closed.expectation.fulfill() }
        }
        return closed
    }

    func testScopedProxyPreservesDirectTrafficAndAllowsSystemFailover() async throws {
        var listeners: [NWListener] = []
        let routing = AppNetworkRouting(configuration: try deployment(), listenerFactory: { parameters, port in
            let listener = try NWListener(using: parameters, on: port)
            listeners.append(listener)
            return listener
        })
        defer { listeners.forEach { $0.cancel() } }
        let session = URLSessionConfiguration.ephemeral
        let store = WKWebsiteDataStore.nonPersistent()
        try await routing.start()
        routing.configure(session)
        routing.configure(store)
        XCTAssertEqual(session.proxyConfigurations.count, 1)
        XCTAssertEqual(store.proxyConfigurations.count, 1)
        for proxy in session.proxyConfigurations + store.proxyConfigurations {
            XCTAssertEqual(proxy.matchDomains, ["home.example"])
            XCTAssertTrue(proxy.allowFailover)
        }

        let direct = AppNetworkRouting(configuration: .generic, listenerFactory: { _, _ in
            XCTFail("A deployment without routing overrides needs no listener")
            throw NWError.posix(.EINVAL)
        })
        try await direct.start()
        direct.configure(session)
        direct.configure(store)
        XCTAssertTrue(session.proxyConfigurations.isEmpty)
        XCTAssertTrue(store.proxyConfigurations.isEmpty)
    }

    func testCancelledListenerRecoversAndIgnoresLateStateFromOldListener() async throws {
        var listeners: [NWListener] = []
        var requestedPorts: [UInt16] = []
        let routing = AppNetworkRouting(configuration: try deployment(), listenerFactory: { parameters, port in
            let listener = try NWListener(using: parameters, on: port)
            listeners.append(listener)
            requestedPorts.append(port.rawValue)
            return listener
        })
        defer { listeners.forEach { $0.cancel() } }
        try await routing.start()
        let firstPort = try XCTUnwrap(routing.port)
        let first = try XCTUnwrap(listeners.first)
        let lateCallback = try XCTUnwrap(first.stateUpdateHandler)
        first.cancel()
        try await waitForInvalidation(routing)
        try await routing.recover()
        let replacementPort = try XCTUnwrap(routing.port)
        XCTAssertEqual(requestedPorts.dropFirst().first, firstPort)
        let replacementCount = listeners.count
        XCTAssertGreaterThan(replacementCount, 1)

        lateCallback(.failed(.posix(.ECANCELED)))
        try await routing.recover()
        XCTAssertEqual(listeners.count, replacementCount, "A healthy listener should survive repeated recovery")
        XCTAssertEqual(routing.port, replacementPort)
        let connection = try await client(port: replacementPort)
        connection.cancel()
    }

    func testResetClosesExistingSocketsAndMakesCapacityAvailableAgain() async throws {
        var listener: NWListener?
        let routing = AppNetworkRouting(configuration: try deployment(), listenerFactory: { parameters, port in
            let server = try NWListener(using: parameters, on: port)
            listener = server
            return server
        }, connectionLimit: 1)
        defer { listener?.cancel() }
        try await routing.start()
        let port = try XCTUnwrap(routing.port)
        let first = try await client(port: port)
        defer { first.cancel() }
        // Leave a CONNECT header incomplete so it occupies the tunnel without
        // making any external request.
        first.send(content: Data("CONNECT ".utf8), completion: .contentProcessed { _ in })
        let firstClosed = observeClose(first)
        try await Task.sleep(nanoseconds: 100_000_000)
        await routing.resetConnections()
        await fulfillment(of: [firstClosed.expectation], timeout: 1)

        let next = try await client(port: port)
        defer { next.cancel() }
        let nextClosed = observeClose(next)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(nextClosed.occurred, "The new socket must remain open after the pool is drained")
        // An unconfigured domain must be rejected before any upstream dial.
        next.send(content: Data("CONNECT direct.example:443 HTTP/1.1\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        await fulfillment(of: [nextClosed.expectation], timeout: 1)
        XCTAssertEqual(routing.port, port)
    }

    func testIncompleteConnectClosesAtBoundedDeadline() async throws {
        var listener: NWListener?
        let routing = AppNetworkRouting(configuration: try deployment(), listenerFactory: { parameters, port in
            let server = try NWListener(using: parameters, on: port)
            listener = server
            return server
        })
        defer { listener?.cancel() }
        try await routing.start()
        let connection = try await client(port: XCTUnwrap(routing.port))
        defer { connection.cancel() }
        connection.send(content: Data("CONNECT ".utf8), completion: .contentProcessed { _ in })
        let closed = observeClose(connection)
        await fulfillment(of: [closed.expectation], timeout: 4)
    }
}
