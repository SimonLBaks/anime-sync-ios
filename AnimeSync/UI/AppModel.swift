import SwiftUI
import Combine
import WebKit

struct AppRoute: Equatable {
    var section: String
    var url: URL?
    var website = false
    var panel: String?
    static let home = AppRoute(section: "Home")
}
struct TakeoverRequest: Identifiable {
    let id = UUID()
    let observed: TVState
    let action: (TVControlLease) async throws -> Void
}

@MainActor final class AppModel: ObservableObject {
    let sync: SyncService
    let tv: TVClient
    let provider: MiruroProvider
    let dashboard: DashboardProvider
    let discovery = TVDiscovery()
    let fixture: Bool
    #if DEBUG
    let qa: QAFixture?
    #endif
    @Published var route = AppRoute.home
    @Published var drawer = false
    @Published var tvPanel = false
    @Published var pairingSheet = false
    @Published var message: String?
    @Published var takeover: TakeoverRequest?
    @Published var player: NativePlaybackModel?
    @Published var searchText = ""
    @Published var libraryQuery = ""
    @Published var libraryFilter = "continue"
    @Published var signingIn = false
    @Published var busy = false
    @Published var selectedSourceID = ""
    private var routes: [AppRoute] = []
    private var idle: Task<Void,Never>?
    private var pendingPlay = false
    private var resolvingEpoch: UInt64 = 0
    private var pendingResume: ResumeSnapshot?
    private var pendingSourceGeneration: Int64?
    private var browserLease: PlaybackLease?
    private var browserMetadata: AnimeMetadata?
    private var browserEpoch: UInt64 = 0
    private var browserStarting = false
    private var browserReady = false
    private var browserLocalOnly = false
    private var browserStartTask: Task<Void,Never>?
    private var launchTask: Task<Void,Never>?
    private var launchTicket: UUID?
    private var pendingTVLease: TVControlLease?
    private var pendingTVEpisode: TVState?
    private var nativeSubtitleContext: (player: UUID, navigation: UInt64, account: UInt64, source: UInt64)?
    private var active = true
    private var handingOff = false
    private var signInProviderURL: URL?
    private var subscriptions: Set<AnyCancellable> = []

