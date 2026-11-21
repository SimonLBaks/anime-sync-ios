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
    private struct PlaybackPresence {
        let metadata: AnimeMetadata
        var task: Task<Void, Never>?
    }
    private var presence: [String: PlaybackPresence] = [:]
    private var releasingPresence: [String: (sessionID: String, task: Task<Void, Never>)] = [:]
    private enum PlaybackConflict: Error {
        case active(PlaybackTakeover)
        case handoffPending
        case superseded
    }
    private let pendingPrefix = "animesync.pending:"
    private let heldPrefix = "animesync.held:"
    private static let historyRefreshFailure = "Could not refresh history. Check your connection."
    var historyRefreshFailed: Bool { status == Self.historyRefreshFailure }
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
        invalidatePlayers()
    }
    func signOut() throws {
        try secrets.write(nil, for: "sync.session")
        accountEpoch &+= 1; connectSequence &+= 1; connecting = false; token = ""; isSignedIn = false; history = .empty; watchedEpisodes = []; episodeFractions = [:]; status = "Sign in to Anime Sync"
        invalidatePlayers()
    }
    private func invalidatePlayers() {
        for monitor in presence.values { monitor.task?.cancel() }
        presence.removeAll()
        for release in releasingPresence.values { release.task.cancel() }
        releasingPresence.removeAll()
        let old = players.values
        players.removeAll()
        for lease in old { lease.invalidate(); onOwnershipLost?(lease) }
    }
    func selectServer(_ origin: URL) throws {
        guard let canonical = AppWebPolicy.origin(origin), AppWebPolicy.dashboards.contains(canonical), let checked = URL(string: canonical) else { throw CoreError.message("Choose a known Anime Sync server") }
        guard checked != baseURL else { return }
        try signOut(); baseURL = checked; preferences.set(checked.absoluteString, forKey: "animesync.base")
    }
    private func request(origin: URL, path: String, body: JSONObject?, authName: String, auth: String, epoch: UInt64) async throws -> JSONObject {
        guard AppWebPolicy.isDashboard(origin), path.hasPrefix("/api/"), CoreHTTPTransport.isSafeHeaderValue(auth),
              let url = URL(string: path, relativeTo: origin)?.absoluteURL, AppWebPolicy.origin(url) == AppWebPolicy.origin(origin) else { throw CoreError.invalidResponse }
        var request = URLRequest(url: url); request.httpMethod = body == nil ? "GET" : "POST"
        request.timeoutInterval = path == "/api/playback/presence" ? 2.5 : 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue(auth, forHTTPHeaderField: authName)
        if let body = body { request.httpBody = try JSONEncoder().encode(body) }
        let reply = try await transport.request(request, maxBytes: path == "/api/progress" && body == nil ? 8_000_000 : 1_000_000)
        try Task.checkCancellation(); try sameAccount(epoch)
        if reply.status == 401 { throw CoreError.unauthorized }
        if reply.status == 409 {
            let json = try? JSONValue.parseObject(reply.body)
            let code = json?["code"]?.string
            if path == "/api/playback", code == "playback_active",
               let sync = json?["sync"]?.object, let generation = sync["generation"]?.integer, generation >= 0 {
                throw PlaybackConflict.active(PlaybackTakeover(generation: generation, deviceLabel: sync["active_device_label"]?.string ?? ""))
            }
            if path == "/api/playback", code == "playback_handoff_pending" { throw PlaybackConflict.handoffPending }
            if path == "/api/playback/presence", code == "playback_superseded" { throw PlaybackConflict.superseded }
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
    func begin(metadata: AnimeMetadata, explicit: Bool, expectedSourceGeneration: Int64? = nil,
               resumeOpenPlayer: Bool = false, previousLease: PlaybackLease? = nil,
               confirmedTakeover: PlaybackTakeover? = nil, allowsTakeoverPrompt: Bool = true) async throws -> PlaybackStart {
        guard metadata.isValid else { throw CoreError.invalidMetadata }
        guard !token.isEmpty else {
            return PlaybackStart(allowed: confirmedTakeover == nil, lease: nil, resumePosition: nil,
                                 message: confirmedTakeover == nil ? nil : "Sign in to resume sync")
        }
        let epoch = accountEpoch
        if let release = releasingPresence[metadata.animeID] { await release.task.value }
        try Task.checkCancellation()
        do { return try await queue.run { [self] in
            try sameAccount(epoch)
            let outgoing = previousLease.flatMap { $0.accountEpoch == epoch ? $0 : nil }
            if let outgoing { await flushPendingLocked(keys: [pendingPrefix + outgoing.id]) }
            else { await flushPendingLocked() }
            try sameAccount(epoch)
            let (response, snapshot) = try await head(metadata, epoch: epoch)
            if let confirmedTakeover, confirmedTakeover.generation != snapshot.generation {
                throw CoreError.conflict("Playback changed. Press Play to check again.")
            }
            if let expected = expectedSourceGeneration, expected != snapshot.generation {
                if explicit, allowsTakeoverPrompt, confirmedTakeover == nil, !(snapshot.sessionID ?? "").isEmpty,
                   let sync = response["sync"]?.object, sync["presence_protocol"]?.integer == 1, sync["active"]?.bool == true,
                   let episode = sync["episode"]?.string, AppWebPolicy.identity(animeID: metadata.animeID,episode: episode),
                   Double(episode) == Double(metadata.episode) {
                    throw PlaybackConflict.active(PlaybackTakeover(generation: snapshot.generation, deviceLabel: sync["active_device_label"]?.string ?? ""))
                }
                throw CoreError.conflict("Playback continued on another device. Press Play to resume its latest position.")
            }
            if !explicit && !(snapshot.sessionID ?? "").isEmpty { throw CoreError.conflict("Press Play to continue on this device") }
            if let outgoing {
                let key = pendingPrefix + outgoing.id
                if let unsent = preferences.data(forKey: key) {
                    if outgoing.generation == snapshot.generation {
                        status = "Progress saved here; retrying when connected"
                        return PlaybackStart(allowed: false, lease: nil, resumePosition: nil,
                                             message: "Your position is saved on this device. Press Play to retry syncing.")
                    }
                    // A newer head makes the old packet stale even if the write
                    // endpoint was unavailable when we tried to send it.
                    preferences.set(unsent, forKey: heldPrefix + key)
                    preferences.removeObject(forKey: key)
                }
            }
            let id = UUID().uuidString
            var body: JSONObject = ["site": .string("miruro"), "anime_id": .string(metadata.animeID), "episode": .string(metadata.episode),
                                    "device_id": .string(deviceID), "playback_session_id": .string(id), "expected_generation": .integer(snapshot.generation),
                                    "presence_protocol": .integer(1), "device_label": .string("iPhone")]
            if confirmedTakeover != nil { body["confirm_takeover"] = .bool(true) }
            let reply = try await claimPlayback(body, confirmed: confirmedTakeover != nil, epoch: epoch)
            guard let sync = reply["sync"]?.object, let generation = sync["generation"]?.integer, generation >= 0 else { throw CoreError.invalidResponse }
            let lease = PlaybackLease(id: id, generation: generation, accountEpoch: epoch, supportsPresence: sync["presence_protocol"]?.integer == 1)
            players[id] = lease
            if lease.supportsPresence { presence[id] = PlaybackPresence(metadata: metadata) }
            let position: TimeInterval?
            if resumeOpenPlayer || confirmedTakeover != nil && reply["progress"]?.object != nil {
                guard let saved = reply["progress"]?.object, let time = saved["current_time"]?.double,
                      let duration = saved["duration"]?.double, time.isFinite, duration.isFinite,
                      duration > 0, time >= 0, time <= duration else {
                    release(lease)
                    return PlaybackStart(allowed: false, lease: nil, resumePosition: nil,
                                         message: "Could not confirm the synced position. Press Play to try again.")
                }
                position = time
            } else {
                position = reply["progress"]?.object.map {
                    AppWebPolicy.resume(position: $0["current_time"]?.double ?? 0, duration: $0["duration"]?.double ?? 0, completed: $0["completed"]?.bool ?? false)
                }
            }
            status = "Synced with Anime Sync"
            return PlaybackStart(allowed: true, lease: lease, resumePosition: position, message: nil)
        }} catch PlaybackConflict.active(let takeover) {
            return PlaybackStart(allowed: false, lease: nil, resumePosition: nil, message: takeover.title,
                                 takeover: explicit && allowsTakeoverPrompt ? takeover : nil)
        } catch CoreError.conflict(let message) { status = message; return PlaybackStart(allowed: false, lease: nil, resumePosition: nil, message: message) }
        catch CoreError.unauthorized {
            if epoch == accountEpoch { clearUnauthorized() }
            return PlaybackStart(allowed: confirmedTakeover == nil, lease: nil, resumePosition: nil, message: "Sign in to resume sync")
        }
        catch is CancellationError { throw CancellationError() }
        catch {
            if confirmedTakeover != nil {
                return PlaybackStart(allowed: false, lease: nil, resumePosition: nil, message: "Could not switch devices. Press Play to try again.")
            }
            status = "Offline · progress held on this device"
            return PlaybackStart(allowed: true, lease: nil, resumePosition: nil, message: status)
        }
    }
    private func claimPlayback(_ body: JSONObject, confirmed: Bool, epoch: UInt64) async throws -> JSONObject {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while true {
            do { return try await authorized("/api/playback", body: body, epoch: epoch) }
            catch PlaybackConflict.handoffPending {
                guard confirmed, clock.now < deadline else { throw CoreError.conflict("Could not switch devices. Press Play to try again.") }
                try await clock.sleep(for: .milliseconds(400))
            }
        }
    }
    private func updatePresence(_ lease: PlaybackLease, metadata: AnimeMetadata, state: String) async throws -> JSONObject {
        let body: JSONObject = ["site": .string("miruro"), "anime_id": .string(metadata.animeID), "episode": .string(metadata.episode),
                                "device_id": .string(deviceID), "playback_session_id": .string(lease.id),
                                "playback_generation": .integer(lease.generation), "state": .string(state)]
        let response = try await authorized("/api/playback/presence", body: body, epoch: lease.accountEpoch)
        guard let sync = response["sync"]?.object else { throw CoreError.invalidResponse }
        return sync
    }
    func observePresence(_ lease: PlaybackLease, onHandoffRequested: @escaping @MainActor () -> Void) {
        guard let observation = presence[lease.id], observation.task == nil, players[lease.id] === lease, lease.isValid else { return }
        let metadata = observation.metadata
        presence[lease.id]?.task = Task { [weak self, weak lease] in
            let clock = ContinuousClock()
            while !Task.isCancelled, let self, let lease, self.players[lease.id] === lease, lease.isValid {
                var interval: Duration = .seconds(1)
                let started = clock.now
                do {
                    let sync = try await self.updatePresence(lease, metadata: metadata, state: "playing")
                    guard !Task.isCancelled, self.players[lease.id] === lease, lease.isValid else { return }
                    if sync["handoff_requested"]?.bool == true { onHandoffRequested(); return }
                } catch PlaybackConflict.superseded {
                    guard !Task.isCancelled, self.players[lease.id] === lease, lease.isValid else { return }
                    lease.invalidate(); self.onOwnershipLost?(lease)
                    return
                } catch CoreError.unauthorized {
                    if !Task.isCancelled, lease.accountEpoch == self.accountEpoch { self.clearUnauthorized() }
                    return
                } catch is CancellationError { return }
                catch { interval = .seconds(2) }
                do { try await clock.sleep(until: started.advanced(by: interval)) } catch { return }
            }
        }
    }
    func suspendPresence(_ lease: PlaybackLease?) {
        guard let lease else { return }
        presence[lease.id]?.task?.cancel()
        presence[lease.id]?.task = nil
    }
    func retirePresence(_ lease: PlaybackLease?) async throws {
        guard let lease, players[lease.id] === lease, lease.isValid,
              let observation = presence[lease.id] else { return }
        observation.task?.cancel()
        _ = try await updatePresence(lease, metadata: observation.metadata, state: "paused")
        presence.removeValue(forKey: lease.id)
    }
    func release(_ lease: PlaybackLease?) {
        guard let lease, players[lease.id] === lease else { return }
        players.removeValue(forKey: lease.id)
        guard let observation = presence.removeValue(forKey: lease.id) else { return }
        observation.task?.cancel()
        if lease.isValid, lease.accountEpoch == accountEpoch {
            let animeID = observation.metadata.animeID
            let previous = releasingPresence[animeID]?.task
            let task = Task { [weak self] in
                if let previous { await previous.value }
                guard let self else { return }
                defer {
                    if self.releasingPresence[animeID]?.sessionID == lease.id { self.releasingPresence.removeValue(forKey: animeID) }
                }
                guard !Task.isCancelled, lease.accountEpoch == self.accountEpoch else { return }
                if self.preferences.data(forKey: self.pendingPrefix + lease.id) != nil {
                    _ = try? await self.queue.run { await self.flushPendingLocked(keys: [self.pendingPrefix + lease.id]) }
                }
                _ = try? await self.updatePresence(lease, metadata: observation.metadata, state: "paused")
            }
            releasingPresence[animeID] = (lease.id, task)
        }
    }
    func progress(metadata: AnimeMetadata, lease: PlaybackLease?, position: TimeInterval, duration: TimeInterval, ended: Bool = false) async {
        guard enqueueProgress(metadata: metadata,lease: lease,position: position,duration: duration,ended: ended) else { return }
        await flushPending()
    }
    @discardableResult func enqueueProgress(metadata: AnimeMetadata, lease: PlaybackLease?, position: TimeInterval, duration: TimeInterval, ended: Bool = false) -> Bool {
        guard metadata.isValid, position.isFinite, duration.isFinite, duration > 0, position >= 0, position <= duration + 60 else { return false }
        if let lease = lease, !lease.isValid || lease.accountEpoch != accountEpoch { return false }
        var payload = metadata.json; payload["device_id"] = .string(deviceID); payload["current_time"] = .number(position)
        payload["duration"] = .number(duration); payload["completed"] = .bool(ended || position / duration >= 0.9)
        guard let lease = lease, let sequence = lease.nextSequence() else {
            if let data = try? JSONEncoder().encode(payload) { preferences.set(data, forKey: heldPrefix + metadata.animeID + ":" + metadata.episode) }
            return false
        }
        payload["sync_protocol"] = .integer(2); payload["playback_session_id"] = .string(lease.id)
        payload["playback_generation"] = .integer(lease.generation); payload["playback_sequence"] = .integer(sequence)
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        preferences.set(data, forKey: pendingPrefix + lease.id)
        return true
    }
    private func pendingKeys() -> [String] { preferences.dictionaryRepresentation().keys.filter { $0.hasPrefix(pendingPrefix) }.sorted() }
    private func flushPendingLocked(keys: [String]? = nil) async {
        guard !token.isEmpty else { return }; let epoch = accountEpoch
        for key in keys ?? pendingKeys() {
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
