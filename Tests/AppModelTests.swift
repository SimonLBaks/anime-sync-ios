import XCTest
import Foundation
@testable import AnimeSync

@MainActor private final class AppModelSecrets: CoreSecrets {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func write(_ data: Data?,for key: String) throws { values[key] = data }
}
@MainActor private final class AppModelHTTP: HTTPTransport {
    var requests: [URLRequest] = []
    var respond: ((URLRequest) async throws -> HTTPReply)!
    func request(_ request: URLRequest,maxBytes: Int) async throws -> HTTPReply {
        requests.append(request); return try await respond(request)
    }
}
@MainActor private final class AppModelGate {
    let reached: XCTestExpectation
    private var continuation: CheckedContinuation<Void,Never>?
    private var opened = false
    init(_ reached: XCTestExpectation) { self.reached = reached }
    func wait() async {
        reached.fulfill()
        if !opened { await withCheckedContinuation { continuation = $0 } }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

/// Actual AppModel navigation with isolated SyncService HTTP and inert WK
/// fixture documents. These tests never prepare/download a media item.
@MainActor final class AppModelTests: XCTestCase {
    private var models: [AppModel] = []
    private var fixtures: [QAFixture] = []
    private var suites: [(String,UserDefaults)] = []
    private var gates: [AppModelGate] = []
    private var tasks: [Task<Void,Never>] = []
    private func reply(_ body: JSONObject) throws -> HTTPReply {
        HTTPReply(status: 200,body: try JSONEncoder().encode(body))
    }
    private func history(_ episode: String = "8") -> JSONObject {
        ["progress": .array([.object([
            "site": .string("miruro"),"anime_id": .string("21"),"episode": .string(episode),
            "title": .string("One Piece"),"current_time": .number(episode == "6" ? 200 : 900),
            "duration": .number(1400),"completed": .bool(false),
            "updated_at": .string("2026-11-06T16:00:00Z")])])]
    }
    private func head(_ generation: Int64 = 7,episode: String = "8") -> JSONObject {
        ["sync": .object(["generation": .integer(generation),"session_id": .string("fixture-pc-session"),"episode": .string(episode)]),
         "progress": .object(["current_time": .number(900),"duration": .number(1400),"completed": .bool(false)])]
    }
    private func isHead(_ request: URLRequest) -> Bool {
        URLComponents(url: request.url!,resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "anime_id" }) == true
    }
    private func make(_ http: AppModelHTTP,
                      recoverConnection: (@MainActor () async throws -> Void)? = nil) throws -> AppModel {
        let name = "qa-ios-app-model-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); suites.append((name,defaults))
        let secrets = AppModelSecrets()
        secrets.values["sync.session"] = try JSONEncoder().encode([
            "origin": .string(AppWebPolicy.home.absoluteString),
            "token": .string("qa_fixture_session_12345678901234567890"),
            "deviceID": .string("ios-app-model-fixture")
        ] as JSONObject)
        let fixture = QAFixture(arguments: ["--qa-fixture","--qa-tv-unpaired"]); fixtures.append(fixture)
        let model = AppModel(sync: SyncService(transport: http,secrets: secrets,preferences: defaults),
                             tv: fixture.makeTV(),fixture: true,recoverConnection: recoverConnection)
        models.append(model)
        return model
    }
    private func card(continuing: Bool = true,hasNew: Bool = false,urlEpisode: String = "6") throws -> SyncLibraryCard {
        try XCTUnwrap(SyncLibraryCard(json: [
            "key": .string("miruro:21"),"title": .string("One Piece"),
            "url": .string("https://miruro.cx/watch/21/fixture-21?ep=" + urlEpisode),
            "episode": .string("6"),"continuing": .bool(continuing),"has_new": .bool(hasNew)
        ]))
    }
    private func block(_ name: String) -> AppModelGate {
        let gate = AppModelGate(expectation(description: name)); gates.append(gate); return gate
    }
    override func tearDown() async throws {
        gates.forEach { $0.open() }
        for task in tasks { await task.value }
        for model in models {
            if let player = model.player { await player.close() }
            model.tv.stopPolling(); model.discovery.stop(); model.provider.stop(); model.dashboard.pause()
        }
        models.removeAll(); fixtures.removeAll(); gates.removeAll(); tasks.removeAll()
        for (name,defaults) in suites { defaults.removePersistentDomain(forName: name) }
        suites.removeAll()
        try await super.tearDown()
    }

    func testLibraryContinueRefreshesEpisodeAndOwnershipBeforeOpeningItsCachedURL() async throws {
        let http = AppModelHTTP(), model = try make(http)
        http.respond = { _ in try self.reply(self.history("6")) }
        let cached = await model.sync.refreshHistory(); XCTAssertTrue(cached)
        model.navigate("Anime Sync")
        var headsBeforeBrowse: [URLRequest] = []
        http.respond = { request in
            XCTAssertEqual(request.httpMethod,"GET")
            return try self.reply(self.isHead(request) ? self.head() : self.history())
        }
        model.provider.onFixtureBrowse = { _,_ in headsBeforeBrowse = http.requests.filter(self.isHead) }
        await model.openLibraryCard(try card())
        XCTAssertEqual(model.route.section,"Episode")
        XCTAssertEqual(model.route.url?.fragment,"anime-sync-id=21&anime-sync-ep=8")
        XCTAssertFalse(model.route.url?.absoluteString.contains("anime-sync-t") ?? true)
        XCTAssertEqual(headsBeforeBrowse.count,1,"Ownership must be captured before discovery begins")
        let query = URLComponents(url: try XCTUnwrap(headsBeforeBrowse.first?.url),resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "episode" })?.value,"8")
        XCTAssertTrue(http.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testOfflineLibraryContinueKeepsTheLibraryInsteadOfOpeningCachedEpisodeSix() async throws {
        let http = AppModelHTTP(), model = try make(http)
        model.navigate("Anime Sync")
        http.respond = { _ in throw URLError(.notConnectedToInternet) }
        await model.openLibraryCard(try card())
        XCTAssertEqual(model.route.section,"Anime Sync")
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.provider.currentURL.path.hasPrefix("/watch/"))
    }

