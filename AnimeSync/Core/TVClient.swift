import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

@MainActor final class TVClient: ObservableObject {
    static let controlChanged = "TV control changed. Tap the action again."
    @Published private(set) var state: TVState
    @Published private(set) var pairing = false
    private let transport: HTTPTransport
    private let secrets: CoreSecrets
    private let queue = AsyncOperationQueue()
    private var token = ""
    private var host = AppConfiguration.current.defaultTVHost
    private var last: JSONObject = [:]
    private var connectionEpoch: UInt64 = 0
    private var pairingSequence: UInt64 = 0
    private var polling: Task<Void, Never>?
    private let deviceName: String
    private struct PairRecord: Codable { let host: String; let token: String }

    init(transport: HTTPTransport? = nil, secrets: CoreSecrets = KeychainSecrets(), deviceName: String? = nil) {
        #if canImport(UIKit)
        let defaultDeviceName = UIDevice.current.model
        #else
        let defaultDeviceName = "Mac QA"
        #endif
        let direct = URLSessionConfiguration.ephemeral
        direct.connectionProxyDictionary = [:]
        self.transport = transport ?? CoreHTTPTransport(configuration: direct)
        self.secrets = secrets; self.deviceName = String((deviceName ?? defaultDeviceName).prefix(80))
        if let saved = try? secrets.read("tv.pairing"), let record = try? JSONDecoder().decode(PairRecord.self, from: saved),
           let valid = try? TVAddress.host(record.host), Self.validToken(record.token) { host = valid; token = record.token }
        state = TVState(); publish(online: false, message: token.isEmpty ? "Connect TV" : "Checking TV…")
    }
    private static func validToken(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9_-]{20,256}\\z", options: .regularExpression) != nil }
    private func publish(online: Bool, message: String) {
        var next = TVState(); next.host = host; next.paired = !token.isEmpty; next.online = online; next.message = message; next.connection = connectionEpoch
        next.title = last["title"]?.string ?? "Anime Sync TV"; next.episode = last["episode"]?.string ?? ""
        next.watchURL = last["watch_url"]?.string.flatMap(URL.init(string:)).flatMap { AppWebPolicy.isProvider($0) ? $0 : nil }
        next.posterURL = last["poster_url"]?.string.flatMap(URL.init(string:)).flatMap { AppWebPolicy.isMediaOrigin($0) ? $0 : nil }
        next.playing = last["playing"]?.bool ?? false
        let position = last["position"]?.double ?? 0, duration = last["duration"]?.double ?? 0
        next.position = position.isFinite ? max(0, position) : 0; next.duration = duration.isFinite ? max(0, duration) : 0
        next.capabilities = Set(last["capabilities"]?.array?.compactMap(\.string) ?? [])
        next.handoffGeneration = last["handoff_generation"]?.integer
        next.handoffSaved = last["handoff_saved"]?.bool == true
        if let control = last["control"]?.object, next.capabilities.contains("exclusive_control"), control["supported"]?.bool == true,
           let available = control["available"]?.bool, let mine = control["mine"]?.bool, let revision = control["revision"]?.integer {
            next.control = TVControlSnapshot(supported: true, available: available, mine: mine, ownerName: control["owner_name"]?.string ?? "", revision: revision)
        }
        if state != next { state = next }
    }
    private func merge(_ response: JSONObject) {
        if response["control"] == nil { last.removeValue(forKey: "control") }
        if response["capabilities"] == nil { last.removeValue(forKey: "capabilities") }
        response.forEach { last[$0.key] = $0.value }
    }
    private func request(host: String, token: String, path: String, body: JSONObject?) async throws -> (HTTPReply, JSONObject) {
        guard ["/status", "/pair", "/command"].contains(path) else { throw CoreError.invalidResponse }
        let base = try TVAddress.base(host)
        var request = URLRequest(url: base.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.timeoutInterval = body?["command"]?.string == "handoff" ? 9 : 3
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body = body { request.httpBody = try JSONEncoder().encode(body) }
        let reply = try await transport.request(request, maxBytes: 128_000)
        let json: JSONObject
        if (200..<300).contains(reply.status) { json = try JSONValue.parseObject(reply.body) }
        else { json = (try? JSONValue.parseObject(reply.body)) ?? [:] }
        return (reply, json)
    }
    private func call(_ path: String, body: JSONObject? = nil, epoch: UInt64) async throws -> JSONObject {
        guard epoch == connectionEpoch, !token.isEmpty else { throw CoreError.conflict(Self.controlChanged) }
        let response = try await request(host: host, token: token, path: path, body: body)
        try Task.checkCancellation()
        guard epoch == connectionEpoch else { throw CoreError.conflict(Self.controlChanged) }
        let (reply, json) = response
        if reply.status == 401 {
            connectionEpoch &+= 1; token = ""; try? secrets.write(nil, for: "tv.pairing")
            publish(online: false, message: "Pair with the TV again")
            throw CoreError.message(json["error"]?.string ?? "Pair with the TV again")
        }
        if reply.status == 409 { merge(json); publish(online: true, message: json["error"]?.string ?? Self.controlChanged); throw CoreError.conflict(json["error"]?.string ?? Self.controlChanged) }
        guard (200..<300).contains(reply.status) else { throw CoreError.message(json["error"]?.string ?? "TV unavailable") }
        return json
    }
    func startPolling() {
        guard polling == nil else { return }
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                await self.refresh()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }
    func stopPolling() {
        polling?.cancel(); polling = nil; connectionEpoch &+= 1; cancelPairing()
        publish(online: state.online, message: state.message)
    }
    func refresh() async {
        guard !token.isEmpty else { return }; let epoch = connectionEpoch
        do { try await queue.run { [self] in
            let response = try await call("/status", epoch: epoch)
            guard epoch == connectionEpoch else { return }; last = response; publish(online: true, message: "Connected to TV")
        }} catch is CancellationError { } catch {
            if epoch == connectionEpoch { publish(online: false, message: "TV unavailable. Open Anime Sync TV and check the connection.") }
        }
    }
    func beginPairing(address: String, pin: String) async throws {
        cancelPairing(); let ticket = pairingSequence
        let checked = try TVAddress.host(address)
        guard pin.range(of: "^[0-9]{6}\\z", options: .regularExpression) != nil else { throw CoreError.message("Enter the six-digit code shown on your TV") }
        pairing = true
        defer { if ticket == pairingSequence { pairing = false } }
        try await queue.run { [self] in
            guard ticket == pairingSequence else { throw CancellationError() }
            let existing = checked == host ? token : ""
            let (reply, data) = try await request(host: checked, token: existing, path: "/pair", body: ["pin": .string(pin), "name": .string(deviceName)])
            try Task.checkCancellation(); guard ticket == pairingSequence else { throw CancellationError() }
            guard (200..<300).contains(reply.status) else { throw CoreError.message(data["error"]?.string ?? "Pairing failed") }
            guard let next = data["token"]?.string, Self.validToken(next) else { throw CoreError.invalidResponse }
            let (statusReply, status) = try await request(host: checked, token: next, path: "/status", body: nil)
            try Task.checkCancellation(); guard ticket == pairingSequence else { throw CancellationError() }
            guard statusReply.status == 200 else { throw CoreError.message(status["error"]?.string ?? "TV unavailable") }
            try secrets.write(JSONEncoder().encode(PairRecord(host: checked, token: next)), for: "tv.pairing")
            host = checked; token = next; connectionEpoch &+= 1; last = status; publish(online: true, message: "Connected to TV")
        }
    }
    func cancelPairing() { pairingSequence &+= 1; pairing = false }
    func observation(_ observed: TVState) throws -> TVControlLease {
        guard observed.control.supported else { throw CoreError.message("Update Anime Sync TV to use TV controls") }
        return TVControlLease(connection: observed.connection, revision: observed.control.revision)
    }
    func sameObservation(_ lease: TVControlLease) -> Bool {
        state.paired && state.online && state.connection == connectionEpoch && lease.connection == connectionEpoch && state.control.supported && lease.revision == state.control.revision
    }
    func isCurrent(_ lease: TVControlLease) -> Bool { sameObservation(lease) && state.control.mine && !state.control.available }
    var currentLease: TVControlLease? {
        guard let lease = try? observation(state), isCurrent(lease) else { return nil }; return lease
    }
    func acquire(observed: TVState, takeover: Bool) async throws -> TVControlLease {
        let expected = try observation(observed)
        return try await queue.run { [self] in
            guard sameObservation(expected) else { throw CoreError.conflict(Self.controlChanged) }
            let response = try await call("/command", body: ["command": .string(takeover ? "control_takeover" : "control_claim"), "expected_control_revision": .integer(expected.revision)], epoch: expected.connection)
            merge(response); publish(online: true, message: "Connected to TV")
            let revision = state.control.revision
            let revisionMatches = observed.control.mine ? revision == expected.revision : expected.revision < Int64.max && revision == expected.revision + 1
            let lease = TVControlLease(connection: expected.connection, revision: revision)
            guard revisionMatches, isCurrent(lease) else { throw CoreError.conflict(Self.controlChanged) }
            return lease
        }
    }
    func validate(_ lease: TVControlLease) async throws {
        try await queue.run { [self] in
            guard isCurrent(lease) else { throw CoreError.conflict(Self.controlChanged) }
            last = try await call("/status", epoch: lease.connection); publish(online: true, message: "Connected to TV")
            guard isCurrent(lease) else { throw CoreError.conflict(Self.controlChanged) }
        }
    }
    func command(_ name: String, payload: JSONObject = [:], lease supplied: TVControlLease? = nil) async throws -> TVState {
        guard !["control_claim", "control_takeover", "control_release"].contains(name) else { throw CoreError.message("Use explicit TV control confirmation") }
        guard let lease = supplied ?? currentLease else { throw CoreError.message("Take control of the TV first") }
        var body = payload; body["command"] = .string(name); body["control_revision"] = .integer(lease.revision)
        return try await queue.run { [self] in
            guard isCurrent(lease) else { throw CoreError.conflict(Self.controlChanged) }
            if name == "load" && !state.canLoad { throw CoreError.message("Update Anime Sync TV to enable Play on TV") }
            let response = try await call("/command", body: body, epoch: lease.connection)
            merge(response); publish(online: true, message: "Connected to TV"); let reply = state
            guard isCurrent(lease) else { throw CoreError.conflict(Self.controlChanged) }
            if name == "handoff" {
                last = try await call("/status", epoch: lease.connection); publish(online: true, message: "Connected to TV")
                guard isCurrent(lease) else { throw CoreError.conflict(Self.controlChanged) }
            }
            return reply
        }
    }
    func load(url: URL, position: TimeInterval? = nil, generation: Int64? = nil, lease: TVControlLease? = nil) async throws {
        guard AppWebPolicy.isProvider(url) else { throw CoreError.invalidMetadata }
        var body: JSONObject = ["url": .string(url.absoluteString)]
        if let position = position {
            guard position.isFinite, position >= 0, position <= 31_536_000 else { throw CoreError.invalidMetadata }
            body["position"] = .number(position)
            if let generation = generation { guard generation >= 0, generation <= 9_007_199_254_740_991 else { throw CoreError.invalidMetadata }; body["source_generation"] = .integer(generation) }
        }
        _ = try await command("load", payload: body, lease: lease)
    }
    func disconnect() async {
        let previous = state, previousHost = host, previousToken = token
        polling?.cancel(); polling = nil; cancelPairing(); connectionEpoch &+= 1; token = ""; last = [:]
        try? secrets.write(nil, for: "tv.pairing"); publish(online: false, message: "Connect TV")
        guard !previousToken.isEmpty, previous.control.supported, previous.control.mine else { return }
        _ = try? await queue.run { [self] in
            try await request(host: previousHost, token: previousToken, path: "/command", body: ["command": .string("control_release"), "expected_control_revision": .integer(previous.control.revision)])
        }
    }
}