    init(sync: SyncService, tv: TVClient, fixture: Bool = false) {
        self.sync = sync; self.tv = tv; self.fixture = fixture
        provider = MiruroProvider(fixture: fixture); dashboard = DashboardProvider(fixture: fixture)
        #if DEBUG
        qa = nil
        #endif
        wire()
    }
    #if DEBUG
    init(qa: QAFixture,liveProvider: Bool = false) {
        self.qa = qa; fixture = true; sync = qa.makeSync(); tv = qa.makeTV()
        provider = MiruroProvider(fixture: !liveProvider); dashboard = DashboardProvider(fixture: true)
        if !liveProvider { qa.seedProvider(provider) }
        qa.seedDashboard(dashboard); wire()
        qa.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }
    #endif
    private func wire() {
        // Forward child publications because navigation and sheets share one native model.
        sync.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        tv.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        provider.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        dashboard.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        provider.onWatchRequested = { [weak self] url in self?.open(url, replacing: self?.route.section == "Episode") }
        dashboard.onWatchRequested = { [weak self] url in self?.open(url) }
        dashboard.onAuthenticated = { [weak self] origin,cookies in
            guard let self else { return }
            let epoch = self.resolvingEpoch
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.sync.connect(origin: origin,cookies: cookies)
                    if epoch == self.resolvingEpoch, self.active { self.finishSignIn() }
                } catch { if epoch == self.resolvingEpoch { self.message = error.localizedDescription } }
            }
        }
        provider.onBrowserPlayback = { [weak self] event in self?.receiveBrowser(event) }
        provider.$subtitles.sink { [weak self] sources in
            self?.forwardNativeSubtitles(sources)
        }.store(in: &subscriptions)
        sync.onOwnershipLost = { [weak self] lease in
            guard let self, self.browserLease === lease else { return }; self.clearBrowser(); self.message = "Playback continued on another device. Press Play to resume here."
        }
        sync.$isSignedIn.dropFirst().sink { [weak self] signedIn in
            if !signedIn { self?.clearSelection(); self?.clearBrowser() }
        }.store(in: &subscriptions)
    }
    func start() async {
        provider.browse(section: "Home"); dashboard.load(origin: sync.baseURL,accountGeneration: sync.accountGeneration)
        tv.startPolling(); await sync.flushPending(); await sync.refreshHistory()
    }
    func touchDrawer() {
        idle?.cancel(); guard drawer else { return }
        idle = Task { [weak self] in do { try await Task.sleep(nanoseconds: 5_000_000_000); self?.drawer = false } catch {} }
    }
    func toggleDrawer() { drawer.toggle(); touchDrawer() }
    func navigate(_ section: String) {
        drawer = false
        if section == "TV" { tvPanel = true; return }
        if section == "Home" { routes = []; show(.home); return }
        let website = ["Schedule","Announcements","Profile","Login"].contains(section)
        let path = section == "Login" ? "/" : "/" + section.lowercased()
        let next = AppRoute(section: section,url: website ? URL(string: "https://miruro.cx" + path) : nil,website: website,panel: section == "Login" ? "Login" : nil)
        if route != next { routes.append(route); show(next) }
    }
    private func show(_ next: AppRoute) {
        clearSelection(); clearBrowser()
        route = next; signingIn = false; signInProviderURL = nil
        if next.website, let url = next.url { provider.openWebsite(section: next.section,url: url,panel: next.panel) }
        else if next.section == "Anime Sync" { provider.stop(); dashboard.load(origin: sync.baseURL,accountGeneration: sync.accountGeneration) }
        else if next.section == "Settings" || next.section == "History" { provider.stop() }
        else if let url = next.url { provider.browse(section: next.section,url: url) }
        else { provider.browse(section: next.section) }
        if next.section == "Home" || next.section == "History" { Task { await sync.refreshHistory() } }
    }
    func back() async {
        if drawer { drawer = false; return }
        if player != nil { await closePlayer(); return }
        if pairingSheet { tv.cancelPairing(); pairingSheet = false; return }
        if tvPanel { tvPanel = false; return }
        if signingIn { if await dashboard.safeWebBack() { return }; finishSignIn(); return }
        if route.website, await provider.back() { return }
        if let previous = routes.popLast() { show(previous) }
        else if route != .home { show(.home) }
        else { drawer = true; touchDrawer() }
    }
    func search() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),to: nil,from: nil,for: nil)
        clearSelection(); clearBrowser(); provider.search(query)
    }
    func open(_ url: URL, replacing: Bool = false) {
        guard AppWebPolicy.isProvider(url) else { return }
        if !replacing { routes.append(route) }
        clearSelection(); clearBrowser(); signingIn = false; signInProviderURL = nil; route = AppRoute(section: "Episode",url: url)
        provider.browse(section: "Episode",url: url)
    }
    func continueWatching(_ entry: HistoryEntry) async {
        await continueWatching(animeID: entry.animeID)
    }
    func openLibraryCard(_ card: SyncLibraryCard) async {
        // New episodes are a deliberate next-episode action. Continue is a
        // series-head action and must not trust the dashboard's cached URL.
        guard card.continuing, !card.hasNew else {
            guard let url = libraryWatchURL(card) else { message = "Refresh this library entry before opening its episode."; return }
            open(url); return
        }
        let parts = card.id.split(separator: ":",omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "miruro",
              AppWebPolicy.identity(animeID: String(parts[1]),episode: "1"),
              let id = Int64(parts[1]) else {
            message = "Refresh your library before continuing this anime."; return
        }
        await continueWatching(animeID: String(id))
    }
    private func libraryWatchURL(_ card: SyncLibraryCard) -> URL? {
        guard ProviderPolicy.isLegacyNativeHistoryURL(card.url) else { return card.url }
        let key = card.id.split(separator: ":",omittingEmptySubsequences: false)
        let parameters = URLComponents(url: card.url,resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "ep" } ?? []
        guard key.count == 2, key[0] == "miruro", parameters.count <= 1 else { return nil }
        let episode = parameters.first?.value ?? (card.hasNew ? card.nextEpisode : card.episode)
        guard AppWebPolicy.identity(animeID: String(key[1]),episode: episode), let id = Int64(key[1]) else { return nil }
        var target = URLComponents(string: "https://miruro.cx/search")!
        target.queryItems = [URLQueryItem(name: "q",value: card.title)]
        target.fragment = "anime-sync-id=\(id)&anime-sync-ep=\(episode)"
        return target.url
    }
    private func continueWatching(animeID: String) async {
        guard !busy, active else { return }; busy = true; defer { busy = false }
        let epoch = resolvingEpoch, account = sync.accountGeneration, selectedRoute = route
        let fresh = await sync.freshContinue(animeID: animeID)
        guard active, epoch == resolvingEpoch, route == selectedRoute,
              account == sync.accountGeneration, !Task.isCancelled else { return }
        guard let fresh else { message = "Could not refresh this episode. Reconnect Anime Sync and try again."; return }
        do {
            // Capture ownership before source discovery, without promoting a
            // cached checkpoint into an explicit seek. Native begin selects the
            // position and rejects this fence if another device advances it.
            let source = try await sync.resume(metadata: fresh.metadata)
            guard active, epoch == resolvingEpoch, route == selectedRoute,
                  account == sync.accountGeneration, !Task.isCancelled else { return }
            let approvedWatch = fresh.watchURL.flatMap { AppWebPolicy.isProvider($0) && !ProviderPolicy.isLegacyNativeHistoryURL($0) ? $0 : nil }
            open(approvedWatch ?? fresh.resolverURL)
            pendingSourceGeneration = source.generation
        } catch {
            if active, epoch == resolvingEpoch, route == selectedRoute, account == sync.accountGeneration {
                message = "Could not refresh this episode. Reconnect Anime Sync and try again."
            }
        }
    }
    func playHere() async {
        guard let metadata = provider.metadata else { message = "Miruro is still finding this episode. Try again shortly."; return }
        guard !busy, !handingOff, active, player == nil, metadata == provider.metadata else { return }
        busy = true; defer { busy = false }
        if pendingResume?.generation == nil, pendingSourceGeneration == nil {
            let epoch = resolvingEpoch, account = sync.accountGeneration, selectedRoute = route
            do {
                let source = try await sync.resume(metadata: metadata)
                guard active, epoch == resolvingEpoch, route == selectedRoute,
                      account == sync.accountGeneration, metadata == provider.metadata,
                      player == nil, !Task.isCancelled else { return }
                pendingSourceGeneration = source.generation
            } catch {
                guard active, epoch == resolvingEpoch, route == selectedRoute,
                      account == sync.accountGeneration, metadata == provider.metadata,
                      player == nil, !Task.isCancelled else { return }
                // An explicit Play may remain local-only while offline. Continue
                // already required a fresh server snapshot before reaching here.
                pendingSourceGeneration = nil
            }
        }
        pendingPlay = true; launchIfReady()
        // The episode view shows live discovery status beside its visible website
        // fallback. A persistent toast would hide changes and suggest a stuck job.
        if provider.sources.isEmpty { message = nil; provider.browserCommand("play") }
    }
    func selectMiruroSource(id: String) {
        guard provider.sourceChoices.contains(where: { $0.id == id && !$0.selected }) else { return }
        guard player == nil else { message = "Close the player before changing the source."; return }
        clearSelection(); clearBrowser()
        provider.selectSourceChoice(id: id)
    }
    func selectEpisode(id: String) {
        guard player == nil, provider.episodes.contains(where: { $0.id == id }) else { return }
        clearSelection(); clearBrowser()
        provider.selectEpisode(id: id)
    }
    func launchIfReady() {
        guard active, pendingPlay, player == nil, launchTask == nil, let metadata = provider.metadata else { return }
        let source = selectedSourceID.isEmpty ? provider.sources.first : provider.sources.first { $0.id == selectedSourceID }
        guard let source, source.selectionRevision == provider.selectionRevision,
              source.choiceID == provider.selectedChoiceID else { return }
        if let lease = pendingTVLease {
            let ticket = UUID(); launchTicket = ticket
            let epoch = resolvingEpoch, account = sync.accountGeneration, selection = selectedSourceID,
                sourceRevision = provider.selectionRevision, choice = provider.selectedChoiceID
            launchTask = Task { [weak self] in
                guard let self else { return }
                defer { if self.launchTicket == ticket { self.launchTask = nil; self.launchTicket = nil } }
                do {
                    try await self.tv.validate(lease)
                    guard self.active, self.resolvingEpoch == epoch, self.sync.accountGeneration == account,
                          self.provider.metadata == metadata, self.selectedSourceID == selection,
                          self.provider.selectionRevision == sourceRevision, self.provider.selectedChoiceID == choice,
                          self.pendingPlay, self.pendingTVLease == lease, !Task.isCancelled,
                          self.pendingTVEpisode.map({ self.sameTVEpisode($0,self.tv.state) }) == true else { throw ProviderFailure.staleNavigation }
                    self.pendingTVLease = nil; self.pendingTVEpisode = nil; self.makePlayer(metadata: metadata,source: source)
                } catch {
                    if self.resolvingEpoch == epoch, !Task.isCancelled { self.pendingPlay = false; self.pendingResume = nil; self.pendingTVLease = nil; self.pendingTVEpisode = nil; self.message = error.localizedDescription }
                }
            }
        } else { makePlayer(metadata: metadata,source: source) }
    }
    private func makePlayer(metadata: AnimeMetadata,source: MediaSource) {
        pendingPlay = false; message = nil; clearBrowser()
        let identity = fixture ? AnimeMetadata(animeID: "",episode: "",title: metadata.title,watchURL: metadata.watchURL) : metadata
        let model = NativePlaybackModel(metadata: identity,source: source,subtitles: provider.subtitles,sync: sync,fixture: fixture,position: pendingResume?.position,generation: pendingResume?.generation ?? pendingSourceGeneration)
        model.onClose = { [weak self] in Task { await self?.closePlayer() } }
        model.onFallback = { [weak self] in Task { await self?.closePlayer(); self?.website() } }
        player = model
        nativeSubtitleContext = (model.id,resolvingEpoch,sync.accountGeneration,provider.selectionRevision)
        forwardNativeSubtitles(provider.subtitles)
        pendingResume = nil; pendingSourceGeneration = nil
    }
    private func forwardNativeSubtitles(_ sources: [SubtitleSource]) {
        guard active, let player, let context = nativeSubtitleContext,
              context.player == player.id, context.navigation == resolvingEpoch,
              context.account == sync.accountGeneration, context.source == provider.selectionRevision,
              provider.metadata == player.metadata else { return }
        player.updateSubtitles(sources.filter { $0.selectionRevision == context.source && $0.choiceID == player.source.choiceID })
    }
    func closePlayer() async { guard let current = player else { return }; await current.close(); if player === current { player = nil; nativeSubtitleContext = nil }; await sync.refreshHistory() }
    func website(panel: String? = nil) {
        let url = provider.currentURL
        let next = AppRoute(section: route.section,url: url,website: true,panel: panel)
        if !route.website { routes.append(route) }
        show(next)
    }
    func signIn() {
        clearSelection(); clearBrowser()
        signInProviderURL = route.website ? provider.currentURL : nil
        provider.stop(); signingIn = true; dashboard.load(origin: sync.baseURL,accountGeneration: sync.accountGeneration)
    }
    private func finishSignIn() {
        signingIn = false
        if let url = signInProviderURL, route.website { signInProviderURL = nil; provider.openWebsite(section: route.section,url: url,panel: route.panel) }
        else { signInProviderURL = nil }
    }
    func switchServer(_ origin: URL) {
        do { clearSelection(); clearBrowser(); try sync.selectServer(origin); dashboard.load(origin: sync.baseURL,accountGeneration: sync.accountGeneration); signingIn = true } catch { message = error.localizedDescription }
    }
    func signOut() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        clearSelection(); clearBrowser(); signingIn = false; signInProviderURL = nil
        do { try sync.signOut(); await dashboard.signOut() }
        catch { message = error.localizedDescription }
    }
    func control(observed previous: TVState? = nil,action: @escaping (TVControlLease) async throws -> Void) {
        let observed = previous ?? tv.state
        guard observed.paired, observed.online else { tvPanel = true; pairingSheet = true; return }
        guard observed.control.supported else { message = "Update Anime Sync TV to use these controls."; return }
        if !observed.control.available && !observed.control.mine { takeover = TakeoverRequest(observed: observed,action: action); return }
        Task { do { let lease = try await tv.acquire(observed: observed,takeover: false); try await action(lease) } catch { message = error.localizedDescription } }
    }
    func confirmTakeover() {
        guard let request = takeover else { return }; takeover = nil
        Task { do { let lease = try await tv.acquire(observed: request.observed,takeover: true); try await request.action(lease) } catch { message = error.localizedDescription } }
    }
    func send(_ name: String,payload: JSONObject = [:]) { control { [weak self] lease in _ = try await self?.tv.command(name,payload: payload,lease: lease) } }
    func playOnTV() {
        let watch = provider.metadata?.watchURL ?? route.url
        guard let url = watch, AppWebPolicy.isProvider(url) else { message = "Choose an episode first."; return }
        let currentPlayer = player, observedRoute = route, epoch = resolvingEpoch, account = sync.accountGeneration
        control { [weak self] lease in
            guard let self, self.active, self.route == observedRoute, self.resolvingEpoch == epoch,
                  account == self.sync.accountGeneration, !self.handingOff else { throw ProviderFailure.staleNavigation }
            self.handingOff = true; defer { self.handingOff = false; currentPlayer?.cancelHandoff() }
            try await self.tv.validate(lease)
            guard self.active, self.resolvingEpoch == epoch, self.route == observedRoute, account == self.sync.accountGeneration else { throw ProviderFailure.staleNavigation }
            var snapshot: HandoffSnapshot?
            if let currentPlayer {
                guard self.player === currentPlayer else { throw ProviderFailure.staleNavigation }
                snapshot = try await currentPlayer.handoff()
            }
            else if self.route.website {
                guard self.browserReady, !self.browserStarting, self.browserMetadata == self.provider.metadata else { throw CoreError.message("Start playback before moving it to the TV.") }
                let browserEpoch = self.browserEpoch, owner = self.browserLease, metadata = self.browserMetadata
                let paused = try await self.provider.prepareHandoff()
                guard self.active, self.resolvingEpoch == epoch, self.browserEpoch == browserEpoch,
                      self.browserReady, self.browserLease === owner, metadata == paused.metadata,
                      account == self.sync.accountGeneration else { throw ProviderFailure.staleNavigation }
                await self.sync.progress(metadata: paused.metadata,lease: owner,position: paused.position,duration: paused.duration,ended: paused.ended)
                let saved = try await self.sync.flushForHandoff(metadata: paused.metadata,lease: owner)
                guard saved.saved else { throw CoreError.message("Progress has not been saved. Reconnect Anime Sync before switching screens.") }
                snapshot = HandoffSnapshot(saved: true,position: owner == nil ? saved.position : paused.position,generation: saved.generation)
            }
            if let snapshot, !snapshot.saved { throw CoreError.message("Progress has not been saved. Reconnect Anime Sync before switching screens.") }
            try await self.tv.validate(lease)
            guard self.active, self.resolvingEpoch == epoch, self.route == observedRoute, account == self.sync.accountGeneration,
                  self.player === currentPlayer else { throw ProviderFailure.staleNavigation }
            try await self.tv.load(url: url,position: snapshot?.position,generation: snapshot?.generation,lease: lease)
            guard self.active, self.resolvingEpoch == epoch, self.route == observedRoute, account == self.sync.accountGeneration,
                  self.player === currentPlayer else { return }
            if let currentPlayer, self.player === currentPlayer { await self.closePlayer() }
            guard self.active, self.resolvingEpoch == epoch, self.route == observedRoute, account == self.sync.accountGeneration else { return }
            self.clearBrowser(); self.tvPanel = true
        }
    }
    func moveFromTV() {
        let observed = tv.state, observedRoute = route, epoch = resolvingEpoch, account = sync.accountGeneration
        control(observed: observed) { [weak self] lease in
            guard let self, self.active, self.route == observedRoute, self.resolvingEpoch == epoch,
                  account == self.sync.accountGeneration, !self.handingOff else { throw ProviderFailure.staleNavigation }
            self.handingOff = true; defer { self.handingOff = false }
            try await self.tv.validate(lease)
            guard self.sameTVEpisode(observed, self.tv.state), self.route == observedRoute,
                  self.resolvingEpoch == epoch, self.active, account == self.sync.accountGeneration else { throw ProviderFailure.staleNavigation }
            let state = try await self.tv.command("handoff",lease: lease)
            guard self.active, self.route == observedRoute, self.resolvingEpoch == epoch,
                  account == self.sync.accountGeneration, self.tv.isCurrent(lease),
                  self.sameTVEpisode(observed, state), self.sameTVEpisode(state, self.tv.state) else { throw ProviderFailure.staleNavigation }
            guard state.handoffSaved, let url = state.watchURL, let generation = state.handoffGeneration,
                  generation >= 0, generation <= 9_007_199_254_740_991 else { throw CoreError.message("The TV has not saved its progress yet. Try again.") }
            self.open(url); self.pendingResume = ResumeSnapshot(position: state.position,generation: generation,sessionID: nil)
            self.pendingTVLease = lease; self.pendingTVEpisode = state; self.pendingPlay = true; self.tvPanel = false
            self.launchIfReady()
        }
    }
    private func sameTVEpisode(_ first: TVState,_ second: TVState) -> Bool {
        guard first.connection == second.connection, first.episode == second.episode,
              let lhs = first.watchURL, let rhs = second.watchURL else { return false }
        var left = URLComponents(url: lhs,resolvingAgainstBaseURL: false), right = URLComponents(url: rhs,resolvingAgainstBaseURL: false)
        left?.fragment = nil; right?.fragment = nil; return left?.string == right?.string
    }
    private func clearSelection() {
        resolvingEpoch &+= 1; pendingPlay = false; pendingResume = nil; pendingSourceGeneration = nil; pendingTVLease = nil; pendingTVEpisode = nil; selectedSourceID = ""
        launchTicket = nil; launchTask?.cancel(); launchTask = nil
    }
    private func clearBrowser(pause: Bool = true,cancelStart: Bool = true) {
        browserEpoch &+= 1
        if cancelStart { browserStartTask?.cancel(); browserStartTask = nil }
        browserStarting = false; browserReady = false; browserLocalOnly = false
        sync.release(browserLease); browserLease = nil; browserMetadata = nil
        if pause { provider.pause() }
    }
    private func receiveBrowser(_ event: BrowserPlaybackEvent) {
        switch event {
        case .started(let metadata,_):
            guard active, route.website, !signingIn, player == nil, provider.metadata == metadata else { provider.pause(); return }
            if handingOff { provider.pause(); return }
            if browserMetadata == metadata && (browserStarting || browserReady) { return }
            browserStartTask?.cancel(); browserStartTask = Task { [weak self] in await self?.browser(event) }
        case .routeChanged(let url):
            clearSelection(); clearBrowser()
            if route.website || route.section == "Episode" { route.url = url }
        case .resumeFailed:
            guard route.website else { return }; clearBrowser(); message = "The website player could not resume. Press Play to try again."
        default: Task { [weak self] in await self?.browser(event) }
        }
    }
    private func browser(_ event: BrowserPlaybackEvent) async {
        switch event {
        case .started(let metadata,let explicit):
            guard active, route.website, !signingIn, provider.metadata == metadata else { return }
            clearBrowser(pause: false,cancelStart: false); let epoch = browserEpoch, routeEpoch = resolvingEpoch, account = sync.accountGeneration
            browserMetadata = metadata; browserStarting = true
            // The pause event caused by this gate cannot write an unowned progress sample.
            provider.pause()
            do { let start = try await sync.begin(metadata: metadata,explicit: explicit)
                guard !Task.isCancelled, active, epoch == browserEpoch, routeEpoch == resolvingEpoch,
                      account == sync.accountGeneration, route.website, provider.metadata == metadata else { sync.release(start.lease); return }
                browserStarting = false
                guard start.allowed else { browserMetadata = nil; message = start.message; return }
                browserLease = start.lease; browserLocalOnly = start.lease == nil; browserReady = true
                provider.resumeBrowser(seconds: start.resumePosition ?? 0)
            } catch {
                if epoch == browserEpoch, routeEpoch == resolvingEpoch, !Task.isCancelled { clearBrowser(); message = error.localizedDescription }
            }
        case .progress(let metadata,let position,let duration,let ended,let playing):
            guard active, route.website, !browserStarting, browserReady, browserMetadata == metadata,
                  provider.metadata == metadata, browserLease != nil || browserLocalOnly, !handingOff else { return }
            let owner = browserLease
            if !playing || ended { clearBrowser(pause: false) }
            await sync.progress(metadata: metadata,lease: owner,position: position,duration: duration,ended: ended)
        case .stopped(let metadata,let position,let duration,let ended):
            guard active, route.website, !browserStarting, browserReady, browserMetadata == metadata,
                  provider.metadata == metadata, browserLease != nil || browserLocalOnly, !handingOff else { return }
            let owner = browserLease; clearBrowser(pause: false)
            await sync.progress(metadata: metadata,lease: owner,position: position,duration: duration,ended: ended)
        default: break
        }
    }
    func background() async {
        let captionContext = nativeSubtitleContext
        let preserveCaptions = captionContext.map { $0.player == player?.id && $0.navigation == resolvingEpoch && $0.account == sync.accountGeneration && $0.source == provider.selectionRevision } == true
        active = false; clearSelection(); clearBrowser(); tv.stopPolling(); discovery.stop(); dashboard.pause()
        // The background transition invalidates pending launches, while this
        // same player's caption scope survives. Actual navigation still fences it.
        if preserveCaptions, let context = captionContext { nativeSubtitleContext = (context.player,resolvingEpoch,context.account,context.source) }
        if let player { await player.background() }
    }
    func foreground() async { active = true; tv.startPolling(); await sync.flushPending(); await sync.refreshHistory(); if active, let player { forwardNativeSubtitles(provider.subtitles); await player.foreground() } }
}

@MainActor final class AppBootstrap: ObservableObject {
    @Published var model: AppModel?
    @Published var error: String?
    func start() async {
        guard model == nil else { return }
        do {
            #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if ProcessInfo.processInfo.arguments.contains("--qa-fixture") || environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
                let liveProvider = ProcessInfo.processInfo.arguments.contains("--qa-live-provider")
                if liveProvider { try await AppNetworkRouting.shared.start() }
                let app = AppModel(qa: QAFixture(),liveProvider: liveProvider); model = app; await app.start(); return
            }
            #endif
            try await AppNetworkRouting.shared.start()
            let configuration = URLSessionConfiguration.ephemeral; AppNetworkRouting.shared.configure(configuration)
            let app = AppModel(sync: SyncService(transport: CoreHTTPTransport(configuration: configuration)),tv: TVClient())
            model = app; await app.start()
        } catch { self.error = "Could not start the connection: " + error.localizedDescription }
    }
}
