import Foundation
import Combine

@MainActor final class SyncService: ObservableObject {
    @Published private(set) var status = "Sign in to Anime Sync"
    @Published private(set) var isSignedIn = false
    @Published private(set) var baseURL: URL
    @Published private(set) var history = HomeHistorySnapshot.empty
    @Published private(set) var watchedEpisodes: Set<EpisodeProgressKey> = []
    @Published private var episodeFractions: [EpisodeProgressKey: Double] = [:]
    @Published private(set) var connecting = false
    var onOwnershipLost: ((PlaybackLease) -> Void)?
    private(set) var deviceID: String
    private let preferences: UserDefaults
    private let secrets: CoreSecrets
    private let transport: HTTPTransport
    private let queue = AsyncOperationQueue()
    private var token = ""
    private var accountEpoch: UInt64 = 0
    var accountGeneration: UInt64 { accountEpoch }
    private var connectSequence: UInt64 = 0
    private var players: [String: PlaybackLease] = [:]
    private let pendingPrefix = "animesync.pending:"
    private let heldPrefix = "animesync.held:"
    private static let historyRefreshFailure = "Could not refresh history. Check your connection."
    private struct StoredSession: Codable { let origin: URL; let token: String; let deviceID: String }

    init(transport: HTTPTransport = CoreHTTPTransport(), secrets: CoreSecrets = KeychainSecrets(), preferences: UserDefaults = .standard) {
        self.transport = transport; self.secrets = secrets; self.preferences = preferences
        let selected = preferences.string(forKey: "animesync.base").flatMap(URL.init(string:))
        baseURL = selected.flatMap { AppWebPolicy.isDashboard($0) ? $0 : nil } ?? AppWebPolicy.home
        deviceID = preferences.string(forKey: "animesync.device") ?? "ios-companion-" + UUID().uuidString
        if let data = try? secrets.read("sync.session"), let saved = try? JSONDecoder().decode(StoredSession.self, from: data),
           AppWebPolicy.isDashboard(saved.origin), Self.validToken(saved.token), !saved.deviceID.isEmpty {
            baseURL = saved.origin; token = saved.token; deviceID = saved.deviceID; isSignedIn = true; status = "Sync ready"
        }
        preferences.set(deviceID, forKey: "animesync.device")
    }
    private static func validToken(_ token: String) -> Bool { token.range(of: "^[A-Za-z0-9._~-]{20,4096}\\z", options: .regularExpression) != nil }
    private func sameAccount(_ epoch: UInt64) throws { guard epoch == accountEpoch else { throw CancellationError() } }
    private func clearUnauthorized() {
        accountEpoch &+= 1; token = ""; isSignedIn = false; history = .empty; watchedEpisodes = []; episodeFractions = [:]
        try? secrets.write(nil, for: "sync.session"); status = "Sign in again to resume sync"
        let old = players.values; players.removeAll(); for lease in old { lease.invalidate(); onOwnershipLost?(lease) }
    }
    func signOut() throws {
        try secrets.write(nil, for: "sync.session")
        accountEpoch &+= 1; connectSequence &+= 1; connecting = false; token = ""; isSignedIn = false; history = .empty; watchedEpisodes = []; episodeFractions = [:]; status = "Sign in to Anime Sync"
        let old = players.values; players.removeAll(); for lease in old { lease.invalidate(); onOwnershipLost?(lease) }
    }
    func selectServer(_ origin: URL) throws {
        guard let canonical = AppWebPolicy.origin(origin), AppWebPolicy.dashboards.contains(canonical), let checked = URL(string: canonical) else { throw CoreError.message("Choose a known Anime Sync server") }
        guard checked != baseURL else { return }
        try signOut(); baseURL = checked; preferences.set(checked.absoluteString, forKey: "animesync.base")
    }
    private func request(origin: URL, path: String, body: JSONObject?, authName: String, auth: String, epoch: UInt64) async throws -> JSONObject {
        guard AppWebPolicy.isDashboard(origin), path.hasPrefix("/api/"), CoreHTTPTransport.isSafeHeaderValue(auth),
              let url = URL(string: path, relativeTo: origin)?.absoluteURL, AppWebPolicy.origin(url) == AppWebPolicy.origin(origin) else { throw CoreError.invalidResponse }
        var request = URLRequest(url: url); request.httpMethod = body == nil ? "GET" : "POST"; request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue(auth, forHTTPHeaderField: authName)
        if let body = body { request.httpBody = try JSONEncoder().encode(body) }
        let reply = try await transport.request(request, maxBytes: path == "/api/progress" && body == nil ? 8_000_000 : 1_000_000)
        try Task.checkCancellation(); try sameAccount(epoch)
        if reply.status == 401 { throw CoreError.unauthorized }
        if reply.status == 409 {
            let json = try? JSONValue.parseObject(reply.body)
            throw CoreError.conflict(json?["error"]?.string ?? "Playback continued on another device")
        }
        guard (200..<300).contains(reply.status) else { throw CoreError.http(reply.status) }
        return try JSONValue.parseObject(reply.body)
    }
    private func authorized(_ path: String, body: JSONObject? = nil, epoch: UInt64) async throws -> JSONObject {
        try sameAccount(epoch); guard !token.isEmpty else { throw CoreError.unauthorized }
        return try await request(origin: baseURL, path: path, body: body, authName: "Authorization", auth: "Bearer " + token, epoch: epoch)
    }
    func connect(origin: URL, cookies: [HTTPCookie]) async throws {
        guard let canonical = AppWebPolicy.origin(origin), AppWebPolicy.dashboards.contains(canonical), let checked = URL(string: canonical), let host = checked.host else { throw CoreError.message("Choose a known Anime Sync server") }
        if !token.isEmpty && checked == baseURL { await refreshHistory(); return }
        guard !connecting else { return }
        let applicable = cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return (host == domain || host.hasSuffix("." + domain)) && !(cookie.expiresDate.map { $0 < Date() } ?? false)
                && CoreHTTPTransport.isSafeHeaderValue(cookie.name) && CoreHTTPTransport.isSafeHeaderValue(cookie.value)
        }
        guard !applicable.isEmpty else { throw CoreError.message("Finish signing in to Anime Sync") }
        let header = HTTPCookie.requestHeaderFields(with: applicable)["Cookie"] ?? ""
        guard !header.isEmpty else { throw CoreError.message("Finish signing in to Anime Sync") }
        connecting = true; connectSequence &+= 1; let ticket = connectSequence, epoch = accountEpoch
        defer { if ticket == connectSequence { connecting = false } }
        do { try await queue.run { [self] in
            try sameAccount(epoch); guard ticket == connectSequence else { throw CancellationError() }
            let result = try await request(origin: checked, path: "/api/device-session", body: ["device_id": .string(deviceID)], authName: "Cookie", auth: header, epoch: epoch)
            guard ticket == connectSequence, let next = result["token"]?.string, Self.validToken(next) else { throw CoreError.invalidResponse }
            try secrets.write(JSONEncoder().encode(StoredSession(origin: checked, token: next, deviceID: deviceID)), for: "sync.session")
            baseURL = checked; token = next; isSignedIn = true; accountEpoch &+= 1
            episodeFractions = [:]
            preferences.set(checked.absoluteString, forKey: "animesync.base"); status = "Synced with Anime Sync"
            await flushPendingLocked()
        }} catch { if ticket == connectSequence { status = "Sign in to enable sync" }; throw error }
        await refreshHistory()
    }
    func isEpisodeWatched(site: String = "miruro",animeID: String,episode: String) -> Bool {
        guard let key = EpisodeProgressKey(site: site,animeID: animeID,episode: episode) else { return false }
        return watchedEpisodes.contains(key)
    }
    func episodeProgress(site: String = "miruro",animeID: String,episode: String) -> Double? {
        guard isSignedIn, let key = EpisodeProgressKey(site: site,animeID: animeID,episode: episode) else { return nil }
        return episodeFractions[key]
    }
    @discardableResult func refreshHistory(retryPending: Bool = false) async -> Bool {
        do { _ = try await readHistory(retryPending: retryPending); return true }
        catch { return false }
    }
    private func readHistory(retryPending: Bool = false, animeID: String? = nil) async throws -> HistoryEntry? {
        guard !token.isEmpty else { throw CoreError.unauthorized }; let epoch = accountEpoch
        do { let result = try await queue.run { [self] () async throws -> (HomeHistorySnapshot,Set<EpisodeProgressKey>,[EpisodeProgressKey: Double],HistoryEntry?) in
            try sameAccount(epoch)
            if retryPending { await flushPendingLocked() }
            let response = try await authorized("/api/progress", epoch: epoch)
            guard let rows = response["progress"]?.array else { throw CoreError.invalidResponse }
            let entries = rows.compactMap { $0.object.flatMap(HistoryEntry.init(json:)) }
            let latest = HomeHistory.latestEntries(entries)
            return (HomeHistory.presentation(latest),WatchedEpisodeIndex.select(entries),HomeHistory.episodeFractions(entries),
                    animeID.flatMap { id in latest.first { $0.animeID == id } })
        }; try Task.checkCancellation(); try sameAccount(epoch)
            if history != result.0 { history = result.0 }
            if watchedEpisodes != result.1 { watchedEpisodes = result.1 }
            if episodeFractions != result.2 { episodeFractions = result.2 }
            if status == Self.historyRefreshFailure { status = "Synced with Anime Sync" }
            return result.3
        } catch CoreError.unauthorized {
            if epoch == accountEpoch { clearUnauthorized() }
            throw CoreError.unauthorized
        } catch is CancellationError { throw CancellationError() }
        catch {
            if epoch == accountEpoch, status != Self.historyRefreshFailure { status = Self.historyRefreshFailure }
            throw error
        }
    }
    func pollContinueWatching() async {
        let clock = ContinuousClock()
        while isSignedIn && !Task.isCancelled {
            let started = clock.now
            let refreshed = await refreshHistory(retryPending: true)
            let deadline = refreshed ? started.advanced(by: .seconds(1)) : clock.now.advanced(by: .seconds(5))
            do { try await clock.sleep(until: deadline) } catch { return }
        }
    }
    /// The selected series can be outside the rows displayed on Home.
    func freshCheckpoint(animeID: String) async throws -> HistoryEntry? {
        try await readHistory(animeID: animeID)
    }
    private func progressPath(_ metadata: AnimeMetadata) -> String {
        var parts = URLComponents(); parts.path = "/api/progress"
        parts.queryItems = [URLQueryItem(name: "site", value: "miruro"), URLQueryItem(name: "anime_id", value: metadata.animeID), URLQueryItem(name: "episode", value: metadata.episode)]
        return parts.string!
    }
    private func head(_ metadata: AnimeMetadata, epoch: UInt64) async throws -> (JSONObject, ResumeSnapshot) {
        let response = try await authorized(progressPath(metadata), epoch: epoch)
        guard let sync = response["sync"]?.object, let generation = sync["generation"]?.integer, generation >= 0 else { throw CoreError.message("Sync server update required") }
        let saved = response["progress"]?.object
        let position = saved.map { AppWebPolicy.resume(position: $0["current_time"]?.double ?? 0, duration: $0["duration"]?.double ?? 0, completed: $0["completed"]?.bool ?? false) } ?? 0
        return (response, ResumeSnapshot(position: position, generation: generation, sessionID: sync["session_id"]?.string))
    }
    func resume(metadata: AnimeMetadata, continueFrom checkpointEpisode: String? = nil) async throws -> ResumeSnapshot {
        guard metadata.isValid else { throw CoreError.invalidMetadata }; guard !token.isEmpty else { return ResumeSnapshot(position: 0, generation: 0, sessionID: nil) }
        let epoch = accountEpoch
        do { return try await queue.run { [self] in
            let (response, snapshot) = try await head(metadata, epoch: epoch)
            if let checkpointEpisode, let active = response["sync"]?.object?["episode"]?.string,
               !(snapshot.sessionID ?? "").isEmpty, !active.isEmpty {
                guard AppWebPolicy.identity(animeID: metadata.animeID,episode: active),
                      Double(active) == Double(metadata.episode) || Double(active) == Double(checkpointEpisode) else {
                    throw CoreError.conflict("Playback moved to another episode. Try Continue again.")
                }
            }
            if let checkpointEpisode, checkpointEpisode != metadata.episode,
               response["progress"]?.object?["completed"]?.bool == true {
                throw CoreError.conflict("The next episode is already watched. Choose Continue again.")
            }
            return snapshot
        } }
        catch CoreError.unauthorized { if epoch == accountEpoch { clearUnauthorized() }; throw CoreError.unauthorized }
    }
    func begin(metadata: AnimeMetadata, explicit: Bool, expectedSourceGeneration: Int64? = nil) async throws -> PlaybackStart {
        guard metadata.isValid else { throw CoreError.invalidMetadata }
        guard !token.isEmpty else { return PlaybackStart(allowed: true, lease: nil, resumePosition: nil, message: nil) }
        let epoch = accountEpoch
        do { return try await queue.run { [self] in
            try sameAccount(epoch); await flushPendingLocked(); try sameAccount(epoch)
            let (_, snapshot) = try await head(metadata, epoch: epoch)
            if let expected = expectedSourceGeneration, expected != snapshot.generation { throw CoreError.conflict("Playback continued on another device. Press Play to resume its latest position.") }
            if !explicit && !(snapshot.sessionID ?? "").isEmpty { throw CoreError.conflict("Press Play to continue on this device") }
            let id = UUID().uuidString
            let reply = try await authorized("/api/playback", body: ["site": .string("miruro"), "anime_id": .string(metadata.animeID), "episode": .string(metadata.episode), "device_id": .string(deviceID), "playback_session_id": .string(id), "expected_generation": .integer(snapshot.generation)], epoch: epoch)
            guard let sync = reply["sync"]?.object, let generation = sync["generation"]?.integer, generation >= 0 else { throw CoreError.invalidResponse }
            let lease = PlaybackLease(id: id, generation: generation, accountEpoch: epoch); players[id] = lease
            let saved = reply["progress"]?.object
            let position = saved.map { AppWebPolicy.resume(position: $0["current_time"]?.double ?? 0, duration: $0["duration"]?.double ?? 0, completed: $0["completed"]?.bool ?? false) }
            status = "Synced with Anime Sync"
            return PlaybackStart(allowed: true, lease: lease, resumePosition: position, message: nil)
        }} catch CoreError.conflict(let message) { status = message; return PlaybackStart(allowed: false, lease: nil, resumePosition: nil, message: message) }
        catch CoreError.unauthorized { if epoch == accountEpoch { clearUnauthorized() }; return PlaybackStart(allowed: true, lease: nil, resumePosition: nil, message: "Sign in to resume sync") }
        catch is CancellationError { throw CancellationError() }
        catch { status = "Offline · progress held on this device"; return PlaybackStart(allowed: true, lease: nil, resumePosition: nil, message: status) }
    }
    func release(_ lease: PlaybackLease?) { if let lease = lease, players[lease.id] === lease { players.removeValue(forKey: lease.id) } }
    func progress(metadata: AnimeMetadata, lease: PlaybackLease?, position: TimeInterval, duration: TimeInterval, ended: Bool = false) async {
        guard metadata.isValid, position.isFinite, duration.isFinite, duration > 0, position >= 0, position <= duration + 60 else { return }
        if let lease = lease, !lease.isValid || lease.accountEpoch != accountEpoch { return }
        var payload = metadata.json; payload["device_id"] = .string(deviceID); payload["current_time"] = .number(position)
        payload["duration"] = .number(duration); payload["completed"] = .bool(ended || position / duration >= 0.9)
        guard let lease = lease, let sequence = lease.nextSequence() else {
            if let data = try? JSONEncoder().encode(payload) { preferences.set(data, forKey: heldPrefix + metadata.animeID + ":" + metadata.episode) }
            return
        }
        payload["sync_protocol"] = .integer(2); payload["playback_session_id"] = .string(lease.id)
        payload["playback_generation"] = .integer(lease.generation); payload["playback_sequence"] = .integer(sequence)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        preferences.set(data, forKey: pendingPrefix + lease.id)
        _ = try? await queue.run { [self] in await flushPendingLocked() }
    }
    private func pendingKeys() -> [String] { preferences.dictionaryRepresentation().keys.filter { $0.hasPrefix(pendingPrefix) }.sorted() }
    private func flushPendingLocked() async {
        guard !token.isEmpty else { return }; let epoch = accountEpoch
        for key in pendingKeys() {
            guard let snapshot = preferences.data(forKey: key) else { continue }
            guard let body = try? JSONValue.parseObject(snapshot) else { preferences.set(snapshot, forKey: heldPrefix + key); preferences.removeObject(forKey: key); continue }
            guard body["sync_protocol"]?.integer == 2 else { preferences.set(snapshot, forKey: heldPrefix + key); if preferences.data(forKey: key) == snapshot { preferences.removeObject(forKey: key) }; continue }
            do {
                _ = try await authorized("/api/progress", body: body, epoch: epoch)
                if preferences.data(forKey: key) == snapshot { preferences.removeObject(forKey: key) }
                if let id = body["anime_id"]?.string, let episode = body["episode"]?.string { preferences.removeObject(forKey: heldPrefix + id + ":" + episode) }
                status = "Synced with Anime Sync"
            } catch CoreError.conflict {
                // The newest queued sample for this invalidated session also belongs in held storage.
                let latest = preferences.data(forKey: key) ?? snapshot
                preferences.set(latest, forKey: heldPrefix + key); preferences.removeObject(forKey: key)
                let id = String(key.dropFirst(pendingPrefix.count))
                if let lease = players[id], lease.isValid, lease.generation == body["playback_generation"]?.integer { lease.invalidate(); onOwnershipLost?(lease) }
                status = "Playback continued on another device · press Play to resume here"
            } catch CoreError.unauthorized { if epoch == accountEpoch { clearUnauthorized() }; return }
            catch is CancellationError { return }
            catch { status = "Progress saved here; retrying when connected"; return }
        }
    }
    func flushForHandoff(metadata: AnimeMetadata? = nil, lease: PlaybackLease? = nil) async throws -> HandoffSnapshot {
        try await queue.run { [self] in
            await flushPendingLocked()
            guard pendingKeys().isEmpty else { return HandoffSnapshot(saved: false, position: nil, generation: nil) }
            if let lease = lease {
                guard !token.isEmpty, lease.accountEpoch == accountEpoch, lease.isValid, lease.sequence > 0, preferences.data(forKey: heldPrefix + pendingPrefix + lease.id) == nil else { return HandoffSnapshot(saved: false, position: nil, generation: nil) }
                return HandoffSnapshot(saved: true, position: nil, generation: lease.generation)
            }
            guard let metadata = metadata, metadata.isValid else { return HandoffSnapshot(saved: true, position: nil, generation: nil) }
            guard preferences.data(forKey: heldPrefix + metadata.animeID + ":" + metadata.episode) == nil, !token.isEmpty else { return HandoffSnapshot(saved: false, position: nil, generation: nil) }
            let epoch = accountEpoch
            let (response, snapshot) = try await head(metadata, epoch: epoch)
            let rawPosition = response["progress"]?.object?["current_time"]?.double ?? 0
            guard rawPosition.isFinite, rawPosition >= 0 else { return HandoffSnapshot(saved: false, position: nil, generation: nil) }
            return HandoffSnapshot(saved: true, position: rawPosition, generation: snapshot.generation)
        }
    }
    func flushPending() async { _ = try? await queue.run { [self] in await flushPendingLocked() } }
}
