import Foundation
import Combine
import WebKit

/// Authentication stays in the dashboard origin and its cookie store, never provider scripts.
@MainActor final class DashboardProvider: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var libraryCards: [SyncLibraryCard] = []
    @Published private(set) var authenticated = false
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var currentOrigin = AppWebPolicy.home
    var onAuthenticated: ((URL, [HTTPCookie]) -> Void)?
    var onWatchRequested: ((URL) -> Void)?
    var onFixtureLoad: ((URL) -> Void)?
    private let receiver = ScriptReceiver()
    private let fixture: Bool
    private var nonce = UUID().uuidString
    private var cookieReadPending = false
    private var deliveredAuthentication = false
    private var accountGeneration: UInt64 = 0
    private var ownLoad = false
    private var entry: WKBackForwardListItem?
    private var setEntry = false
    private var clearingAuthentication = false
    private var blanking = false
    private var blankWaiter: CheckedContinuation<Void,Never>?
    // Dashboard origins have a dedicated persistent profile. Local-storage removal
    // cannot erase Miruro/stream-provider sessions in the separate default profile.
    private static let profileID = UUID(uuidString: "ca667e7c-63ee-4be1-b88d-8f10688da47b")!

    lazy var webView: WKWebView = {
        let controller = WKUserContentController(); controller.add(receiver, name: "dashboardControl")
        let configuration = WKWebViewConfiguration(); configuration.userContentController = controller
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.profileID); configuration.mediaTypesRequiringUserActionForPlayback = .all
        AppNetworkRouting.shared.configure(configuration.websiteDataStore)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self; view.allowsBackForwardNavigationGestures = false
        view.isOpaque = false; view.backgroundColor = .black; view.scrollView.backgroundColor = .black
        return view
    }()
    init(fixture: Bool = false) {
        #if DEBUG
        self.fixture = fixture
        #else
        self.fixture = false
        #endif
        super.init(); receiver.dashboard = self
    }
    func load(origin: URL,accountGeneration: UInt64 = 0) {
        guard !clearingAuthentication else { return }
        guard AppWebPolicy.isDashboard(origin), let text = AppWebPolicy.origin(origin), let clean = URL(string: text) else {
            error = "Choose the home or Tailscale Anime Sync server."; return
        }
        let preserve = clean == currentOrigin && accountGeneration == self.accountGeneration && authenticated
        currentOrigin = clean; self.accountGeneration = accountGeneration
        nonce = UUID().uuidString; loading = true; error = nil
        if !preserve { libraryCards = []; authenticated = false }
        deliveredAuthentication = false
        cookieReadPending = false; entry = nil; setEntry = true
        if fixture { onFixtureLoad?(clean); return }
        refreshNetwork()
        installScripts(); ownLoad = true; webView.load(URLRequest(url: clean))
    }
    func refreshNetwork(reloadFailed: Bool = false) {
        AppNetworkRouting.shared.configure(webView.configuration.websiteDataStore)
        if reloadFailed, error != nil { reload() }
    }
    func reload() { load(origin: currentOrigin,accountGeneration: accountGeneration) }
    func safeWebBack() async -> Bool {
        guard !fixture else { return false }
        let captured = nonce
        let result = try? await webView.evaluateJavaScript("window.AnimeTvNav?.back()===true")
        guard nonce == captured else { return true }
        if result as? Bool == true { return true }
        if let entry, webView.backForwardList.currentItem !== entry, webView.backForwardList.backList.contains(where: { $0 === entry }), webView.canGoBack {
            webView.goBack(); return true
        }
        return false
    }
    func allowsBackSwipe(at point: CGPoint) async -> Bool {
        guard !fixture else { return true }
        guard !clearingAuthentication else { return false }
        let captured = nonce
        let result = try? await webView.evaluateJavaScript(ProviderScripts.backSwipeHitTest(at: point,size: webView.bounds.size))
        guard captured == nonce, !clearingAuthentication else { return false }
        return result as? Bool ?? true
    }
    func pause() { if !fixture { webView.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(v=>v.pause())", completionHandler: nil) } }
    private func installScripts() {
        let controller = webView.configuration.userContentController; controller.removeAllUserScripts()
        let bootstrap = ProviderScripts.bootstrap(nonce: nonce, handler: "dashboardControl", origins: AppWebPolicy.dashboards)
        controller.addUserScript(WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let script = ProviderScripts.read("tv-navigation.js") + "\n" + ProviderScripts.read("dashboard.js")
        controller.addUserScript(WKUserScript(source: bootstrap + "\n" + script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }
    func receive(_ message: WKScriptMessage) {
        guard !clearingAuthentication, message.name == "dashboardControl", message.webView === webView, message.frameInfo.isMainFrame,
              let origin = ProviderScripts.origin(message.frameInfo), AppWebPolicy.isDashboard(origin),
              AppWebPolicy.origin(origin) == AppWebPolicy.origin(currentOrigin),
              let packet = ProviderScripts.packet(message.body, nonce: nonce, maximum: 1_000_000) else { return }
        consume(packet)
    }
    private func consume(_ packet: JSONObject) {
        switch packet["type"]?.string {
        case "authenticated":
            if !authenticated { authenticated = true }
            if !fixture { deliverAuthentication() }
        case "library-status":
            if let pending = packet["loading"]?.bool, loading != pending { loading = pending }
        case "library":
            guard packet["complete"]?.bool == true, packet["loading"]?.bool != true,
                  let rows = packet["cards"]?.array else { return }
            let cards = rows.prefix(2000).compactMap { $0.object.flatMap(SyncLibraryCard.init(json:)) }
            guard rows.isEmpty || !cards.isEmpty else { loading = false; error = "The refreshed library could not be read. Try again."; return }
            if libraryCards != cards { libraryCards = cards }
            if !authenticated { authenticated = true }; if loading { loading = false }; error = nil
        case "watch":
            if let url = packet["url"]?.string.flatMap(URL.init(string:)), AppWebPolicy.isProvider(url) { onWatchRequested?(url) }
        default: break
        }
    }
    private func deliverAuthentication() {
        guard !clearingAuthentication, !cookieReadPending, !deliveredAuthentication else { return }
        cookieReadPending = true; let captured = nonce; let origin = currentOrigin
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] all in
            Task { @MainActor in
                guard let self, !self.clearingAuthentication, self.nonce == captured, self.currentOrigin == origin else { return }
                self.cookieReadPending = false
                let cookies = all.filter { cookie in
                    let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    guard let host = origin.host?.lowercased(), cookie.expiresDate.map({ $0 > Date() }) ?? true else { return false }
                    return host == domain || host.hasSuffix("." + domain)
                }
                guard !cookies.isEmpty else { return }
                // Cookie values are delivered only to the approved backend client and never logged.
                self.deliveredAuthentication = true; self.onAuthenticated?(origin, cookies)
            }
        }
    }
    /// Retry registration after a failed/offline device-session request, without re-entering credentials.
    func retryAuthentication() { deliveredAuthentication = false; if authenticated { deliverAuthentication() } }
    static func belongsToDashboard(_ domain: String) -> Bool {
        let clean = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !clean.isEmpty else { return false }
        return [AppWebPolicy.home.host, AppWebPolicy.tailnet.host].compactMap { $0?.lowercased() }.contains { $0 == clean || $0.hasSuffix("." + clean) }
    }
    /// Explicit logout fences old callbacks before clearing the backend-only profile.
    /// Cookie deletion is host-scoped; local/session storage records come from a
    /// profile whose top-level documents and frames only allow approved dashboards.
    func signOut() async {
        guard !clearingAuthentication else { return }
        clearingAuthentication = true; nonce = UUID().uuidString
        accountGeneration &+= 1
        authenticated = false; libraryCards = []; deliveredAuthentication = true; cookieReadPending = false; loading = true
        entry = nil; setEntry = false
        if fixture { clearingAuthentication = false; loading = false; return }
        let selected = currentOrigin
        webView.stopLoading(); webView.configuration.userContentController.removeAllUserScripts()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
            blanking = true; blankWaiter = continuation
            webView.loadHTMLString("<!doctype html><html></html>", baseURL: nil)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.finishBlank()
            }
        }
        let store = webView.configuration.websiteDataStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) } }
        for cookie in cookies where Self.belongsToDashboard(cookie.domain) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in store.httpCookieStore.delete(cookie) { continuation.resume() } }
        }
        let types: Set<String> = [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage]
        let records: [WKWebsiteDataRecord] = await withCheckedContinuation { continuation in store.fetchDataRecords(ofTypes: types) { continuation.resume(returning: $0) } }
        let scoped = records.filter { Self.belongsToDashboard($0.displayName) }
        if !scoped.isEmpty {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in store.removeData(ofTypes: types, for: scoped) { continuation.resume() } }
        }
        clearingAuthentication = false; load(origin: selected,accountGeneration: accountGeneration)
    }
    private func finishBlank() { blanking = false; let pending = blankWaiter; blankWaiter = nil; pending?.resume() }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if clearingAuthentication {
            decisionHandler(blanking && url.absoluteString == "about:blank" ? .allow : .cancel); return
        }
        if navigationAction.targetFrame?.isMainFrame == false { decisionHandler(AppWebPolicy.isDashboard(url) && AppWebPolicy.origin(url) == AppWebPolicy.origin(currentOrigin) ? .allow : .cancel); return }
        if AppWebPolicy.isProvider(url) { decisionHandler(.cancel); onWatchRequested?(url); return }
        guard AppWebPolicy.isDashboard(url), AppWebPolicy.origin(url) == AppWebPolicy.origin(currentOrigin), navigationAction.targetFrame != nil else {
            decisionHandler(.cancel); return
        }
        if ownLoad { ownLoad = false }
        else { nonce = UUID().uuidString; installScripts() }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !clearingAuthentication else { return }
        if setEntry { entry = webView.backForwardList.currentItem; setEntry = false }
        let bootstrap = ProviderScripts.bootstrap(nonce: nonce, handler: "dashboardControl", origins: AppWebPolicy.dashboards)
        webView.evaluateJavaScript(bootstrap, completionHandler: nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if clearingAuthentication { if webView.url?.absoluteString == "about:blank" { finishBlank() }; return }
        guard let url = webView.url, AppWebPolicy.isDashboard(url), AppWebPolicy.origin(url) == AppWebPolicy.origin(currentOrigin) else { return }
        loading = false
        let script = ProviderScripts.bootstrap(nonce: nonce, handler: "dashboardControl", origins: AppWebPolicy.dashboards) + "\n" + ProviderScripts.read("tv-navigation.js") + "\n" + ProviderScripts.read("dashboard.js")
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ failure: Error) { guard !clearingAuthentication, (failure as NSError).code != NSURLErrorCancelled else { return }; loading = false; error = "Anime Sync could not load. Check the network or choose the Tailscale server." }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loading = false; error = "Anime Sync stopped. Use Reload to reopen it." }
    func receiveFixture(_ packet: JSONObject) {
        #if DEBUG
        guard fixture else { return }; consume(packet)
        #endif
    }
}
