#if DEBUG
import Foundation
import Combine

/// Disposable UI-test world. No request can escape to a real account or receiver.
@MainActor final class QAFixture: ObservableObject {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--qa-fixture") }
    static let pairingPIN = "000000"
    static let mediaURL = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")!
    @Published private(set) var commandCount = 0
    @Published private(set) var syncWriteCount = 0
    @Published private(set) var mutationLog: [String] = []
    let preferences: UserDefaults
    private let preferenceName: String
    private let secrets = QAFixtureSecrets()
    private let syncToken = "as-session-v1.qa_fixture_not_a_real_secret_123456789"
    private let tvToken = "qa_fixture_tv_not_a_real_secret_123456789"
    private let deviceID = "ios-companion-qa-fixture"
    private var rows: [String: JSONObject] = [:]
    private var heads: [String: (session: String, generation: Int64, sequence: Int64)] = [:]
    private var paired: Bool
    private var tvMine: Bool
    private var tvAvailable = false
    private var tvRevision: Int64 = 4
    private var tvPosition: Double = 200
    private var tvPlaying = false
    private var tvEpisode = "6"
    private var tvURL = URL(string: "https://miruro.cx/watch/21/fixture-21?ep=6")!
    private var handoffSaved = false
    private var syncInstance: SyncService?
    private var tvInstance: TVClient?
    private var dashboardLoadSequence = 0
    private var providerSubscriptions: [AnyCancellable] = []
    private var fixtureAudioChoice = "qa.audio.sub"
    private var fixtureProviderChoice = "qa.provider.a"
    private let includeSynopsis: Bool

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        includeSynopsis = arguments.contains("--qa-episode-synopsis")
        preferenceName = "qa-ios-fixture-" + UUID().uuidString
        preferences = UserDefaults(suiteName: preferenceName)!
        paired = !arguments.contains("--qa-tv-unpaired")
        let occupied = arguments.contains("--qa-tv-occupied")
        tvMine = paired && !occupied; tvAvailable = !paired && !occupied
        seedRows()
        let record: JSONObject = ["origin": .string(AppWebPolicy.home.absoluteString), "token": .string(syncToken), "deviceID": .string(deviceID)]
        secrets.values["sync.session"] = try? JSONEncoder().encode(record)
        if paired { secrets.values["tv.pairing"] = try? JSONEncoder().encode(["host": "10.0.0.20", "token": tvToken]) }
    }
    deinit { preferences.removePersistentDomain(forName: preferenceName) }

    func makeSync() -> SyncService {
        if let syncInstance { return syncInstance }
        let transport = QAFixtureTransport { [weak self] request in
            guard let self else { throw CancellationError() }; return try self.syncRequest(request)
        }
        let service = SyncService(transport: transport, secrets: secrets, preferences: preferences)
        syncInstance = service; return service
    }
    func makeTV() -> TVClient {
        if let tvInstance { return tvInstance }
        let transport = QAFixtureTransport { [weak self] request in
            guard let self else { throw CancellationError() }; return try self.tvRequest(request)
        }
        let client = TVClient(transport: transport, secrets: secrets, deviceName: "Fixture iPhone")
        tvInstance = client; return client
    }
    private func answer(_ object: JSONObject, status: Int = 200) throws -> HTTPReply {
        HTTPReply(status: status, body: try JSONEncoder().encode(object))
    }
    private func error(_ text: String, status: Int) throws -> HTTPReply { try answer(["error": .string(text)], status: status) }
    private func payload(_ request: URLRequest) throws -> JSONObject { try request.httpBody.map(JSONValue.parseObject) ?? [:] }
    private func key(_ id: String, _ episode: String) -> String { id + ":" + episode }
    private func seedRows() {
        let titles = ["One Piece", "The Apothecary Diaries", "Frieren: Beyond Journey’s End", "Dandadan", "Solo Leveling", "Re:ZERO", "Spy × Family", "Delicious in Dungeon", "Jujutsu Kaisen", "Fullmetal Alchemist: Brotherhood"]
        for index in 0..<titles.count {
            let id = String(21 + index), episode = index == 0 ? "6" : String(index + 1)
            let row: JSONObject = ["site": .string("miruro"), "anime_id": .string(id), "episode": .string(episode), "title": .string(titles[index]),
                "watch_url": .string("https://miruro.cx/watch/\(id)/fixture-\(id)?ep=\(episode)"), "poster_url": .string(""),
                "current_time": .number(index < 6 ? Double(200 + index * 30) : 1400), "duration": .number(1400), "completed": .bool(index >= 6),
                "updated_at": .string(String(format: "2026-11-06T16:%02d:00Z", 59 - index))]
            rows[key(id, episode)] = row; heads[key(id, episode)] = ("", 0, 0)
        }
        // An older completed episode must remain marked without replacing this
        // series' unfinished latest episode in Continue watching.
        var completed = rows[key("21","6")]!
        completed["episode"] = .string("1"); completed["watch_url"] = .string("https://miruro.cx/watch/21/fixture-21?ep=1")
        completed["current_time"] = .number(1400); completed["completed"] = .bool(true)
        completed["updated_at"] = .string("2026-11-05T16:00:00Z")
        rows[key("21","1")] = completed; heads[key("21","1")] = ("",0,0)
    }
    private func headResponse(_ key: String) -> JSONObject {
        let head = heads[key] ?? (session: "", generation: Int64(0), sequence: Int64(0))
        return ["sync": .object(["generation": .integer(head.generation), "session_id": .string(head.session)]), "progress": rows[key].map(JSONValue.object) ?? .null]
    }
    private func syncRequest(_ request: URLRequest) throws -> HTTPReply {
        guard let url = request.url, AppWebPolicy.isDashboard(url) else { throw CoreError.invalidResponse }
        let body = try payload(request)
        if url.path == "/api/device-session", request.httpMethod == "POST" { return try answer(["token": .string(syncToken)]) }
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer " + syncToken else { return try error("Fixture sign-in required", status: 401) }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if request.httpMethod == "GET", url.path == "/api/progress" {
            if let id = query.first(where: { $0.name == "anime_id" })?.value, let episode = query.first(where: { $0.name == "episode" })?.value { return try answer(headResponse(key(id, episode))) }
            return try answer(["progress": .array(rows.keys.sorted().compactMap { rows[$0].map(JSONValue.object) })])
        }
        guard let id = body["anime_id"]?.string, let episode = body["episode"]?.string, AppWebPolicy.identity(animeID: id, episode: episode) else { return try error("Invalid fixture identity", status: 400) }
        let identity = key(id, episode), head = heads[key(id, episode)] ?? (session: "", generation: Int64(0), sequence: Int64(0))
        if request.httpMethod == "POST", url.path == "/api/playback" {
            guard body["expected_generation"]?.integer == head.generation, let session = body["playback_session_id"]?.string, !session.isEmpty, body["device_id"]?.string == deviceID else { return try error("Fixture playback continued elsewhere", status: 409) }
            heads[identity] = (session, head.generation + 1, 0)
            return try answer(headResponse(identity))
        }
        if request.httpMethod == "POST", url.path == "/api/progress" {
            guard body["sync_protocol"]?.integer == 2, body["playback_session_id"]?.string == head.session, !head.session.isEmpty,
                  body["playback_generation"]?.integer == head.generation, let sequence = body["playback_sequence"]?.integer,
                  sequence > head.sequence, body["device_id"]?.string == deviceID else { return try error("Fixture playback continued elsewhere", status: 409) }
            var next = body; next["updated_at"] = .string(ISO8601DateFormatter().string(from: Date()))
            rows[identity] = next; heads[identity] = (head.session, head.generation, sequence); syncWriteCount += 1
            return try answer(["ok": .bool(true)])
        }
        return try error("Unknown fixture endpoint", status: 404)
    }
    private func tvStatus() -> JSONObject {
        var status: JSONObject = ["capabilities": .array(["load", "handoff", "exclusive_control"].map(JSONValue.string)),
            "control": .object(["supported": .bool(true), "mine": .bool(tvMine), "available": .bool(tvAvailable), "owner_name": .string(tvAvailable ? "" : tvMine ? "Fixture iPhone" : "Fixture tablet"), "revision": .integer(tvRevision)]),
            "title": .string("One Piece"), "episode": .string(tvEpisode), "watch_url": .string(tvURL.absoluteString), "playing": .bool(tvPlaying), "position": .number(tvPosition), "duration": .number(1400)]
        if handoffSaved { status["handoff_saved"] = .bool(true); status["handoff_generation"] = .integer(heads[key(tvURL.pathComponents.dropFirst(2).first ?? "21", tvEpisode)]?.generation ?? 0) }
        return status
    }
    private func tvConflict(_ message: String) throws -> HTTPReply { var status = tvStatus(); status["error"] = .string(message); return try answer(status, status: 409) }
    private func tvRequest(_ request: URLRequest) throws -> HTTPReply {
        guard let url = request.url, url.scheme == "http", url.port == 8765, let host = url.host, (try? TVAddress.host(host)) != nil else { throw CoreError.invalidTVAddress }
        let body = try payload(request)
        if url.path == "/pair", request.httpMethod == "POST" {
            guard body["pin"]?.string == Self.pairingPIN else { return try error("Incorrect fixture pairing code", status: 403) }
            paired = true; return try answer(["token": .string(tvToken)])
        }
        guard paired, request.value(forHTTPHeaderField: "Authorization") == "Bearer " + tvToken else { return try error("Fixture pairing required", status: 401) }
        if url.path == "/status", request.httpMethod == "GET" { return try answer(tvStatus()) }
        guard url.path == "/command", let command = body["command"]?.string else { return try error("Unknown fixture endpoint", status: 404) }
        if ["control_claim", "control_takeover", "control_release"].contains(command) {
            guard body["expected_control_revision"]?.integer == tvRevision else { return try tvConflict("TV control changed. Tap the action again.") }
            if command == "control_release" {
                guard tvMine else { return try tvConflict("Only the owner can release fixture TV control") }; tvMine = false; tvAvailable = true; tvRevision += 1
            } else {
                guard command == "control_takeover" || tvAvailable || tvMine else { return try tvConflict("Another fixture device controls this TV") }
                if !tvMine { tvRevision += 1 }; tvMine = true; tvAvailable = false
            }
            return try answer(tvStatus())
        }
        guard tvMine, body["control_revision"]?.integer == tvRevision else { return try tvConflict("Take control of the TV first") }
        let allowed: Set<String> = ["key", "back", "home", "toggle", "play", "pause", "seek", "text", "subtitles", "pointer", "scroll", "load", "seek_to", "handoff"]
        guard allowed.contains(command) else { return try error("Unknown fixture command", status: 400) }
        switch command {
        case "play": tvPlaying = true
        case "pause", "handoff": tvPlaying = false; handoffSaved = command == "handoff"
        case "toggle": tvPlaying.toggle()
        case "seek": tvPosition = min(1400, max(0, tvPosition + (body["seconds"]?.double ?? 0)))
        case "seek_to": tvPosition = min(1400, max(0, body["seconds"]?.double ?? 0))
        case "load":
            guard let value = body["url"]?.string, let loaded = URL(string: value), AppWebPolicy.isProvider(loaded) else { return try error("Invalid fixture watch URL", status: 400) }
            tvURL = loaded; tvPosition = body["position"]?.double ?? 0; tvPlaying = true
            tvEpisode = URLComponents(url: loaded, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "ep" })?.value ?? tvEpisode
        default: break
        }
        commandCount += 1; mutationLog.append(command)
        return try answer(tvStatus())
    }

    func seedProvider(_ provider: MiruroProvider) {
        provider.$selectedChoiceID.dropFirst().sink { [weak self,weak provider] choice in
            guard !choice.isEmpty, let provider else { return }
            let url = provider.currentURL, revision = provider.selectionRevision
            Task { @MainActor [weak self,weak provider] in
                guard let self, let provider, provider.currentURL == url,
                      provider.selectionRevision == revision, provider.selectedChoiceID == choice else { return }
                if choice.hasPrefix("qa.audio.") { self.fixtureAudioChoice = choice }
                if choice.hasPrefix("qa.provider.") { self.fixtureProviderChoice = choice }
                self.publishProvider(provider,section: provider.section,url: url)
            }
        }.store(in: &providerSubscriptions)
        provider.onFixtureBrowse = { [weak self, weak provider] section, url in
            guard let self, let provider else { return }; self.publishProvider(provider, section: section, url: url)
        }
        provider.onFixtureEpisode = { [weak provider] episode in
            guard let provider else { return }; var url = URLComponents(url: provider.currentURL, resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "ep", value: episode)]; if let target = url.url { provider.open(url: target) }
        }
        publishProvider(provider, section: provider.section, url: provider.currentURL)
    }
    private func publishProvider(_ provider: MiruroProvider, section: String, url: URL) {
        if let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment, fragment.contains("anime-sync-id=") {
            var parts = URLComponents(); parts.query = fragment
            let id = parts.queryItems?.first(where: { $0.name == "anime-sync-id" })?.value ?? "21"
            let episode = parts.queryItems?.first(where: { $0.name == "anime-sync-ep" })?.value ?? "6"
            provider.receiveFixture(["type": .string("resolved-watch"), "url": .string("https://miruro.cx/watch/\(id)/fixture-\(id)?ep=\(episode)"), "anime_id": .string(id), "episode": .string(episode)])
            return
        }
        if url.path.hasPrefix("/watch/") || url.path.hasPrefix("/info/") {
            let id = url.pathComponents.dropFirst(2).first ?? "21"
            let episode = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "ep" })?.value ?? "6"
            let title = rows.values.first { $0["anime_id"]?.string == id }?["title"]?.string ?? "Fixture anime"
            let metadata = AnimeMetadata(animeID: id, episode: episode, title: title, watchURL: url)
            var details = metadata.json
            if includeSynopsis && id == "21" {
                details["description"] = .string((1...16).map { "At stop \($0), the crew discovers a different island and learns its local history before setting sail again." }.joined(separator: "\n\n"))
            }
            provider.receiveFixture(["type": .string("metadata"), "metadata": .object(details)])
            let episodeCount: Int = id == "21" ? 1140 : 40
            var episodeChoices: [JSONValue] = []
            episodeChoices.reserveCapacity(episodeCount)
            for index in 1...episodeCount {
                let number = String(index)
                var item: JSONObject = [:]
                item["id"] = .string(number)
                item["label"] = .string(number)
                item["number"] = .string(number)
                item["title"] = .string("Fixture episode \(number)")
                item["selected"] = .bool(number == episode)
                episodeChoices.append(.object(item))
            }
            provider.receiveFixture(["type": .string("episodes"),"complete": .bool(true),"episodes": .array(episodeChoices)])
            let audio: [JSONValue] = [("qa.audio.sub","Sub"),("qa.audio.dub","Dub")].map { choice,label in
                .object(["id": .string(choice),"label": .string(label),"selected": .bool(choice == fixtureAudioChoice)])
            }
            let sources: [JSONValue] = [("qa.provider.a","Fixture A"),("qa.provider.b","Fixture B")].map { choice,label in
                .object(["id": .string(choice),"label": .string(label),"selected": .bool(choice == fixtureProviderChoice)])
            }
            let groups: [JSONValue] = [.object(["name": .string("Audio"),"items": .array(audio)]),.object(["name": .string("Provider"),"items": .array(sources)])]
            provider.receiveFixture(["type": .string("source-choices"),"groups": .array(groups)])
            provider.receiveFixture(["type": .string("source"), "url": .string("https://example.invalid/qa-alternate.m3u8"), "mime": .string("application/vnd.apple.mpegurl"), "confirmed": .bool(false)])
            provider.receiveFixture(["type": .string("source"), "url": .string(Self.mediaURL.absoluteString), "mime": .string("application/vnd.apple.mpegurl"), "confirmed": .bool(true)])
            return
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value?.lowercased() ?? ""
        let items: [JSONValue] = query.contains("zzqaempty") ? [] : rows.keys.sorted().compactMap { key in
            guard let row = rows[key] else { return nil }
            return .object(["title": row["title"] ?? .string("Fixture anime"), "url": row["watch_url"] ?? .string(""), "badge": .string("Episode " + (row["episode"]?.string ?? "1"))])
        }
        let labels = section == "Search" ? ["Search results"] : ["Latest Episodes", "Top Airing", "Popular Anime"]
        provider.receiveFixture(["type": .string("catalogue"), "loading": .bool(false), "message": .string(items.isEmpty ? "No anime found" : ""), "groups": .array(items.isEmpty ? [] : labels.map { .object(["title": .string($0), "items": .array(items)]) })])
        if section == "Home" { provider.receiveFixture(["type": .string("hero"), "hero": .object(["title": .string("One Piece"), "description": .string("A disposable preview for native iPhone layout and playback tests."), "meta": .string("Adventure · 40 episodes"), "url": .string("https://miruro.cx/watch/21/fixture-21?ep=6")])]) }
    }
    func seedDashboard(_ dashboard: DashboardProvider) {
        dashboard.onFixtureLoad = { [weak self, weak dashboard] _ in
            guard let self, let dashboard else { return }
            self.dashboardLoadSequence += 1
            let sequence = self.dashboardLoadSequence
            // A real reload first receives a provisional/authenticated page while
            // its full dataset is still loading. It may not erase a saved grid.
            dashboard.receiveFixture(["type": .string("library-status"),"loading": .bool(true)])
            dashboard.receiveFixture(["type": .string("library"),"loading": .bool(true),"complete": .bool(false),"cards": .array([])])
            Task { @MainActor [weak self, weak dashboard] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled, let self, let dashboard, self.dashboardLoadSequence == sequence else { return }
                self.publishDashboard(dashboard,sequence: sequence)
            }
        }
        publishDashboard(dashboard)
    }
    private func publishDashboard(_ dashboard: DashboardProvider,sequence: Int = 0) {
        let cards: [JSONValue] = (0..<60).map { index in
            let id = String(21 + index), baseTitle = index == 0 ? "One Piece" : "Fixture anime \(index + 1)"
            let title = baseTitle + (sequence > 0 ? " · refreshed \(sequence)" : "")
            return .object(["key": .string("miruro:" + id), "title": .string(title), "url": .string("https://miruro.cx/watch/\(id)/fixture-\(id)?ep=6"), "episode": .string("6"), "progress": .number(index < 20 ? 0.2 : 0), "continuing": .bool(index < 20 && index % 3 != 0), "has_new": .bool(index % 3 == 0), "next_episode": .string("7"), "next_url": .string("https://miruro.cx/watch/\(id)/fixture-\(id)?ep=7")])
        }
        dashboard.receiveFixture(["type": .string("library"),"loading": .bool(false),"complete": .bool(true),"cards": .array(cards)])
    }
}

private final class QAFixtureSecrets: CoreSecrets {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func write(_ data: Data?, for key: String) throws { values[key] = data }
}
@MainActor private final class QAFixtureTransport: HTTPTransport {
    let respond: @MainActor (URLRequest) throws -> HTTPReply
    init(_ respond: @escaping @MainActor (URLRequest) throws -> HTTPReply) { self.respond = respond }
    func request(_ request: URLRequest, maxBytes: Int) async throws -> HTTPReply {
        try Task.checkCancellation(); let reply = try respond(request)
        guard reply.body.count <= maxBytes else { throw CoreError.responseTooLarge }; return reply
    }
}
#endif
