import Foundation
import Combine
import WebKit

/// Real Miruro documents supply catalogue data; only the selected main document controls app state.
@MainActor final class MiruroProvider: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var groups: [CatalogueGroup] = []
    @Published private(set) var hero: CatalogueHero?
    @Published private(set) var metadata: AnimeMetadata?
    @Published private(set) var synopsis = ""
    @Published private(set) var searchSuggestions: [SearchSuggestion] = []
    @Published private(set) var suggestionsLoading = false
    @Published private(set) var seasons: [SeasonChoice] = []
    @Published private(set) var episodes: [EpisodeChoice] = []
    @Published private(set) var episodeInventoryComplete = false
    @Published private(set) var sourceChoices: [WebsiteSourceChoice] = []
    @Published private(set) var sourceChoicesLoading = false
    @Published private(set) var selectionRevision: UInt64 = 0
    @Published private(set) var selectedChoiceID = ""
    @Published private(set) var sources: [MediaSource] = []
    @Published private(set) var unsupportedSources: [MediaSource] = []
    @Published private(set) var subtitles: [SubtitleSource] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var websiteMode = false
    @Published private(set) var currentURL = URL(string: "https://miruro.cx/")!
    @Published private(set) var section = "Home"
    @Published private(set) var emptyMessage = "Loading Miruro…"
    @Published private(set) var sourceStatus = NativeSourceStatus.loadingPlayer
    var onWatchRequested: ((URL) -> Void)?
    var onBrowserPlayback: ((BrowserPlaybackEvent) -> Void)?
    var onFixtureBrowse: ((String, URL) -> Void)?
    var onFixtureEpisode: ((String) -> Void)?
    var onFixtureSourceChoice: ((String) -> Bool)?

    private let receiver = ScriptReceiver()
    private let fixture: Bool
    private var documentNonce = UUID().uuidString
    private var navigationEpoch: UInt64 = 0
    private var ownedNavigation = false
    private var clearingDocument = false
    private var loadTask: Task<Void, Never>?
    private var suggestionDeadline: Task<Void, Never>?
    private var privacyRulesInstalled = false
    private var websiteEntry: WKBackForwardListItem?
    private var setWebsiteEntry = false
    private var pendingPanel: String?
    private var nativeReloadCount = 0
    private var sourceProbes: [String: Task<Void,Never>] = [:]
    private var probedSources: Set<String> = []
    private var selectionToken = ""
    private var lastSessionID = ""
    private var lastSessionRevision: Int64?
    private var sessionChanging = false
    private var handoff: (id: String, nonce: String, continuation: CheckedContinuation<BrowserHandoffSnapshot, Error>)?

    private var configuredNative = true
    lazy var webView: WKWebView = makeWebView(native: true)

    private func makeWebView(native: Bool) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(receiver, name: "providerControl")
        controller.add(receiver, name: "providerResource")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = native ? [] : .all
        configuration.websiteDataStore = .default()
        AppNetworkRouting.shared.configure(configuration.websiteDataStore)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        view.isOpaque = false; view.backgroundColor = .black
        view.scrollView.backgroundColor = .black
        view.allowsBackForwardNavigationGestures = false
        return view
    }

    init(fixture: Bool = false) {
        #if DEBUG
        self.fixture = fixture
        #else
        self.fixture = false
        #endif
        super.init(); receiver.owner = self
    }
    func browse(section: String, url: URL) {
        self.section = section
        nativeReloadCount = 0
        open(url: url, native: true)
    }
    func browse(section: String) {
        let path: String
        switch section {
        case "Home": path = "/"
        case "Trending": path = "/trending"
        case "Discover": path = "/discover"
        case "Search": path = "/search"
        case "Schedule": path = "/schedule"
        case "History": path = "/history"
        case "Announcements": path = "/announcements"
        case "Profile": path = "/profile"
        default: path = "/"
        }
        browse(section: section, url: URL(string: "https://miruro.cx" + path)!)
    }
    static func searchURL(_ query: String, request: UInt64? = nil) -> URL {
        var parts = URLComponents(string: "https://miruro.cx/search")!
        parts.queryItems = [URLQueryItem(name: "q",value: query)]
        // Match URLSearchParams decoding and WebKit's HTTPS URL serialization.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+",with: "%2B")
            .replacingOccurrences(of: "'",with: "%27")
        if let request { parts.fragment = "anime-sync-suggestions=\(request)" }
        return parts.url!
    }
    func open(url: URL, native: Bool = true, autoplay: Bool = false) {
        loadDocument(url: url, native: native, autoplay: autoplay, keepReloadBudget: false)
    }
    private func loadDocument(url inputURL: URL, native: Bool, autoplay: Bool = false, keepReloadBudget: Bool) {
        if !keepReloadBudget { nativeReloadCount = 0 }
        guard let url = ProviderPolicy.documentURL(inputURL,native: native) else { error = ProviderFailure.invalidURL.localizedDescription; return }
        cancelHandoff(ProviderFailure.staleNavigation)
        cancelSourceProbes()
        if configuredNative != native {
            let previous = webView
            previous.stopLoading(); previous.navigationDelegate = nil; previous.uiDelegate = nil
            previous.configuration.userContentController.removeScriptMessageHandler(forName: "providerControl")
            previous.configuration.userContentController.removeScriptMessageHandler(forName: "providerResource")
            previous.loadHTMLString("",baseURL: nil)
            webView = makeWebView(native: native); configuredNative = native; privacyRulesInstalled = false
        }
        navigationEpoch &+= 1; let epoch = navigationEpoch
        documentNonce = UUID().uuidString
        currentURL = url; websiteMode = !native; loading = true; error = nil
        groups = []; hero = nil; metadata = nil; synopsis = ""; seasons = []; episodes = []; sources = []; unsupportedSources = []; subtitles = []
        searchSuggestions = []; suggestionsLoading = section == "Search" && url.fragment?.hasPrefix("anime-sync-suggestions=") == true
        suggestionDeadline?.cancel()
        if suggestionsLoading, !fixture {
            suggestionDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled, let self, self.navigationEpoch == epoch, self.suggestionsLoading else { return }
                self.suggestionsLoading = false
                if self.error == nil { self.error = "Suggestions couldn’t load. Try View All." }
            }
        }
        episodeInventoryComplete = false; sourceChoices = []; sourceChoicesLoading = false
        selectedChoiceID = ""; selectionToken = ""; selectionRevision &+= 1
        lastSessionID = ""; lastSessionRevision = nil; sessionChanging = false
        emptyMessage = "Loading Miruro…"
        sourceStatus = .loadingPlayer
        websiteEntry = nil; setWebsiteEntry = !native
        loadTask?.cancel()
        clearingDocument = false
        if fixture {
            loading = false; onFixtureBrowse?(section, url); return
        }
        installScripts()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !self.privacyRulesInstalled {
                    let rules = try await ProviderRuleLists.privateRequests()
                    guard self.navigationEpoch == epoch, !Task.isCancelled else { return }
                    self.webView.configuration.userContentController.add(rules); self.privacyRulesInstalled = true
                }
                guard self.navigationEpoch == epoch, !Task.isCancelled else { return }
                self.refreshNetwork()
                // A new query generation can have the same URL apart from its
                // fragment. Rebind this exact search document to the new nonce.
                if self.section == "Search", let displayed = self.webView.url, displayed != url,
                   self.withoutFragment(displayed) == self.withoutFragment(url) {
                    let target = ProviderPolicy.jsonLiteral(url.absoluteString)
                    let previous = ProviderPolicy.jsonLiteral(displayed.absoluteString)
                    let view = self.webView
                    let rebound = (try? await view.evaluateJavaScript("""
                    (()=>{if (location.href !== \(previous)) return false;
                    history.replaceState(history.state,'',\(target));
                    \(self.documentSetup())
                    return true;})()
                    """)) as? Bool
                    guard self.navigationEpoch == epoch, !Task.isCancelled else { return }
                    if rebound != true {
                        self.ownedNavigation = true
                        view.load(URLRequest(url: url))
                    }
                } else {
                    self.ownedNavigation = true
                    self.webView.load(URLRequest(url: url))
                }
            } catch {
                guard self.navigationEpoch == epoch else { return }
                self.loading = false; self.error = "The page's privacy boundary could not initialize. Try again."
            }
        }
    }
    func refreshNetwork(reloadFailed: Bool = false) {
        AppNetworkRouting.shared.configure(webView.configuration.websiteDataStore)
        if reloadFailed, error != nil { reload() }
    }
    func reload() { open(url: currentURL, native: !websiteMode) }
    func selectEpisode(id: String) {
        guard !id.isEmpty, id.count < 80 else { return }
        if fixture { onFixtureEpisode?(id); return }
        if let episode = episodes.first(where: { $0.id == id }), let url = episode.url,
           AppWebPolicy.isProvider(url), AppWebPolicy.origin(url) == AppWebPolicy.origin(currentURL), url.path == currentURL.path {
            open(url: url,native: true); return
        }
        evaluate("window.AnimeTvPage?.selectEpisode(\(ProviderPolicy.jsonLiteral(id)))")
    }
    func refreshSourceChoices() {
        guard !websiteMode, metadata != nil else { return }
        sourceChoicesLoading = true
        if fixture { sourceChoicesLoading = false; return }
        evaluate("window.AnimeTvPage?.sourceChoices()")
    }
    func selectSourceChoice(id: String) {
        guard !websiteMode, let choice = sourceChoices.first(where: { $0.id == id }), !choice.selected else { return }
        cancelSourceProbes(); sources = []; unsupportedSources = []; subtitles = []
        selectionRevision &+= 1; selectedChoiceID = id; selectionToken = UUID().uuidString
        sessionChanging = true; sourceChoicesLoading = true; sourceStatus = .loadingPlayer; error = nil
        if fixture {
            if onFixtureSourceChoice?(id) == false { recoverSourceSelectionFailure() }
            else { sourceChoicesLoading = false }
            return
        }
        let token = selectionToken, nonce = documentNonce
        Task { [weak self] in
            guard let self else { return }
            let result = try? await self.webView.callAsyncJavaScript("return await window.AnimeTvPage?.selectSource(id,ticket)",arguments: ["id": id,"ticket": token],in: nil,contentWorld: .page)
            guard self.documentNonce == nonce, self.selectionToken == token else { return }
            if result as? Bool != true { self.recoverSourceSelectionFailure() }
        }
    }
    private func recoverSourceSelectionFailure() {
        // A failed menu lookup may never reset the browser's observer token;
        // a script error can also occur after the click. A fresh document is
        // safe in both cases and gives every frame a new nonce/empty selection.
        reload()
        error = "This Miruro source changed. The episode was reloaded; choose the source and try again."
    }
    func showWebsite(panel: String? = nil) {
        pendingPanel = panel
        open(url: currentURL, native: false)
    }
    func openWebsite(section: String, url: URL, panel: String? = nil) {
        self.section = section; pendingPanel = panel
        open(url: url, native: false)
    }
    func pause() { if !fixture { evaluate("window.AnimeTvPage?.pause()") } }
    func resumeBrowser(seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0, !fixture else { return }
        evaluate("window.AnimeTvPage?.resumeBrowser(\(seconds),true)")
    }
    func browserCommand(_ command: String, amount: Double = 0) {
        guard ["play", "pause", "toggle", "seek", "seek_to"].contains(command), amount.isFinite, !fixture else { return }
        evaluate("window.AnimeTvPage?.command(\(ProviderPolicy.jsonLiteral(command)),\(amount))")
    }
    func back() async -> Bool {
        guard websiteMode, !fixture else { return false }
        let nonce = documentNonce
        let result = try? await webView.evaluateJavaScript("window.AnimeTvPage?.back()===true")
        guard nonce == documentNonce else { return true }
        if result as? Bool == true { return true }
        if let entry = websiteEntry, webView.backForwardList.currentItem !== entry,
           webView.backForwardList.backList.contains(where: { $0 === entry }), webView.canGoBack {
            webView.goBack(); return true
        }
        return false
    }
    /// The app owns Back gestures; central swipes must first respect website controls.
    func allowsBackSwipe(at point: CGPoint) async -> Bool {
        guard !fixture, websiteMode else { return true }
        let captured = documentNonce
        let result = try? await webView.evaluateJavaScript(ProviderScripts.backSwipeHitTest(at: point,size: webView.bounds.size))
        guard captured == documentNonce else { return false }
        return result as? Bool ?? true
    }
    func prepareHandoff() async throws -> BrowserHandoffSnapshot {
        guard websiteMode, !fixture, handoff == nil else { throw ProviderFailure.missingPlayer }
        let id = UUID().uuidString; let nonce = documentNonce
        return try await withCheckedThrowingContinuation { continuation in
            handoff = (id, nonce, continuation)
            evaluate("window.AnimeTvPage?.handoff(\(ProviderPolicy.jsonLiteral(id)))")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.handoff?.id == id else { return }
                self.cancelHandoff(ProviderFailure.timeout)
            }
        }
    }
    func suspend() { pause(); cancelHandoff(ProviderFailure.staleNavigation) }
    func stop() {
        loadTask?.cancel(); cancelHandoff(ProviderFailure.staleNavigation)
        suggestionDeadline?.cancel()
        cancelSourceProbes()
        seasons = []; synopsis = ""; searchSuggestions = []; suggestionsLoading = false
        navigationEpoch &+= 1; documentNonce = UUID().uuidString; loading = false
        if !fixture { clearingDocument = true; webView.stopLoading(); webView.loadHTMLString("", baseURL: nil) }
    }
    private func cancelHandoff(_ error: Error) {
        guard let pending = handoff else { return }; handoff = nil
        pending.continuation.resume(throwing: error)
    }
    private func installScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        let native = !websiteMode
        let bootstrap = ProviderScripts.bootstrap(nonce: documentNonce, handler: "providerControl", origins: AppWebPolicy.providers)
        controller.addUserScript(WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let observer = ProviderScripts.read("resource-observer.js")
            .replacingOccurrences(of: "__ANIME_SYNC_NONCE__", with: ProviderPolicy.jsonLiteral(documentNonce))
            .replacingOccurrences(of: "__ANIME_SYNC_NATIVE__", with: native ? "true" : "false")
        controller.addUserScript(WKUserScript(source: observer, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let app = ProviderScripts.read("tv-navigation.js") + "\n" + ProviderScripts.read("provider.js")
        let setup = "\nwindow.AnimeTvPage?.nativeMode(\(native));window.AnimeTvPage?.browseMode(\(!native));"
        controller.addUserScript(WKUserScript(source: bootstrap + "\n" + app + setup, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }
    private func evaluate(_ script: String) { webView.evaluateJavaScript(script, completionHandler: nil) }
    private func samePage(_ value: String?) -> Bool { value == currentURL.absoluteString }

    func receive(_ message: WKScriptMessage) {
        guard message.webView === webView, let origin = ProviderScripts.origin(message.frameInfo),
              let packet = ProviderScripts.packet(message.body, nonce: documentNonce, maximum: message.name == "providerResource" ? 20_000 : 1_000_000) else { return }
        if message.name == "providerResource" {
            guard AppWebPolicy.isMediaOrigin(origin), AppWebPolicy.isProvider(currentURL),
                  let raw = packet["page"]?.string, let framePage = URL(string: raw), AppWebPolicy.origin(framePage) == AppWebPolicy.origin(origin),
                  !message.frameInfo.isMainFrame || packet["requestPage"]?.string == currentURL.absoluteString else { return }
            // A source switch can leave an older iframe alive. Only new top-frame
            // requests/configuration carrying the captured selection token belong to it.
            guard selectionToken.isEmpty || message.frameInfo.isMainFrame && packet["selection"]?.string == selectionToken else { return }
            if packet["type"]?.string == "source-session" {
                guard message.frameInfo.isMainFrame, AppWebPolicy.isProvider(origin) else { return }
                consumeSourceSession(packet); return
            }
            if packet["type"]?.string == "media-status" {
                if !websiteMode, sources.isEmpty, packet["phase"]?.string == "gesture-required" { sourceStatus = .gestureRequired }
            } else { candidate(packet,frameURL: framePage,confirmed: false,resourceOnly: true,trustedConfiguration: message.frameInfo.isMainFrame && AppWebPolicy.isProvider(origin) && AppWebPolicy.origin(origin) == AppWebPolicy.origin(currentURL)) }
            return
        }
        guard message.name == "providerControl", message.frameInfo.isMainFrame,
              AppWebPolicy.isProvider(origin), AppWebPolicy.origin(origin) == AppWebPolicy.origin(currentURL) else { return }
        consume(packet)
    }
    private func consume(_ packet: JSONObject) {
        let type = packet["type"]?.string ?? ""
        guard type == "route" || samePage(packet["page"]?.string) else { return }
        switch type {
        case "route":
            guard let raw = packet["url"]?.string, let url = URL(string: raw), AppWebPolicy.isProvider(url),
                  AppWebPolicy.origin(url) == AppWebPolicy.origin(currentURL) else { return }
            if section == "Search", !websiteMode, currentURL.path == "/search", url != currentURL { return }
            if withoutFragment(url) != withoutFragment(currentURL) {
                // A new route receives a fresh document/iframe epoch in both modes.
                // Old iframe/video callbacks cannot be relabelled as the next episode.
                guard nativeReloadCount < 8 else { loading = false; error = "This page keeps redirecting. Use Reload to try again."; return }
                nativeReloadCount += 1
                onBrowserPlayback?(.routeChanged(url))
                loadDocument(url: url, native: !websiteMode, keepReloadBudget: true); return
            }
            // Hash-only resume hints do not change episode ownership, but subsequent
            // bridge packets must still match the document's complete current URL.
            currentURL = url
        case "catalogue":
            let result = packet["groups"]?.array ?? []
            groups = result.prefix(32).compactMap { value in
                guard let group = value.object, let title = group["title"]?.string else { return nil }
                let items = (group["items"]?.array ?? []).prefix(48).compactMap { $0.object.flatMap(CatalogueCard.init(json:)) }
                return CatalogueGroup(title: String(title.prefix(200)), items: items)
            }
            loading = packet["loading"]?.bool ?? false
            emptyMessage = String((packet["message"]?.string ?? "No titles available. Try Reload.").prefix(500))
        case "search-suggestions":
            guard section == "Search", !websiteMode, currentURL.fragment?.hasPrefix("anime-sync-suggestions=") == true,
                  let parts = URLComponents(url: currentURL,resolvingAgainstBaseURL: false),
                  parts.path == "/search", parts.queryItems?.first(where: { $0.name == "q" })?.value == packet["query"]?.string else { return }
            var seen = Set<String>()
            searchSuggestions = (packet["items"]?.array ?? []).prefix(6).compactMap { value in
                guard let item = value.object, let choice = SearchSuggestion(json: item,page: currentURL),
                      seen.insert(choice.id).inserted else { return nil }
                return choice
            }
            suggestionsLoading = packet["loading"]?.bool == true
            if !suggestionsLoading {
                suggestionDeadline?.cancel()
                if error == "Suggestions couldn’t load. Try View All." { error = nil }
            }
        case "hero": if let item = packet["hero"]?.object { hero = CatalogueHero(json: item) }
        case "metadata":
            guard let item = packet["metadata"]?.object, let next = AnimeMetadata(json: item),
                  withoutFragment(next.watchURL) == withoutFragment(currentURL) else { return }
            let description = String((item["description"]?.string ?? "").prefix(6000)).trimmingCharacters(in: .whitespacesAndNewlines)
            if synopsis != description { synopsis = description }
            if metadata != next { metadata = next }; if loading { loading = false }
            if sources.isEmpty, sourceStatus == .loadingPlayer { sourceStatus = .waitingForStream }
        case "seasons":
            guard !websiteMode, section == "Episode", let items = packet["seasons"]?.array else { return }
            var seen = Set<String>()
            let choices = items.prefix(32).compactMap { value -> SeasonChoice? in
                guard let item = value.object, let choice = SeasonChoice(json: item,page: currentURL),
                      seen.insert(choice.id).inserted else { return nil }
                return choice
            }
            let available = choices.contains(where: { !$0.selected }) ? choices : []
            if seasons != available { seasons = available }
        case "episodes":
            var seenEpisodes: Set<Double> = [], seenIDs: Set<String> = []
            let next: [EpisodeChoice] = (packet["episodes"]?.array ?? []).prefix(3000).compactMap { value in
                guard let item = value.object, let id = item["id"]?.string, !id.isEmpty, id.count <= 80,
                      let label = item["label"]?.string, let number = Double(item["number"]?.string ?? id), number.isFinite, number >= 0,
                      seenEpisodes.insert(number).inserted, seenIDs.insert(id).inserted else { return nil }
                let url = item["url"]?.string.flatMap(URL.init(string:)).flatMap { value -> URL? in
                    guard AppWebPolicy.isProvider(value), AppWebPolicy.origin(value) == AppWebPolicy.origin(currentURL), value.path == currentURL.path,
                          let values = URLComponents(url: value,resolvingAgainstBaseURL: false)?.queryItems?.filter({ $0.name == "ep" }),
                          values.count == 1, values[0].value.flatMap(Double.init) == number else { return nil }
                    return value
                }
                return EpisodeChoice(id: id,label: String(label.prefix(120)),number: String((item["number"]?.string ?? id).prefix(40)),title: String((item["title"]?.string ?? "").prefix(300)),selected: item["selected"]?.bool == true,url: url)
            }.sorted { (Double($0.number) ?? 0) < (Double($1.number) ?? 0) }
            if next != episodes { episodes = next }
            episodeInventoryComplete = packet["complete"]?.bool == true
        case "source-choices":
            var result: [WebsiteSourceChoice] = []
            for value in (packet["groups"]?.array ?? []).prefix(2) {
                guard let group = value.object, let name = group["name"]?.string, ["Audio","Provider"].contains(name) else { continue }
                for value in (group["items"]?.array ?? []).prefix(32) {
                    guard let item = value.object, let id = item["id"]?.string, !id.isEmpty, id.count <= 500,
                          let label = item["label"]?.string, !label.isEmpty, !result.contains(where: { $0.id == id }) else { continue }
                    result.append(WebsiteSourceChoice(id: id,kind: name.lowercased(),label: String(label.prefix(200)),selected: item["selected"]?.bool == true))
                }
            }
            sourceChoices = result; sourceChoicesLoading = false
        case "source-choices-status": sourceChoicesLoading = packet["loading"]?.bool == true
        case "source-selected":
            guard packet["selection"]?.string == selectionToken else { return }
            sourceChoicesLoading = false
        case "source-session": consumeSourceSession(packet)
        case "source", "subtitle": candidate(packet,frameURL: currentURL,confirmed: packet["confirmed"]?.bool == true,resourceOnly: false,trustedConfiguration: true)
        case "resolved-watch":
            guard let page = packet["page"]?.string.flatMap(URL.init(string:)), page == currentURL,
                  let target = packet["url"]?.string.flatMap(URL.init(string:)),
                  AppWebPolicy.resolvedWatch(page: page, target: target, animeID: packet["anime_id"]?.string ?? "", episode: packet["episode"]?.string ?? "") else { return }
            open(url: target, native: !websiteMode)
        case "browse-watch":
            if websiteMode, let url = packet["url"]?.string.flatMap(URL.init(string:)), AppWebPolicy.isProvider(url) { onWatchRequested?(url) }
        case "playback-start":
            if websiteMode, let item = packet["metadata"]?.object.flatMap(validBrowserMetadata) { onBrowserPlayback?(.started(item, explicit: packet["explicit"]?.bool == true)) }
        case "progress", "playback-stop":
            guard websiteMode, let item = packet["metadata"]?.object.flatMap(validBrowserMetadata),
                  let position = packet["position"]?.double, let duration = packet["duration"]?.double,
                  position.isFinite, duration.isFinite, position >= 0, duration > 0, position <= duration + 60 else { return }
            let ended = packet["ended"]?.bool == true
            if type == "progress" { onBrowserPlayback?(.progress(item, position: position, duration: duration, ended: ended, playing: packet["playing"]?.bool == true)) }
            else { onBrowserPlayback?(.stopped(item, position: position, duration: duration, ended: ended)) }
        case "playback-resume-failed": onBrowserPlayback?(.resumeFailed)
        case "handoff-ready":
            guard let pending = handoff, packet["id"]?.string == pending.id, pending.nonce == documentNonce else { return }
            guard packet["paused"]?.bool == true, let item = packet["metadata"]?.object.flatMap(validBrowserMetadata),
                  let position = packet["position"]?.double, let duration = packet["duration"]?.double,
                  position.isFinite, duration.isFinite, position >= 0, duration > 0, position <= duration + 60 else { cancelHandoff(ProviderFailure.missingPlayer); return }
            handoff = nil
            pending.continuation.resume(returning: BrowserHandoffSnapshot(metadata: item, position: position, duration: duration, ended: packet["ended"]?.bool == true, paused: true))
        default: break
        }
    }
    private func validBrowserMetadata(_ value: JSONObject) -> AnimeMetadata? {
        guard let item = AnimeMetadata(json: value), let current = metadata,
              item.animeID == current.animeID, item.episode == current.episode,
              withoutFragment(item.watchURL) == withoutFragment(currentURL) else { return nil }
        return item
    }
    private func candidate(_ packet: JSONObject,frameURL: URL,confirmed: Bool,resourceOnly: Bool,trustedConfiguration: Bool = false) {
        guard selectionToken.isEmpty || packet["selection"]?.string == selectionToken else { return }
        guard let kind = packet["type"]?.string, ["source", "subtitle"].contains(kind),
              let url = packet["url"]?.string.flatMap(URL.init(string:)), AppWebPolicy.isMediaOrigin(url), url.absoluteString.count <= 10_000 else { return }
        let headers = ProviderPolicy.ordinaryHeaders(packet["headers"]?.object, frameURL: frameURL)
        let configured = trustedConfiguration && packet["configured"]?.bool == true
        if kind == "subtitle" || AppWebPolicy.isSubtitle(url) {
            guard subtitles.count < 32 || subtitles.contains(where: { $0.url == url }) else { return }
            let existing = subtitles.first(where: { $0.url == url })
            let label = packet["label"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? existing?.label ?? "Subtitles \(subtitles.count + 1)"
            let language = packet["language"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? existing?.language ?? "und"
            let retainedHeaders = existing?.configured == true && !configured ? existing!.headers : headers
            let next = SubtitleSource(url: url,label: String(label.prefix(120)),language: String(language.prefix(20)),headers: retainedHeaders,choiceID: selectedChoiceID,selectionRevision: selectionRevision,configured: configured || existing?.configured == true)
            if let i = subtitles.firstIndex(where: { $0.url == url }) { subtitles[i] = next } else { subtitles.append(next) }
            return
        }
        let mime = String((packet["mime"]?.string ?? "").prefix(120))
        let segmentEntries = configured ? packet["segments"]?.array ?? [] : []
        if !websiteMode, !ProviderPolicy.nativeMedia(url,mimeType: mime), !AppWebPolicy.isMedia(url),
           confirmed || packet["mediaElement"]?.bool == true {
            probeSource(url,headers: headers,frameURL: frameURL,confirmed: !resourceOnly && confirmed,configured: configured,segments: segmentEntries)
            return
        }
        guard confirmed || AppWebPolicy.isMedia(url) || ProviderPolicy.nativeMedia(url, mimeType: mime) else { return }
        let next = MediaSource(url: url,headers: headers,confirmed: !resourceOnly && confirmed,mimeType: mime,choiceID: selectedChoiceID,selectionRevision: selectionRevision,configured: configured,segments: PlaybackSegment.parse(segmentEntries))
        if next.nativePlayable {
            guard sources.count < 24 || sources.contains(where: { $0.url == url }) else { return }
            if let i = sources.firstIndex(where: { $0.url == url }) {
                // Current main-frame configuration can repair a generic offer.
                // Generic reports cannot downgrade it, and a media-only frame
                // cannot replace a confirmed source or grant playback authority.
                if next.confirmed || !sources[i].confirmed && (next.configured || !sources[i].configured && sources[i].headers == next.headers) {
                    var merged = next; merged.confirmed = next.confirmed || sources[i].confirmed
                    merged.configured = next.configured || sources[i].configured
                    if !next.configured { merged.segments = sources[i].segments }; sources[i] = merged
                }
            }
            else { sources.append(next) }
            sources.sort { $0.confirmed && !$1.confirmed }
            sourceStatus = .ready
        } else if !unsupportedSources.contains(where: { $0.url == url }), unsupportedSources.count < 24 { unsupportedSources.append(next) }
    }
    private func consumeSourceSession(_ packet: JSONObject) {
        guard selectionToken.isEmpty || packet["selection"]?.string == selectionToken,
              let revision = packet["revision"]?.integer, revision >= 0,
              let id = packet["sessionID"]?.string, id.count <= 200 else { return }
        if id == lastSessionID, let previous = lastSessionRevision, revision <= previous { return }
        // A new document/explicit choice already discarded the old offers. The
        // SDK may resolve HTTPS HLS into a blob before its ready callback, so
        // completing that open cycle must keep its captured offers and probes.
        if lastSessionRevision != nil, !sessionChanging {
            selectionRevision &+= 1
            cancelSourceProbes(); sources = []; unsupportedSources = []; subtitles = []
        }
        lastSessionID = id; lastSessionRevision = revision
        sessionChanging = packet["status"]?.string != "ready"
        sourceStatus = !sources.isEmpty ? .ready : sourceProbes.isEmpty ? .waitingForStream : .checkingFormat
    }
    private func probeSource(_ url: URL,headers: [String:String],frameURL: URL,confirmed: Bool,configured: Bool = false,segments: [JSONValue] = []) {
        let key = url.absoluteString
        guard !fixture, MediaBridgePolicy.allows(url), probedSources.count < 12, sourceProbes.count < 3,
              !probedSources.contains(key) else { return }
        probedSources.insert(key); let nonce = documentNonce, selection = selectionToken
        sourceStatus = .checkingFormat
        sourceProbes[key] = Task { [weak self] in
            let mime = await MediaSourceProbe.mimeType(url: url,headers: headers)
            guard let self, self.documentNonce == nonce, self.selectionToken == selection, !Task.isCancelled else { return }
            self.sourceProbes.removeValue(forKey: key)
            if let mime {
                self.candidate(["type": .string("source"), "url": .string(key), "mime": .string(mime),
                                "selection": .string(selection),
                                "configured": .bool(configured), "segments": .array(segments),
                                "headers": .object(headers.mapValues(JSONValue.string))],frameURL: frameURL,confirmed: confirmed,resourceOnly: !confirmed,trustedConfiguration: configured)
            } else if self.sourceProbes.isEmpty, self.sources.isEmpty, self.sourceStatus == .checkingFormat { self.sourceStatus = .waitingForStream }
        }
    }
    private func cancelSourceProbes() {
        let pending = Array(sourceProbes.values); sourceProbes.removeAll(); probedSources.removeAll()
        pending.forEach { $0.cancel() }
    }
    private func withoutFragment(_ url: URL) -> String { var value = URLComponents(url: url, resolvingAgainstBaseURL: false)!; value.fragment = nil; return value.string ?? url.absoluteString }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard webView === self.webView else { decisionHandler(.cancel); return }
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if clearingDocument, url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(AppWebPolicy.isDashboard(url) ? .cancel : .allow); return
        }
        guard AppWebPolicy.isProvider(url) else { decisionHandler(.cancel); if url.scheme != "about" { error = "This link opens outside Miruro." }; return }
        if navigationAction.targetFrame == nil { decisionHandler(.cancel); return }
        if ownedNavigation { ownedNavigation = false; decisionHandler(.allow); return }
        if !websiteMode, navigationAction.navigationType == .linkActivated { decisionHandler(.cancel); onWatchRequested?(url); return }
        cancelHandoff(ProviderFailure.staleNavigation)
        cancelSourceProbes()
        documentNonce = UUID().uuidString; currentURL = url; metadata = nil; synopsis = ""; sources = []; subtitles = []; unsupportedSources = []
        seasons = []; episodes = []; episodeInventoryComplete = false; sourceChoices = []; sourceChoicesLoading = false
        selectedChoiceID = ""; selectionToken = ""; selectionRevision &+= 1
        lastSessionID = ""; lastSessionRevision = nil; sessionChanging = false
        installScripts(); decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        if setWebsiteEntry { websiteEntry = webView.backForwardList.currentItem; setWebsiteEntry = false }
        let bootstrap = ProviderScripts.bootstrap(nonce: documentNonce, handler: "providerControl", origins: AppWebPolicy.providers)
        evaluate(bootstrap)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, let url = webView.url, AppWebPolicy.isProvider(url) else { return }
        evaluate(documentSetup())
        if let panel = pendingPanel { pendingPanel = nil; evaluate("window.AnimeTvPage?.openPanel(\(ProviderPolicy.jsonLiteral(panel)))") }
    }
    private func documentSetup() -> String {
        let script = ProviderScripts.bootstrap(nonce: documentNonce, handler: "providerControl", origins: AppWebPolicy.providers) + "\n" + ProviderScripts.read("tv-navigation.js") + "\n" + ProviderScripts.read("provider.js")
        return script + "\nwindow.AnimeTvPage?.nativeMode(\(!websiteMode));window.AnimeTvPage?.browseMode(\(websiteMode));"
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { guard webView === self.webView else { return }; navigationFailed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { guard webView === self.webView else { return }; navigationFailed(error) }
    private func navigationFailed(_ failure: Error) {
        guard (failure as NSError).code != NSURLErrorCancelled else { return }; loading = false; error = ProviderFailure.unavailable.localizedDescription
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { guard webView === self.webView else { return }; loading = false; error = "The browser stopped. Use Reload to reopen this page."; cancelHandoff(ProviderFailure.unavailable) }

    /// Debug previews exercise native SwiftUI with packets instead of making real network requests.
    func receiveFixture(_ packet: JSONObject) {
        #if DEBUG
        guard fixture else { return }
        var value = packet
        if value["page"] == nil { value["page"] = .string(currentURL.absoluteString) }
        if value["selection"] == nil { value["selection"] = .string(selectionToken) }
        consume(value)
        #endif
    }
}