    func testForegroundRestoresConnectionBeforeReloadingFailedHome() async throws {
        var events: [String] = []
        let http = AppModelHTTP(), model = try make(http) { events.append("restore") }
        model.provider.onFixtureBrowse = { _,_ in events.append("browse") }
        await model.background()
        model.provider.webView(model.provider.webView,didFailProvisionalNavigation: nil,
                               withError: URLError(.networkConnectionLost))
        XCTAssertNotNil(model.provider.error)

        await model.foreground()

        XCTAssertEqual(events,["restore","browse"])
        XCTAssertEqual(model.route,.home)
        XCTAssertNil(model.provider.error)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testRetryRefreshesLibraryAfterConnectionRecovers() async throws {
        let http = AppModelHTTP()
        var restored = false
        let model = try make(http) { restored = true }
        http.respond = { _ in try self.reply(self.history("6")) }
        _ = await model.sync.refreshHistory()
        model.navigate("Anime Sync")
        http.respond = { request in
            guard restored else { throw URLError(.networkConnectionLost) }
            return try self.reply(self.isHead(request) ? self.head() : self.history())
        }
        await model.openLibraryCard(try card())
        XCTAssertNotNil(model.message)
        XCTAssertEqual(model.sync.history.continuing.first?.episode,"6")

        await model.retryConnection()

        XCTAssertEqual(model.sync.history.continuing.first?.episode,"8")
        XCTAssertNil(model.message)
        XCTAssertEqual(model.route.section,"Anime Sync")
        await model.openLibraryCard(try card())
        XCTAssertEqual(model.route.url?.fragment,"anime-sync-id=21&anime-sync-ep=8")
        XCTAssertTrue(http.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testPlayWithSavedProgressWaitsForFreshPositionAfterConnectionLoss() async throws {
        let http = AppModelHTTP(), model = try make(http)
        http.respond = { _ in try self.reply(self.history("6")) }
        _ = await model.sync.refreshHistory()
        let url = URL(string: "https://miruro.cx/watch/21/fixture-21?ep=6")!
        model.open(url)
        model.provider.receiveFixture(["type": .string("metadata"),"metadata": .object(AnimeMetadata(animeID: "21",episode: "6",title: "One Piece",watchURL: url).json)])
        model.provider.receiveFixture(["type": .string("source"),"url": .string("https://cdn.example/fixture.mp4"),"confirmed": .bool(true)])
        http.respond = { _ in throw URLError(.networkConnectionLost) }

        await model.playHere()

        XCTAssertNil(model.player)
        XCTAssertTrue(model.message?.contains("saved position") == true)
        http.respond = { _ in try self.reply(self.head(episode: "6")) }
        await model.playHere()
        XCTAssertNotNil(model.player)
        XCTAssertTrue(http.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testLibraryContinueCanOpenASeriesOutsideHomeAndWithAnEarlyCheckpoint() async throws {
        let http = AppModelHTTP(), model = try make(http)
        model.navigate("Anime Sync")
        var row = try XCTUnwrap(history()["progress"]?.array?.first?.object)
        row["updated_at"] = .string("2026-11-06T15:00:00Z")
        let newer: [JSONValue] = (100...124).map { id in
            var item = row
            item["anime_id"] = .string(String(id))
            item["updated_at"] = .string("2026-11-06T16:00:00Z")
            return .object(item)
        }
        for position in [900.0, 2.0] {
            row["current_time"] = .number(position)
            let rows: JSONObject = ["progress": .array(newer + [.object(row)])]
            http.respond = { request in try self.reply(self.isHead(request) ? self.head() : rows) }
            await model.openLibraryCard(try card())
            XCTAssertEqual(model.route.url?.fragment,"anime-sync-id=21&anime-sync-ep=8")
            XCTAssertEqual(model.sync.history.continuing.count,24)
            XCTAssertFalse(model.sync.history.continuing.contains { $0.animeID == "21" })
            model.navigate("Anime Sync")
        }
    }

    func testCompletedLibraryCheckpointOpensAdvertisedNumericNextEpisode() async throws {
        let http = AppModelHTTP(), model = try make(http)
        model.navigate("Anime Sync")
        let next = try XCTUnwrap(SyncLibraryCard(json: [
            "key": .string("miruro:21"),"title": .string("One Piece"),
            "url": .string("https://miruro.cx/watch/21/fixture-21?ep=8"),
            "episode": .integer(9),"next_episode": .integer(9),"checkpoint_episode": .string("8"),
            "continuing": .bool(true),"has_new": .bool(false)
        ]))
        XCTAssertEqual(next.episode,"9")
        var row = try XCTUnwrap(history()["progress"]?.array?.first?.object)
        row["completed"] = .bool(true)
        let completed = row
        var older = try XCTUnwrap(history("6")["progress"]?.array?.first?.object)
        older["updated_at"] = .string("2026-11-06T15:00:00Z")
        let old: JSONValue = .object(older)
        http.respond = { request in
            if self.isHead(request) {
                XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url),resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "episode" })?.value,"9")
                return try self.reply(self.head(episode: "8"))
            }
            return try self.reply(["progress": .array([.object(completed),old])])
        }
        await model.openLibraryCard(next)
        XCTAssertEqual(model.route.url?.fragment,"anime-sync-id=21&anime-sync-ep=9")
        XCTAssertTrue(http.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testContinueDoesNotOpenOldEpisodeWhenAnotherDeviceChangesTheSeriesHead() async throws {
        let http = AppModelHTTP(), model = try make(http)
        model.navigate("Anime Sync")
        http.respond = { request in try self.reply(self.isHead(request) ? self.head(episode: "9") : self.history()) }
        await model.openLibraryCard(try card())
        XCTAssertEqual(model.route.section,"Anime Sync")
        XCTAssertEqual(model.message,"Playback moved to another episode. Try Continue again.")
    }

    func testChangingPageWhileContinueOwnershipLoadsCannotOpenThePreviousSelection() async throws {
        let http = AppModelHTTP(), model = try make(http), blocked = block("ownership head requested")
        model.navigate("Anime Sync")
        http.respond = { request in
            if self.isHead(request) { await blocked.wait(); return try self.reply(self.head()) }
            return try self.reply(self.history())
        }
        let selected = try card()
        let old = Task { await model.openLibraryCard(selected) }; tasks.append(old)
        await fulfillment(of: [blocked.reached],timeout: 3)
        model.navigate("Search")
        blocked.open(); await old.value
        XCTAssertEqual(model.route.section,"Search")
        XCTAssertEqual(model.provider.currentURL.path,"/search")
        XCTAssertNil(model.player)
    }

    func testAccountChangeWhileContinueOwnershipLoadsCannotOpenTheOldAccountSelection() async throws {
        let http = AppModelHTTP(), model = try make(http), blocked = block("old account head requested")
        model.navigate("Anime Sync")
        http.respond = { request in
            if self.isHead(request) { await blocked.wait(); return try self.reply(self.head()) }
            return try self.reply(self.history())
        }
        let selected = try card()
        let old = Task { await model.openLibraryCard(selected) }; tasks.append(old)
        await fulfillment(of: [blocked.reached],timeout: 3)
        try model.sync.signOut()
        blocked.open(); await old.value
        XCTAssertEqual(model.route.section,"Anime Sync")
        XCTAssertNil(model.player)
        XCTAssertFalse(model.provider.currentURL.path.hasPrefix("/watch/"))
    }

    func testNewEpisodeActionRetainsItsDeliberateNextEpisodeURL() async throws {
        let http = AppModelHTTP(), model = try make(http)
        http.respond = { _ in XCTFail("A deliberate new-episode selection must not become Continue"); return try self.reply([:]) }
        await model.openLibraryCard(try card(continuing: false,hasNew: true,urlEpisode: "7"))
        XCTAssertEqual(model.route.url?.query,"ep=7")
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testContinueResolvesLegacySavedHostsWithFreshIdentityAndOwnership() async throws {
        for host in ["www.miruro.to","www.miruro.cx","miruro.tv","untrusted.example"] {
            let http = AppModelHTTP(), model = try make(http)
            var response = history("8")
            var row = try XCTUnwrap(response["progress"]?.array?.first?.object)
            row["watch_url"] = .string("https://" + host + "/watch/old-opaque/one-piece?ep=6")
            response["progress"] = .array([.object(row)])
            let fresh = response
            http.respond = { request in try self.reply(self.isHead(request) ? self.head() : fresh) }
            await model.openLibraryCard(try card())
            let target = try XCTUnwrap(model.route.url)
            XCTAssertEqual(target.host,"miruro.cx"); XCTAssertEqual(target.path,"/search")
            XCTAssertEqual(target.fragment,"anime-sync-id=21&anime-sync-ep=8","Legacy opaque IDs and cached episode6 cannot override the fresh series identity")
            XCTAssertEqual(http.requests.filter(self.isHead).count,1)
            XCTAssertTrue(http.requests.allSatisfy { $0.httpMethod == "GET" })
        }
    }

    func testLegacyExplicitLibraryEpisodesResolveWithoutBecomingContinue() async throws {
        for hasNew in [false,true] {
            let http = AppModelHTTP(), model = try make(http), episode = hasNew ? "7" : "6"
            http.respond = { _ in XCTFail("An explicit library episode must not read Continue"); return try self.reply([:]) }
            let item = try XCTUnwrap(SyncLibraryCard(json: [
                "key": .string("miruro:21"),"title": .string("One Piece"),
                "url": .string("https://www.miruro.to/watch/old-opaque/one-piece?ep=" + episode),
                "episode": .string("6"),"continuing": .bool(false),"has_new": .bool(hasNew),"next_episode": .string("7")
            ]))
            await model.openLibraryCard(item)
            XCTAssertEqual(model.route.url?.host,"miruro.cx")
            XCTAssertEqual(model.route.url?.fragment,"anime-sync-id=21&anime-sync-ep=" + episode)
            XCTAssertTrue(http.requests.isEmpty)
        }
    }

    func testPlayCapturesOwnershipBeforeWaitingForTheMutedSourceDiscovery() async throws {
        let http = AppModelHTTP(), model = try make(http), blocked = block("pre-discovery ownership requested")
        let url = URL(string: "https://miruro.cx/watch/21/fixture-21?ep=6")!
        model.open(url)
        model.provider.receiveFixture(["type": .string("metadata"),"metadata": .object(AnimeMetadata(animeID: "21",episode: "6",title: "One Piece",watchURL: url).json)])
        http.respond = { request in
            XCTAssertEqual(request.httpMethod,"GET"); XCTAssertTrue(self.isHead(request))
            await blocked.wait(); return try self.reply(self.head())
        }
        let play = Task { await model.playHere() }; tasks.append(play)
        await fulfillment(of: [blocked.reached],timeout: 3)
        XCTAssertNil(model.player); XCTAssertTrue(model.provider.sources.isEmpty)
        await model.playHere()
        XCTAssertEqual(http.requests.count,1,"Repeated Play taps must share the in-flight ownership request, without queuing an intent that can reopen a closed player")
        blocked.open(); await play.value
        model.provider.receiveFixture(["type": .string("source"),"url": .string("https://cdn.example/fixture.mp4"),"confirmed": .bool(true)])
        model.launchIfReady()
        XCTAssertNotNil(model.player)
        XCTAssertEqual(http.requests.count,1,"Discovery completion may not refresh away the pre-discovery fence")
        XCTAssertTrue(http.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testHomeUsesCanonicalContinueAndHistoryWithoutDroppingUnrelatedProviderRows() {
        let headings = ["Continue watching","Continue Watching"," CONTINUE\u{00a0}WATCHING ","Continue-watching →", "Recently watched","Recently\nWatched", "Latest Episodes","Watchlist","Continue Watching Classics","Recently Watched Again"]
        let url = URL(string: "https://miruro.cx/watch/21/fixture-21?ep=6")!
        let groups = headings.map { CatalogueGroup(title: $0,items: [CatalogueCard(title: "Fixture",url: url)]) }
        let home = CataloguePresentation.groups(groups,section: "Home")
        XCTAssertEqual(home.map(\.title),["Latest Episodes","Watchlist","Continue Watching Classics","Recently Watched Again"])
        XCTAssertTrue(home.allSatisfy { $0.items.first?.url == url },"Presentation filtering must preserve the surviving row's content")
        for section in ["Trending","Discover","Search"] {
            XCTAssertEqual(CataloguePresentation.groups(groups,section: section),groups,"Only Home substitutes canonical Anime Sync rows")
        }
    }

    func testEpisodePresentationSortsRealNumbersAndKeepsSuppliedTitlesAndCurrentIdentity() {
        let ten = EpisodeChoice(id: "opaque-ten",label: "10",number: "10",title: "A supplied episode title",selected: true)
        let two = EpisodeChoice(id: "opaque-two",label: "2",number: "02.000")
        let one = EpisodeChoice(id: "opaque-one",label: "1",number: "1",title: "First supplied title")
        let fraction = EpisodeChoice(id: "opaque-fraction",label: "2.5",number: "2.5")
        let special = EpisodeChoice(id: "special",label: "Website special")
        let ordered = EpisodePresentation.ordered([ten,two,special,one,fraction,ten])
        XCTAssertEqual(ordered.map(\.id),[one.id,two.id,fraction.id,ten.id,special.id])
        XCTAssertEqual(EpisodePresentation.title(ten),"A supplied episode title")
        XCTAssertEqual(EpisodePresentation.title(two),"Episode 2")
        XCTAssertEqual(EpisodePresentation.title(special),"Website special","Missing metadata must not manufacture an episode name")
        XCTAssertTrue(EpisodePresentation.isCurrent(two,number: "2.0"))
        XCTAssertFalse(EpisodePresentation.isCurrent(ten,number: "2"),"Current metadata takes precedence over an older selected DOM row")
    }

    func testLongEpisodeInventoryRetainsAll1140RowsAndProvidesTruthfulJumpRanges() {
        let episodes = (1...1140).reversed().map { EpisodeChoice(id: "opaque-\($0)",label: String($0),number: String($0)) }
        let ordered = EpisodePresentation.ordered(episodes), ranges = EpisodePresentation.jumps(episodes)
        XCTAssertEqual(ordered.count,1140); XCTAssertEqual(ordered.first?.number,"1"); XCTAssertEqual(ordered.last?.number,"1140")
        XCTAssertEqual(ranges.count,12); XCTAssertEqual(ranges.first?.label,"1–100"); XCTAssertEqual(ranges.last?.label,"1101–1140")
        XCTAssertEqual(ranges.last?.firstEpisodeID,"opaque-1101")
        XCTAssertEqual(ordered.first(where: { EpisodePresentation.isCurrent($0,number: "1140") })?.id,"opaque-1140")
        let sparse = [EpisodeChoice(id: "a",label: "101",number: "101"),EpisodeChoice(id: "b",label: "108",number: "108")]
        XCTAssertEqual(EpisodePresentation.jumps(sparse).map(\.label),["101–108"],"Ranges describe only supplied rows; they do not fabricate missing episodes")
    }

    func testEpisodeWindowRemainsBoundedByPortraitAndShortLandscapeViewport() {
        for height in [CGFloat(1),120,210,700,900] {
            let window = EpisodePresentation.windowHeight(available: height)
            XCTAssertGreaterThan(window,0); XCTAssertLessThanOrEqual(window,height); XCTAssertLessThanOrEqual(window,320)
        }
        XCTAssertLessThan(EpisodePresentation.windowHeight(available: 210),EpisodePresentation.windowHeight(available: 700))
    }
}
