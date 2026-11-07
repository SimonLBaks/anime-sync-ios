import XCTest
import Foundation
@testable import AnimeSync

@MainActor private final class MemorySecrets: CoreSecrets {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func write(_ data: Data?, for key: String) throws { values[key] = data }
}
private final class FixturePreferences {
    let name = "qa-ios-protocol-" + UUID().uuidString
    let defaults: UserDefaults
    init() { defaults = UserDefaults(suiteName: name)! }
    deinit { defaults.removePersistentDomain(forName: name) }
}
@MainActor private final class FakeHTTP: HTTPTransport {
    var requests: [URLRequest] = []
    var respond: ((URLRequest) async throws -> HTTPReply)!
    func request(_ request: URLRequest, maxBytes: Int) async throws -> HTTPReply {
        requests.append(request); let reply = try await respond(request)
        if reply.body.count > maxBytes { throw CoreError.responseTooLarge }; return reply
    }
}
@MainActor private final class Gate {
    let started: XCTestExpectation
    var continuation: CheckedContinuation<Void, Never>?
    init(_ started: XCTestExpectation) { self.started = started }
    func wait() async { await withCheckedContinuation { continuation = $0; started.fulfill() } }
    func open() { continuation?.resume(); continuation = nil }
}

@MainActor final class ProtocolTests: XCTestCase {
    private let token = "as-session-v1.fixture_not_a_real_secret_12345"
    private let tvToken = "fixture_tv_token_12345678901234567890"
    private var metadata: AnimeMetadata { AnimeMetadata(animeID: "21", episode: "6", title: "One Piece", watchURL: URL(string: "https://miruro.cx/watch/fixture/one-piece?ep=6")!) }
    private func reply(_ object: JSONObject, status: Int = 200) throws -> HTTPReply { HTTPReply(status: status, body: try JSONEncoder().encode(object)) }
    private func body(_ request: URLRequest) throws -> JSONObject { try JSONValue.parseObject(XCTUnwrap(request.httpBody)) }
    private func head(generation: Int64 = 7, position: Double = 200, completed: Bool = false, session: String = "") -> JSONObject {
        ["sync": .object(["generation": .integer(generation), "session_id": .string(session)]),
         "progress": .object(["current_time": .number(position), "duration": .number(1000), "completed": .bool(completed)])]
    }
    private func tvState(revision: Int64 = 1, mine: Bool = false, available: Bool = true) -> JSONObject {
        ["capabilities": .array([.string("exclusive_control"), .string("load"), .string("handoff")]),
         "control": .object(["supported": .bool(true), "available": .bool(available), "mine": .bool(mine), "owner_name": .string(mine ? "iPhone" : "Tablet"), "revision": .integer(revision)]),
         "title": .string("Fixture"), "watch_url": .string("https://miruro.cx/watch/fixture/one-piece?ep=6"), "episode": .string("6")]
    }
    private func sync(_ http: FakeHTTP, _ preferences: FixturePreferences, authenticated: Bool = true) throws -> (SyncService, MemorySecrets) {
        let secrets = MemorySecrets()
        if authenticated { secrets.values["sync.session"] = try JSONEncoder().encode(["origin": .string(AppWebPolicy.home.absoluteString), "token": .string(token), "deviceID": .string("ios-companion-fixture")] as JSONObject) }
        return (SyncService(transport: http, secrets: secrets, preferences: preferences.defaults), secrets)
    }
    private func existingTV(_ http: FakeHTTP) throws -> TVClient {
        let secrets = MemorySecrets(); secrets.values["tv.pairing"] = try JSONEncoder().encode(["host": "10.0.0.20", "token": tvToken])
        return TVClient(transport: http, secrets: secrets, deviceName: "Fixture iPhone")
    }
    func testHeaderPolicyRejectsCRLFGraphemesAndControlScalars() async {
        XCTAssertTrue(CoreHTTPTransport.isSafeHeaderValue("Bearer fixture-token"))
        XCTAssertTrue(CoreHTTPTransport.isSafeHeaderValue("fixture_cookie=fixture-value"))
        for control in ["\r", "\n", "\r\n", "\u{0000}", "\t"] {
            XCTAssertFalse(CoreHTTPTransport.isSafeHeaderValue("before" + control + "after"))
        }
    }
    func testTVAddressNeverAcceptsPublicRedirectUserInfoOrNonNumericHost() async throws {
        for value in ["10.0.0.20", "10.2.3.4", "http://172.22.1.8:8765/"] { XCTAssertNoThrow(try TVAddress.host(value)) }
        for value in ["8.8.8.8", "100.64.0.43", "localhost", "192.168.01.8", "https://10.0.0.20", "http://user@10.0.0.20", "http://10.0.0.20:80", "10.0.0.20?x=1", "10.0.0.20/#x", "http://10.0.0.20.evil.test"] { XCTAssertThrowsError(try TVAddress.host(value), value) }
    }
    func testStrictIdentityPINAndStoredTokensRejectFinalLineTerminators() async throws {
        for suffix in ["\n", "\r\n"] {
            XCTAssertFalse(AppWebPolicy.identity(animeID: "21" + suffix, episode: "6"))
            XCTAssertFalse(AppWebPolicy.identity(animeID: "21", episode: "6" + suffix))
            let http = FakeHTTP(), secrets = MemorySecrets()
            http.respond = { _ in XCTFail("Malformed PIN or stored credentials reached transport"); return try self.reply([:]) }
            secrets.values["tv.pairing"] = try JSONEncoder().encode(["host": "10.0.0.20", "token": tvToken + suffix])
            let tv = TVClient(transport: http, secrets: secrets, deviceName: "Fixture")
            XCTAssertFalse(tv.state.paired)
            do { try await tv.beginPairing(address: "10.0.0.20", pin: "123456" + suffix); XCTFail("Malformed PIN accepted") } catch { }
            let preferences = FixturePreferences()
            secrets.values["sync.session"] = try JSONEncoder().encode(["origin": .string(AppWebPolicy.home.absoluteString), "token": .string(token + suffix), "deviceID": .string("ios-companion-fixture")] as JSONObject)
            let sync = SyncService(transport: http, secrets: secrets, preferences: preferences.defaults)
            XCTAssertFalse(sync.isSignedIn); XCTAssertTrue(http.requests.isEmpty)
        }
    }
    func testStrictControlWireTypesRejectFloatExponentBoolNegativeAndImpossibleFlags() async throws {
        let http = FakeHTTP(), client = try existingTV(http)
        for value in ["1.0", "1e0", "true", "-1"] {
            http.respond = { _ in HTTPReply(status: 200, body: Data("{\"capabilities\":[\"exclusive_control\"],\"control\":{\"supported\":true,\"available\":true,\"mine\":false,\"revision\":\(value)}}".utf8)) }
            await client.refresh(); XCTAssertFalse(client.state.control.supported, value)
        }
        http.respond = { _ in try self.reply(self.tvState(revision: 1, mine: true, available: true)) }
        await client.refresh(); XCTAssertFalse(client.state.control.supported)
        http.respond = { _ in try self.reply(self.tvState()) }; await client.refresh(); XCTAssertTrue(client.state.control.supported)
    }
    func testPairingAndPollingNeverClaimTVControl() async throws {
        let http = FakeHTTP(), secrets = MemorySecrets()
        http.respond = { request in
            if request.url?.path == "/pair" { XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); return try self.reply(["token": .string(self.tvToken)]) }
            XCTAssertEqual(request.url?.path, "/status"); return try self.reply(self.tvState())
        }
        let client = TVClient(transport: http, secrets: secrets, deviceName: "Fixture")
        try await client.beginPairing(address: "10.0.0.20", pin: "123456"); await client.refresh()
        XCTAssertTrue(client.state.paired); XCTAssertTrue(client.state.control.available); XCTAssertFalse(client.state.control.mine)
        XCTAssertEqual(http.requests.filter { $0.url?.path == "/command" }.count, 0)
    }
    func testCanceledPairResponseCannotPersistOrFetchStatus() async throws {
        let http = FakeHTTP(), secrets = MemorySecrets(), gate = Gate(expectation(description: "pair reached transport"))
        http.respond = { request in XCTAssertEqual(request.url?.path, "/pair"); await gate.wait(); return try self.reply(["token": .string(self.tvToken)]) }
        let client = TVClient(transport: http, secrets: secrets, deviceName: "Fixture")
        let pairing = Task { try await client.beginPairing(address: "10.0.0.20", pin: "123456") }
        await fulfillment(of: [gate.started], timeout: 2); client.cancelPairing(); gate.open()
        do { try await pairing.value; XCTFail("Canceled pairing committed") } catch { }
        XCTAssertFalse(client.state.paired); XCTAssertTrue(secrets.values.isEmpty); XCTAssertEqual(http.requests.count, 1)
    }
    func testCanceledPairWaitingInQueueNeverSendsPairRequest() async throws {
        let http = FakeHTTP(), gate = Gate(expectation(description: "status blocks queue"))
        http.respond = { request in XCTAssertEqual(request.url?.path, "/status"); await gate.wait(); return try self.reply(self.tvState()) }
        let client = try existingTV(http)
        let status = Task { await client.refresh() }
        await fulfillment(of: [gate.started], timeout: 2)
        let pairing = Task { try await client.beginPairing(address: "192.168.1.79", pin: "123456") }
        await Task.yield(); client.cancelPairing(); gate.open(); await status.value
        do { try await pairing.value; XCTFail("Canceled queued pairing committed") } catch { }
        XCTAssertEqual(http.requests.count, 1); XCTAssertEqual(client.state.host, "10.0.0.20"); XCTAssertTrue(client.state.paired)
    }
    func testCanceledPairDuringStatusCannotReplaceSavedConnection() async throws {
        let http = FakeHTTP(), secrets = MemorySecrets(), gate = Gate(expectation(description: "status reached transport"))
        http.respond = { request in
            if request.url?.path == "/pair" { return try self.reply(["token": .string(self.tvToken)]) }
            await gate.wait(); return try self.reply(self.tvState())
        }
        let client = TVClient(transport: http, secrets: secrets, deviceName: "Fixture")
        let pairing = Task { try await client.beginPairing(address: "10.0.0.20", pin: "123456") }
        await fulfillment(of: [gate.started], timeout: 2); client.cancelPairing(); gate.open()
        do { try await pairing.value; XCTFail("Canceled status committed") } catch { }
        XCTAssertFalse(client.state.paired); XCTAssertTrue(secrets.values.isEmpty); XCTAssertEqual(http.requests.count, 2)
    }
    func testControlABAAndStaleTakeoverNeverBorrowNewRevision() async throws {
        let http = FakeHTTP(); var statusReads = 0
        http.respond = { request in
            if request.url?.path == "/status" { statusReads += 1; return try self.reply(self.tvState(revision: statusReads == 1 ? 1 : 4, mine: statusReads > 1, available: statusReads == 1)) }
            XCTAssertEqual(try self.body(request)["command"]?.string, "control_claim"); return try self.reply(self.tvState(revision: 2, mine: true, available: false))
        }
        let client = try existingTV(http); await client.refresh(); let observed = client.state
        let lease = try await client.acquire(observed: observed, takeover: false); XCTAssertEqual(lease.revision, 2)
        await client.refresh(); XCTAssertEqual(client.state.control.revision, 4)
        do { _ = try await client.command("toggle", lease: lease); XCTFail("Old ownership period authorized") } catch { }
        do { _ = try await client.acquire(observed: observed, takeover: true); XCTFail("Stale prompt authorized") } catch { }
        XCTAssertEqual(http.requests.filter { $0.url?.path == "/command" }.count, 1)
    }
    func testCanceledQueuedTVCommandIsNotSentOrRetried() async throws {
        let http = FakeHTTP(), gate = Gate(expectation(description: "first command in flight"))
        http.respond = { request in
            if request.url?.path == "/status" { return try self.reply(self.tvState(revision: 2, mine: true, available: false)) }
            XCTAssertEqual(try self.body(request)["command"]?.string, "pause"); await gate.wait(); return try self.reply(self.tvState(revision: 2, mine: true, available: false))
        }
        let client = try existingTV(http); await client.refresh(); let lease = try XCTUnwrap(client.currentLease)
        let first = Task { try await client.command("pause", lease: lease) }
        await fulfillment(of: [gate.started], timeout: 2)
        let second = Task { try await client.command("play", lease: lease) }; await Task.yield(); second.cancel(); gate.open()
        _ = try await first.value
        do { _ = try await second.value; XCTFail("Canceled queued command sent") } catch { }
        XCTAssertEqual(http.requests.filter { $0.url?.path == "/command" }.count, 1)
    }
    func testTVTimeoutSendsMutableCommandOnlyOnce() async throws {
        let http = FakeHTTP()
        http.respond = { request in if request.url?.path == "/status" { return try self.reply(self.tvState(revision: 2, mine: true, available: false)) }; throw URLError(.timedOut) }
        let client = try existingTV(http); await client.refresh(); let lease = try XCTUnwrap(client.currentLease)
        do { _ = try await client.command("toggle", lease: lease); XCTFail("Expected timeout") } catch { }
        XCTAssertEqual(http.requests.filter { $0.url?.path == "/command" }.count, 1)
    }
    func testContinueRequiresSuccessfulFreshFetchAndUsesExactIdentityWithoutCachedPosition() async throws {
        let preferences = FixturePreferences(), http = FakeHTTP(); let (service, _) = try sync(http, preferences)
        func progress(_ episode: String, _ position: Double) -> JSONObject { ["progress": .array([.object(["site": .string("miruro"), "anime_id": .string("21"), "episode": .string(episode), "title": .string("One Piece"), "current_time": .number(position), "duration": .number(1200), "completed": .bool(false), "updated_at": .string("2026-11-06T16:00:00Z")])])] }
        http.respond = { _ in try self.reply(progress("6", 200)) }; let refreshed = await service.refreshHistory(); XCTAssertTrue(refreshed)
        http.respond = { _ in throw URLError(.notConnectedToInternet) }; let offline = await service.freshContinue(animeID: "21"); XCTAssertNil(offline); XCTAssertEqual(service.history.continuing.first?.episode, "6")
        XCTAssertEqual(service.status, "Could not refresh history. Check your connection.")
        http.respond = { _ in try self.reply(progress("8", 900)) }; let fresh = await service.freshContinue(animeID: "21")
        XCTAssertEqual(fresh?.episode, "8"); XCTAssertEqual(fresh?.currentTime, 900); XCTAssertEqual(fresh?.resolverURL.fragment, "anime-sync-id=21&anime-sync-ep=8"); XCTAssertFalse(fresh?.resolverURL.absoluteString.contains("anime-sync-t") ?? true)
        XCTAssertEqual(service.status, "Synced with Anime Sync")
    }
    func testCanceledHistoryRefreshPreservesHistoryAndStatus() async throws {
        let preferences = FixturePreferences(), http = FakeHTTP(); let (service, _) = try sync(http, preferences)
        http.respond = { _ in try self.reply(["progress": .array([
            .object(["site": .string("miruro"), "anime_id": .string("21"), "episode": .string("6"), "title": .string("One Piece"), "current_time": .number(200), "duration": .number(1200), "completed": .bool(false), "updated_at": .string("2026-11-06T16:00:00Z")]),
            .object(["site": .string("miruro"), "anime_id": .string("00021"), "episode": .string("0002.000"), "title": .string("One Piece"), "current_time": .number(1200), "duration": .number(1200), "completed": .bool(true), "updated_at": .string("2026-11-06T15:00:00Z")])
        ])]) }
        let initial = await service.refreshHistory(); XCTAssertTrue(initial)
        let history = service.history, status = service.status, watched = service.watchedEpisodes
        XCTAssertFalse(history.recent.isEmpty)
        XCTAssertTrue(service.isEpisodeWatched(animeID: "21",episode: "2"))
        let gate = Gate(expectation(description: "history refresh reached transport"))
        http.respond = { _ in await gate.wait(); return try self.reply(["progress": .array([])]) }
        let refresh = Task { await service.refreshHistory() }
        await fulfillment(of: [gate.started], timeout: 2)
        refresh.cancel(); gate.open()
        let refreshed = await refresh.value
        XCTAssertFalse(refreshed); XCTAssertEqual(service.history, history); XCTAssertEqual(service.status, status); XCTAssertEqual(service.watchedEpisodes,watched)
        XCTAssertTrue(service.isSignedIn); XCTAssertEqual(http.requests.count, 2)
        let late = Gate(expectation(description: "old-account history reached transport"))
        http.respond = { _ in await late.wait(); return try self.reply(["progress": .array([])]) }
        let oldAccount = Task { await service.refreshHistory() }
        await fulfillment(of: [late.started],timeout: 2)
        try service.signOut(); late.open()
        let committed = await oldAccount.value
        XCTAssertFalse(committed); XCTAssertEqual(service.history,.empty); XCTAssertTrue(service.watchedEpisodes.isEmpty)
    }
    func testWatchedIndexUsesEveryCompletedEpisodeWithoutGuessingFromTheSeriesHead() async throws {
        let preferences = FixturePreferences(), http = FakeHTTP(); let (service, _) = try sync(http, preferences)
        func row(_ anime: String,_ episode: String,_ completed: Bool,_ time: String) -> JSONValue {
            .object(["site": .string("miruro"),"anime_id": .string(anime),"episode": .string(episode),"title": .string("Fixture anime"),"current_time": .number(completed ? 1200 : 200),"duration": .number(1200),"completed": .bool(completed),"updated_at": .string("2026-11-06T" + time + "Z")])
        }
        let rows: [JSONValue] = [row("00021","0001.000",true,"10:00:00"),row("21","2.500",true,"11:00:00"),row("21","3",false,"12:00:00"),row("22","2",true,"13:00:00"),row("21","9007199254740993",true,"14:00:00")]
        http.respond = { _ in try self.reply(["progress": .array(rows)]) }
        let loaded = await service.refreshHistory(); XCTAssertTrue(loaded)
        XCTAssertEqual(service.history.recent.count,2); XCTAssertEqual(service.watchedEpisodes.count,3)
        XCTAssertTrue(service.isEpisodeWatched(animeID: "21",episode: "1")); XCTAssertTrue(service.isEpisodeWatched(animeID: "00021",episode: "02.500"))
        XCTAssertFalse(service.isEpisodeWatched(animeID: "21",episode: "2")); XCTAssertFalse(service.isEpisodeWatched(animeID: "21",episode: "3"))
        XCTAssertTrue(service.isEpisodeWatched(animeID: "22",episode: "2")); XCTAssertFalse(service.isEpisodeWatched(site: "another-site",animeID: "21",episode: "1"))
        XCTAssertFalse(service.isEpisodeWatched(animeID: "21",episode: "9007199254740993"),"Out-of-protocol episode identities must not be rounded into a different key")
        XCTAssertEqual(service.episodeProgress(animeID: "00021",episode: "03.000"),200.0 / 1200)
        XCTAssertEqual(service.episodeProgress(animeID: "21",episode: "1"),1)
        XCTAssertNil(service.episodeProgress(animeID: "21",episode: "2"))
        let watched = service.watchedEpisodes
        http.respond = { _ in throw URLError(.notConnectedToInternet) }
        let offline = await service.refreshHistory(); XCTAssertFalse(offline); XCTAssertEqual(service.watchedEpisodes,watched)
        http.respond = { _ in try self.reply(["progress": .array([])]) }
        let empty = await service.refreshHistory(); XCTAssertTrue(empty); XCTAssertTrue(service.watchedEpisodes.isEmpty)
        XCTAssertNil(service.episodeProgress(animeID: "21",episode: "3"))
        XCTAssertEqual(http.requests.count,3); XCTAssertTrue(http.requests.allSatisfy { $0.httpMethod == "GET" },"One full history request supplies all markers without per-episode reads or writes")
    }
    func testWatchedIndexClearsOnSignOutServerChangeAndUnauthorizedResponse() async throws {
        for reset in ["sign-out","server","unauthorized"] {
            let preferences = FixturePreferences(), http = FakeHTTP(); let (service, _) = try sync(http, preferences)
            http.respond = { _ in try self.reply(["progress": .array([.object(["site": .string("miruro"),"anime_id": .string("21"),"episode": .string("1"),"completed": .bool(true)])])]) }
            let loaded = await service.refreshHistory(); XCTAssertTrue(loaded); XCTAssertTrue(service.isEpisodeWatched(animeID: "21",episode: "1"))
            if reset == "sign-out" { try service.signOut() }
            else if reset == "server" { try service.selectServer(AppWebPolicy.tailnet) }
            else { http.respond = { _ in try self.reply([:],status: 401) }; let refreshed = await service.refreshHistory(); XCTAssertFalse(refreshed) }
            XCTAssertFalse(service.isSignedIn); XCTAssertTrue(service.watchedEpisodes.isEmpty); XCTAssertEqual(service.history,.empty)
        }
    }
    func testLatestCompletedOrInvalidHistoryDoesNotResurrectAnOlderEpisode() async {
        let old = HistoryEntry(animeID: "00021", episode: "6.000", title: "One Piece", currentTime: 200, duration: 1200, completed: false, updatedAt: "2026-11-05T10:00:00Z")
        var newest = old; newest.animeID = "21"; newest.episode = "8"; newest.completed = true; newest.updatedAt = "2026-11-06T10:00:00Z"
        var selected = HomeHistory.select([old, newest]); XCTAssertTrue(selected.continuing.isEmpty); XCTAssertEqual(selected.recent.first?.episode, "8")
        newest.title = ""; selected = HomeHistory.select([old, newest]); XCTAssertTrue(selected.continuing.isEmpty); XCTAssertTrue(selected.recent.isEmpty)
    }
    func testPlaybackClaimsFreshGenerationThenWritesMonotonicProtocolTwoSamples() async throws {
        let preferences = FixturePreferences(), http = FakeHTTP(); let (service, _) = try sync(http, preferences)
        http.respond = { request in
            if request.httpMethod == "GET" { return try self.reply(self.head(generation: 7, position: 500)) }
            let payload = try self.body(request)
            if request.url?.path == "/api/playback" { XCTAssertEqual(payload["expected_generation"]?.integer, 7); XCTAssertEqual(payload["device_id"]?.string, service.deviceID); return try self.reply(self.head(generation: 8, position: 500)) }
            XCTAssertEqual(payload["sync_protocol"]?.integer, 2); XCTAssertEqual(payload["playback_generation"]?.integer, 8); return try self.reply(["ok": .bool(true)])
        }
        let started = try await service.begin(metadata: metadata, explicit: true); let lease = try XCTUnwrap(started.lease); XCTAssertEqual(started.resumePosition, 500)
        await service.progress(metadata: metadata, lease: lease, position: 520, duration: 1000); await service.progress(metadata: metadata, lease: lease, position: 530, duration: 1000)
        let writes = try http.requests.filter { $0.url?.path == "/api/progress" && $0.httpMethod == "POST" }.map(body)
        XCTAssertEqual(writes.map { $0["playback_sequence"]?.integer }, [1, 2]); XCTAssertTrue(writes.allSatisfy { $0["playback_session_id"]?.string == lease.id })
    }
    func testGenerationChangeDuringSourceDiscoveryAndUnsolicitedResumeDoNotClaim() async throws {
        let preferences = FixturePreferences(), http = FakeHTTP(); let (service, _) = try sync(http, preferences)
        http.respond = { _ in try self.reply(self.head(generation: 8, session: "another-player")) }
        let stale = try await service.begin(metadata: metadata, explicit: true, expectedSourceGeneration: 7); XCTAssertFalse(stale.allowed)
        let automatic = try await service.begin(metadata: metadata, explicit: false); XCTAssertFalse(automatic.allowed)
        XCTAssertEqual(http.requests.filter { $0.httpMethod == "POST" }.count, 0)
    }
    func testOfflinePendingSaveBlocksHandoffWithoutInvalidatingCurrentLease() async throws {
        let preferences = FixturePreferences(), http = FakeHTTP(); let (service, _) = try sync(http, preferences)
        http.respond = { request in try self.reply(self.head(generation: request.httpMethod == "GET" ? 1 : 2)) }
        let started = try await service.begin(metadata: metadata, explicit: true); let lease = try XCTUnwrap(started.lease)
        http.respond = { _ in throw URLError(.notConnectedToInternet) }
        await service.progress(metadata: metadata, lease: lease, position: 220, duration: 1000)
        let pendingStatus = service.status
        XCTAssertEqual(pendingStatus, "Progress saved here; retrying when connected")
        http.respond = { request in
            if request.httpMethod == "GET" { return try self.reply(["progress": .array([])]) }
            throw URLError(.notConnectedToInternet)
        }
        let refreshed = await service.refreshHistory(); XCTAssertTrue(refreshed)
        XCTAssertEqual(service.status, pendingStatus)
        let handoff = try await service.flushForHandoff(metadata: metadata, lease: lease); XCTAssertFalse(handoff.saved); XCTAssertTrue(lease.isValid)
        XCTAssertEqual(preferences.defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("animesync.pending:") }.count, 1)
    }
    func testConflictedSessionMovesToHeldAndDoesNotInvalidateDifferentAnimePlayer() async throws {
        let preferences = FixturePreferences(), http = FakeHTTP(); let (service, _) = try sync(http, preferences)
        http.respond = { request in try self.reply(self.head(generation: request.httpMethod == "GET" ? 1 : 2)) }
        let startA = try await service.begin(metadata: metadata, explicit: true); let a = try XCTUnwrap(startA.lease)
        var other = metadata; other.animeID = "22"; other.title = "Other"
        let startB = try await service.begin(metadata: other, explicit: true); let b = try XCTUnwrap(startB.lease)
        var invalidated: [String] = []; service.onOwnershipLost = { invalidated.append($0.id) }
        http.respond = { _ in try self.reply(["error": .string("newer owner")], status: 409) }
        await service.progress(metadata: metadata, lease: a, position: 220, duration: 1000)
        XCTAssertFalse(a.isValid); XCTAssertTrue(b.isValid); XCTAssertEqual(invalidated, [a.id])
        XCTAssertNotNil(preferences.defaults.data(forKey: "animesync.held:animesync.pending:" + a.id))
        XCTAssertNil(preferences.defaults.data(forKey: "animesync.pending:" + a.id))
        let handoff = try await service.flushForHandoff(metadata: metadata, lease: a); XCTAssertFalse(handoff.saved)
    }
    func testUnownedHandoffUsesRawCompletedCheckpointRatherThanResumeZero() async throws {
        let preferences = FixturePreferences(), http = FakeHTTP(); let (service, _) = try sync(http, preferences)
        http.respond = { _ in try self.reply(self.head(generation: 4, position: 1000, completed: true)) }
        let resume = try await service.resume(metadata: metadata); XCTAssertEqual(resume.position, 0)
        let handoff = try await service.flushForHandoff(metadata: metadata); XCTAssertTrue(handoff.saved); XCTAssertEqual(handoff.position, 1000); XCTAssertEqual(handoff.generation, 4)
    }
    func testUntrackedHeldProgressCannotBeTransferredAsAnAcceptedSave() async throws {
        let preferences = FixturePreferences(), http = FakeHTTP(); let (service, _) = try sync(http, preferences)
        http.respond = { _ in XCTFail("Held untracked sample must not be silently ignored"); return try self.reply([:]) }
        await service.progress(metadata: metadata, lease: nil, position: 100, duration: 1000)
        let handoff = try await service.flushForHandoff(metadata: metadata); XCTAssertFalse(handoff.saved); XCTAssertTrue(http.requests.isEmpty)
    }
    func testReleasedLeaseCannotSaveOrAuthorizeHandoffAfterSignOut() async throws {
        let preferences = FixturePreferences(), http = FakeHTTP(); let (service, _) = try sync(http, preferences)
        http.respond = { request in try self.reply(request.url?.path == "/api/playback" || request.httpMethod == "GET" ? self.head(generation: 1) : ["ok": .bool(true)]) }
        let start = try await service.begin(metadata: metadata, explicit: true); let lease = try XCTUnwrap(start.lease)
        await service.progress(metadata: metadata, lease: lease, position: 100, duration: 1000); service.release(lease); try service.signOut()
        let before = http.requests.count; await service.progress(metadata: metadata, lease: lease, position: 200, duration: 1000)
        let handoff = try await service.flushForHandoff(metadata: metadata, lease: lease); XCTAssertFalse(handoff.saved); XCTAssertEqual(http.requests.count, before)
    }
    #if DEBUG && !CORE_PROTOCOLS_ONLY
    func testUIFixtureHistoryIsSignedInDisposableAndDistinct() async {
        let fixture = QAFixture(arguments: ["--qa-fixture"]), sync = fixture.makeSync()
        XCTAssertTrue(sync.isSignedIn)
        let refreshed = await sync.refreshHistory(); XCTAssertTrue(refreshed)
        XCTAssertEqual(sync.history.recent.count, 10); XCTAssertEqual(Set(sync.history.recent.map(\.animeID)).count, 10)
        XCTAssertGreaterThanOrEqual(sync.history.continuing.count, 4); XCTAssertEqual(fixture.syncWriteCount, 0)
        let second = QAFixture(arguments: ["--qa-fixture"])
        XCTAssertFalse(second.preferences === fixture.preferences)
    }
    func testUIFixtureOccupiedTVControlOnlyDoesNotCountAsPlaybackMutation() async throws {
        let fixture = QAFixture(arguments: ["--qa-fixture", "--qa-tv-occupied"]), tv = fixture.makeTV()
        await tv.refresh(); XCTAssertTrue(tv.state.paired); XCTAssertFalse(tv.state.control.mine); XCTAssertFalse(tv.state.control.available)
        let observed = tv.state, before = fixture.commandCount
        XCTAssertEqual(before, 0)
        let lease = try await tv.acquire(observed: observed, takeover: true)
        XCTAssertTrue(tv.state.control.mine); XCTAssertEqual(fixture.commandCount, before)
        _ = try await tv.command("pause", lease: lease)
        XCTAssertEqual(fixture.commandCount, before + 1)
        await tv.disconnect(); XCTAssertEqual(fixture.commandCount, before + 1); XCTAssertEqual(fixture.syncWriteCount, 0)
    }
    func testUIFixtureUnpairedTVRequiresExplicitFixturePairing() async throws {
        let fixture = QAFixture(arguments: ["--qa-fixture", "--qa-tv-unpaired"]), tv = fixture.makeTV()
        XCTAssertFalse(tv.state.paired)
        do { try await tv.beginPairing(address: "10.0.0.20", pin: "111111"); XCTFail("Wrong fixture PIN accepted") } catch { }
        XCTAssertFalse(tv.state.paired)
        try await tv.beginPairing(address: "10.0.0.20", pin: QAFixture.pairingPIN)
        XCTAssertTrue(tv.state.paired); XCTAssertFalse(tv.state.control.mine); XCTAssertTrue(tv.state.control.available)
        XCTAssertEqual(fixture.commandCount, 0)
    }
    #endif
    func testDeviceSessionUsesTrustedDashboardCookieAndStableBoundDeviceID() async throws {
        let preferences = FixturePreferences(), http = FakeHTTP(); let (service, secrets) = try sync(http, preferences, authenticated: false)
        http.respond = { request in
            if request.url?.path == "/api/device-session" { XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("anime_sync_admin=fixture-cookie") == true); XCTAssertEqual(try self.body(request)["device_id"]?.string, service.deviceID); return try self.reply(["token": .string(self.token)]) }
            return try self.reply(["progress": .array([])])
        }
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "anime-sync.example", .path: "/", .name: "anime_sync_admin", .value: "fixture-cookie", .secure: "TRUE"]))
        try await service.connect(origin: AppWebPolicy.home, cookies: [cookie]); XCTAssertTrue(service.isSignedIn); XCTAssertNotNil(secrets.values["sync.session"])
        let count = http.requests.count
        do { try await service.connect(origin: URL(string: "https://miruro.cx")!, cookies: [cookie]); XCTFail("Provider received dashboard auth") } catch { }
        XCTAssertEqual(http.requests.count, count)
    }
}
