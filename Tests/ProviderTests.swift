import Foundation
import XCTest
import WebKit
@testable import AnimeSync

@MainActor private final class ProbeCandidateCapture: NSObject, WKScriptMessageHandler {
    let received: XCTestExpectation
    var packet: JSONObject?
    init(received: XCTestExpectation) { self.received = received }
    func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
        guard packet == nil, let packet = ProviderScripts.packet(message.body,nonce: "probe-test",maximum: 5000),
              packet["type"]?.string == "source" else { return }
        self.packet = packet; received.fulfill()
    }
}

@MainActor private final class DashboardPacketCapture: NSObject, WKScriptMessageHandler {
    var packets: [JSONObject] = []
    var onPacket: ((JSONObject)->Void)?
    func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
        guard let packet = ProviderScripts.packet(message.body,nonce: "dashboard-test",maximum: 20_000) else { return }
        packets.append(packet); onPacket?(packet)
    }
}

@MainActor private final class SubtitleCandidateCapture: NSObject, WKScriptMessageHandler {
    let received: XCTestExpectation
    var packets: [JSONObject] = []
    var sources: [JSONObject] = []
    init(received: XCTestExpectation) { self.received = received }
    func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
        guard let packet = ProviderScripts.packet(message.body,nonce: "subtitle-test",maximum: 5000) else { return }
        if packet["type"]?.string == "source" { sources.append(packet); return }
        guard packet["type"]?.string == "subtitle", !packets.contains(where: { $0["url"] == packet["url"] }) else { return }
        packets.append(packet); received.fulfill()
    }
}

@MainActor final class ProviderTests: XCTestCase {
    func testNativeDocumentNormalizationChangesOnlyVerifiedWWWHost() throws {
        let legacy = try XCTUnwrap(URL(string: "https://www.miruro.cx/watch/1qLBIMfJS3I-ND9HDTRiUHDhvBLN0kco/record-of-ragnarok-ii?ep=6&option=a%2Bb#anime-sync-t=42.5"))
        let modern = try XCTUnwrap(ProviderPolicy.documentURL(legacy,native: true))
        XCTAssertEqual(modern.host,"miruro.cx")
        let original = try XCTUnwrap(URLComponents(url: legacy,resolvingAgainstBaseURL: false))
        let normalized = try XCTUnwrap(URLComponents(url: modern,resolvingAgainstBaseURL: false))
        XCTAssertEqual(normalized.percentEncodedPath,original.percentEncodedPath)
        XCTAssertEqual(normalized.percentEncodedQuery,original.percentEncodedQuery)
        XCTAssertEqual(normalized.percentEncodedFragment,original.percentEncodedFragment)
        XCTAssertEqual(ProviderPolicy.documentURL(legacy,native: false),legacy)
        for raw in ["https://miruro.cx/watch/id/title?ep=6", "https://miruro.to/watch/old/title?ep=6", "https://www.miruro.to/watch/old/title?ep=6"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertEqual(ProviderPolicy.documentURL(url,native: true),url)
        }
        for raw in ["http://www.miruro.cx/watch/id/title?ep=6", "https://www.miruro.cx.evil.example/watch/id/title?ep=6", "https://user:password@www.miruro.cx/watch/id/title?ep=6", "https://www.miruro.cx:8443/watch/id/title?ep=6"] {
            XCTAssertNil(ProviderPolicy.documentURL(try XCTUnwrap(URL(string: raw)),native: true))
        }
    }

    func testLegacyHistoryClassificationUsesExactOriginsWithoutAuthorizingOldTVHosts() throws {
        for host in ["www.miruro.cx", "miruro.to", "www.miruro.to", "miruro.tv", "www.miruro.tv"] {
            let url = try XCTUnwrap(URL(string: "https://" + host + "/watch/legacy/title?ep=6"))
            XCTAssertTrue(ProviderPolicy.isLegacyNativeHistoryURL(url))
            if host.hasSuffix(".tv") { XCTAssertNil(ProviderPolicy.documentURL(url,native: true)) }
        }
        for raw in ["https://miruro.cx/watch/id/title?ep=6", "http://www.miruro.to/watch/id/title?ep=6", "https://www.miruro.to.evil.example/watch/id/title?ep=6", "https://user:password@www.miruro.to/watch/id/title?ep=6", "https://www.miruro.to:8443/watch/id/title?ep=6", "https://hianime.to/watch/id"] {
            XCTAssertFalse(ProviderPolicy.isLegacyNativeHistoryURL(try XCTUnwrap(URL(string: raw))))
        }
    }

    func testNativeWWWHistoryLoadCapturesModernPageWhileWebsiteKeepsLegacyURL() throws {
        let provider = MiruroProvider(fixture: true)
        let legacy = try XCTUnwrap(URL(string: "https://www.miruro.cx/watch/1qLBIMfJS3I-ND9HDTRiUHDhvBLN0kco/record-of-ragnarok-ii?ep=6#anime-sync-t=42"))
        let modern = try XCTUnwrap(ProviderPolicy.documentURL(legacy,native: true))
        var requested: [URL] = []
        provider.onFixtureBrowse = { _,url in requested.append(url) }
        provider.open(url: legacy,native: true)
        XCTAssertEqual(provider.currentURL,modern); XCTAssertEqual(requested,[modern])
        let metadata = AnimeMetadata(animeID: "138056",episode: "6",title: "Record of Ragnarok II",watchURL: modern)
        provider.receiveFixture(["type": .string("metadata"), "metadata": .object(metadata.json)])
        XCTAssertEqual(provider.metadata,metadata)
        provider.openWebsite(section: "Episode",url: legacy)
        XCTAssertEqual(provider.currentURL,legacy); XCTAssertTrue(provider.websiteMode)
        XCTAssertEqual(requested,[modern,legacy])
        provider.open(url: try XCTUnwrap(URL(string: "https://www.miruro.cx.evil.example/watch/id/title?ep=6")),native: true)
        XCTAssertEqual(provider.currentURL,legacy); XCTAssertEqual(requested.count,2)
        provider.stop()
    }

    func testDashboardRefreshRetainsOnlySameAccountSnapshotsAndHonorsCompleteEmpty() async {
        let dashboard = DashboardProvider(fixture: true)
        func card(_ key: String) -> JSONValue { .object(["key": .string(key), "title": .string(key), "url": .string("https://miruro.cx/watch/fixture/one-piece?ep=6"), "continuing": .bool(true)]) }
        func library(_ cards: [JSONValue],complete: Bool) -> JSONObject { ["type": .string("library"), "cards": .array(cards), "complete": .bool(complete)] }
        dashboard.load(origin: AppWebPolicy.home,accountGeneration: 7)
        dashboard.receiveFixture(["type": .string("authenticated")])
        dashboard.receiveFixture(library([card("original")],complete: true))
        let original = dashboard.libraryCards
        dashboard.receiveFixture(["type": .string("library"), "cards": .array([])])
        XCTAssertEqual(dashboard.libraryCards,original,"Unmarked empty snapshots are not authoritative")
        dashboard.reload()
        XCTAssertEqual(dashboard.libraryCards,original); XCTAssertTrue(dashboard.authenticated); XCTAssertTrue(dashboard.loading)
        dashboard.receiveFixture(["type": .string("library-status"), "loading": .bool(true)])
        dashboard.receiveFixture(library([],complete: false))
        dashboard.receiveFixture(["type": .string("library"), "cards": .array([]), "loading": .bool(true)])
        XCTAssertEqual(dashboard.libraryCards,original); XCTAssertTrue(dashboard.authenticated)
        dashboard.receiveFixture(library([card("replacement")],complete: true))
        XCTAssertEqual(dashboard.libraryCards.map(\.id),["replacement"]); XCTAssertFalse(dashboard.loading)
        dashboard.receiveFixture(library([],complete: true))
        XCTAssertTrue(dashboard.libraryCards.isEmpty); XCTAssertTrue(dashboard.authenticated)
        dashboard.receiveFixture(library([card("replacement")],complete: true))
        dashboard.load(origin: AppWebPolicy.home,accountGeneration: 8)
        XCTAssertTrue(dashboard.libraryCards.isEmpty); XCTAssertFalse(dashboard.authenticated)
        dashboard.receiveFixture(library([card("new-account")],complete: true))
        dashboard.load(origin: AppWebPolicy.tailnet,accountGeneration: 8)
        XCTAssertTrue(dashboard.libraryCards.isEmpty); XCTAssertFalse(dashboard.authenticated)
        dashboard.receiveFixture(library([card("tailnet")],complete: true))
        await dashboard.signOut()
        XCTAssertTrue(dashboard.libraryCards.isEmpty); XCTAssertFalse(dashboard.authenticated)
    }

    func testShippedDashboardScriptNeverPublishesAProvisionalEmptyLibrary() async throws {
        let source = ProviderScripts.read("dashboard.js")
        XCTAssertFalse(source.isEmpty)
        let capture = DashboardPacketCapture()
        let authenticated = expectation(description: "Fixture page authenticated before data loaded")
        capture.onPacket = { if $0["type"]?.string == "authenticated" { authenticated.fulfill() } }
        let controller = WKUserContentController(); controller.add(capture,name: "dashboardProbe")
        let setup = """
        window.state={authenticated:true,loadInFlight:true,mutationInFlight:false,series:[],items:[]};
        function latestTrackedEpisode(s){return s.latest;}
        function isUpToDateSeries(s){return false;}
        function isNewEpisodeSeries(s){return false;}
        function seriesKey(s){return s.key;}
        function posterUrl(s){return '';}
        function seriesActionUrl(s,e){return s.url;}
        window.AnimeTvFocus={navigate(){},back(){return false;},text(){},isNavigationEvent(){return false;}};
        window.AnimeTv={postMessage:raw=>window.webkit.messageHandlers.dashboardProbe.postMessage({nonce:'dashboard-test',data:raw})};
        """
        controller.addUserScript(WKUserScript(source: setup + source,injectionTime: .atDocumentEnd,forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent(); configuration.userContentController = controller
        let view = WKWebView(frame: .zero,configuration: configuration)
        defer { view.stopLoading(); controller.removeScriptMessageHandler(forName: "dashboardProbe"); controller.removeAllUserScripts() }
        view.loadHTMLString("<!doctype html><html><body><section id='list'></section></body></html>",baseURL: nil)
        await fulfillment(of: [authenticated],timeout: 5)
        capture.onPacket = nil
        XCTAssertFalse(capture.packets.contains { $0["type"]?.string == "library" })
        let complete = expectation(description: "A rendered complete library is published")
        capture.onPacket = { if $0["type"]?.string == "library" { complete.fulfill() } }
        _ = try await view.evaluateJavaScript("state.loadInFlight=false;state.series=[{key:'one',title:'One Piece',latest:{episode:'6',completed:false,progress:0.4},url:'https://miruro.cx/watch/fixture/one-piece?ep=6'}];document.querySelector('#list').innerHTML='<article></article>';window.AnimeTvDashboard.snapshot(true);")
        await fulfillment(of: [complete],timeout: 5)
        capture.onPacket = nil
        XCTAssertEqual(capture.packets.last(where: { $0["type"]?.string == "library" })?["cards"]?.array?.count,1)
        let pending = expectation(description: "Provisional refresh reports loading only")
        capture.onPacket = { if $0["type"]?.string == "library-status", $0["loading"]?.bool == true { pending.fulfill() } }
        _ = try await view.evaluateJavaScript("state.loadInFlight=true;state.series=[];window.AnimeTvDashboard.snapshot(true);")
        await fulfillment(of: [pending],timeout: 5)
        capture.onPacket = nil
        XCTAssertEqual(capture.packets.filter { $0["type"]?.string == "library" }.count,1)
        let empty = expectation(description: "Authoritative empty library is still published")
        capture.onPacket = { if $0["type"]?.string == "library" { empty.fulfill() } }
        _ = try await view.evaluateJavaScript("state.loadInFlight=false;document.querySelector('#list').innerHTML='<div class=empty>No anime</div>';window.AnimeTvDashboard.snapshot(true);")
        await fulfillment(of: [empty],timeout: 5)
        capture.onPacket = nil
        XCTAssertEqual(capture.packets.last(where: { $0["type"]?.string == "library" })?["cards"]?.array?.count,0)
        XCTAssertEqual(capture.packets.last(where: { $0["type"]?.string == "library" })?["complete"]?.bool,true)
    }

    func testNativeDiscoveryAndWebsiteKeepSeparateGesturePolicies() async {
        let provider = MiruroProvider(fixture: true)
        let native = provider.webView
        XCTAssertTrue(native.configuration.mediaTypesRequiringUserActionForPlayback.isEmpty)
        provider.openWebsite(section: "Episode",url: URL(string: "https://miruro.cx/watch/fixture/one-piece?ep=1")!)
        let website = provider.webView
        XCTAssertFalse(native === website)
        XCTAssertEqual(website.configuration.mediaTypesRequiringUserActionForPlayback,.all)
        provider.open(url: URL(string: "https://miruro.cx/watch/fixture/one-piece?ep=1")!,native: true)
        XCTAssertFalse(provider.webView === website)
        XCTAssertTrue(provider.webView.configuration.mediaTypesRequiringUserActionForPlayback.isEmpty)
        provider.stop()
    }

    func testSafariExtensionlessDOMVideoIsReportedWithoutPromotingFrameTrust() async throws {
        let source = ProviderScripts.read("resource-observer.js")
            .replacingOccurrences(of: "__ANIME_SYNC_NONCE__",with: "\"probe-test\"")
            .replacingOccurrences(of: "__ANIME_SYNC_NATIVE__",with: "true")
        XCTAssertFalse(source.isEmpty)
        let received = expectation(description: "Actual observer reports the extensionless video URL")
        let capture = ProbeCandidateCapture(received: received)
        let controller = WKUserContentController(); controller.add(capture,name: "providerResource")
        // A getter supplies a fixture URL without assigning src or making a network load.
        let setup = "Object.defineProperty(document.querySelector('video'),'currentSrc',{get:()=> 'https://cdn.example/source.php?fixture=one'});"
        controller.addUserScript(WKUserScript(source: setup + source,injectionTime: .atDocumentEnd,forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent(); configuration.userContentController = controller
        let view = WKWebView(frame: .zero,configuration: configuration)
        defer { view.stopLoading(); controller.removeScriptMessageHandler(forName: "providerResource"); controller.removeAllUserScripts() }
        view.loadHTMLString("<!doctype html><html><body><video preload='none'></video></body></html>",baseURL: nil)
        // A cold WebKit content process can take several seconds to start on CI.
        await fulfillment(of: [received],timeout: 15)
        XCTAssertEqual(capture.packet?["url"]?.string,"https://cdn.example/source.php?fixture=one")
        XCTAssertEqual(capture.packet?["mediaElement"]?.bool,true)
        XCTAssertNotEqual(capture.packet?["confirmed"]?.bool,true,"A subframe observation must never grant native autoplay/identity authority")
    }

    func testShippedObserverReportsExtensionlessTracksWebVTTAndEmbedSessions() async throws {
        let source = ProviderScripts.read("resource-observer.js")
            .replacingOccurrences(of: "__ANIME_SYNC_NONCE__",with: "\"subtitle-test\"")
            .replacingOccurrences(of: "__ANIME_SYNC_NATIVE__",with: "true")
        XCTAssertFalse(source.isEmpty)
        let received = expectation(description: "Actual observer reports all extensionless subtitle paths")
        received.expectedFulfillmentCount = 3
        let capture = SubtitleCandidateCapture(received: received)
        let controller = WKUserContentController(); controller.add(capture,name: "providerResource")
        // Neither getter nor stub fetch performs a network request.
        let setup = """
        Object.defineProperty(document.querySelector('track'),'src',{get:()=> 'https://cdn.example/track?id=one'});
        window.fetch=()=>Promise.resolve({url:'https://cdn.example/caption?id=two',headers:{get:()=> 'text/vtt; charset=utf-8'}});
        customElements.define('strmcx-embed',class extends HTMLElement{setSession(session){return session.status==='ready';}});
        """
        let invoke = ";window.fetch('fixture');Promise.resolve().then(()=>{const embed=document.querySelector('strmcx-embed');embed.setSession({status:'ready',revision:1,source:{kind:'direct',url:'https://cdn.example/sdk-video',type:'application/x-mpegurl'},tracks:[{src:'https://cdn.example/subtitle?id=three',label:'Français',language:'fr',kind:'subtitles'}]});embed.setSession({status:'invalid',revision:2,tracks:[{src:'https://cdn.example/rejected',label:'Rejected',language:'en',kind:'subtitles'}]});embed.setSession({status:'ready',revision:0,tracks:[{src:'https://cdn.example/stale',label:'Stale',language:'en',kind:'subtitles'}]});});"
        controller.addUserScript(WKUserScript(source: setup + source + invoke,injectionTime: .atDocumentEnd,forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent(); configuration.userContentController = controller
        let view = WKWebView(frame: .zero,configuration: configuration)
        defer { view.stopLoading(); controller.removeScriptMessageHandler(forName: "providerResource"); controller.removeAllUserScripts() }
        view.loadHTMLString("<!doctype html><html><body><video preload='none'><track label='English CC' srclang='en' kind='subtitles'></video><strmcx-embed></strmcx-embed></body></html>",baseURL: nil)
        await fulfillment(of: [received],timeout: 15)
        XCTAssertEqual(Set(capture.packets.compactMap { $0["url"]?.string }),["https://cdn.example/track?id=one", "https://cdn.example/caption?id=two", "https://cdn.example/subtitle?id=three"])
        let track = capture.packets.first { $0["url"]?.string == "https://cdn.example/track?id=one" }
        XCTAssertEqual(track?["label"]?.string,"English CC"); XCTAssertEqual(track?["language"]?.string,"en")
        let session = capture.packets.first { $0["url"]?.string == "https://cdn.example/subtitle?id=three" }
        XCTAssertEqual(session?["label"]?.string,"Français"); XCTAssertEqual(session?["language"]?.string,"fr")
        XCTAssertTrue(capture.packets.allSatisfy { $0["confirmed"]?.bool != true && $0["mediaElement"]?.bool != true })
        XCTAssertEqual(capture.sources.count,1)
        XCTAssertEqual(capture.sources.first?["configured"]?.bool,true)
        XCTAssertNotEqual(capture.sources.first?["confirmed"]?.bool,true,"SDK source headers are still only an unconfirmed media offer")
    }

    func testSubtitleFetchCannotEraseDiscoveredTrackIdentity() {
        let provider = MiruroProvider(fixture: true)
        provider.open(url: URL(string: "https://miruro.cx/watch/fixture/one-piece?ep=1")!,native: true)
        let url = "https://cdn.example/caption?id=one"
        provider.receiveFixture(["type": .string("subtitle"), "url": .string(url), "label": .string("English CC"), "language": .string("en"), "configured": .bool(true), "headers": .object(["Origin": .string("https://strm.cx"), "Referer": .string("https://strm.cx/?embed=1")])])
        provider.receiveFixture(["type": .string("subtitle"), "url": .string(url), "label": .string(""), "language": .string("")])
        XCTAssertEqual(provider.subtitles.count,1)
        XCTAssertEqual(provider.subtitles.first?.label,"English CC"); XCTAssertEqual(provider.subtitles.first?.language,"en")
        XCTAssertEqual(provider.subtitles.first?.headers["Origin"],"https://strm.cx")
        provider.receiveFixture(["type": .string("subtitle"), "url": .string("https://cdn.example/unknown-caption")])
        XCTAssertEqual(provider.subtitles.last?.language,"und","Unlabelled network captions must not invent an English language")
        provider.stop()
    }

    func testWebsiteSourceSelectionRejectsOldOffersAndKeepsCaptionsInItsRevision() {
        let provider = MiruroProvider(fixture: true)
        provider.open(url: URL(string: "https://miruro.cx/watch/fixture/one-piece?ep=1")!,native: true)
        let option: JSONValue = .object(["id": .string("Provider:bee"), "label": .string("bee s-sub"), "selected": .bool(false)])
        let group: JSONValue = .object(["name": .string("Provider"), "items": .array([option])])
        provider.receiveFixture(["type": .string("source-choices"), "groups": .array([group])])
        provider.receiveFixture(["type": .string("source"), "url": .string("https://cdn.example/old.m3u8")])
        provider.receiveFixture(["type": .string("subtitle"), "url": .string("https://cdn.example/old.vtt")])
        let previous = provider.selectionRevision
        provider.selectSourceChoice(id: "Provider:bee")
        XCTAssertGreaterThan(provider.selectionRevision,previous)
        XCTAssertTrue(provider.sources.isEmpty); XCTAssertTrue(provider.subtitles.isEmpty)
        provider.receiveFixture(["type": .string("source"), "url": .string("https://cdn.example/stale.m3u8"), "selection": .string("old-selection")])
        provider.receiveFixture(["type": .string("subtitle"), "url": .string("https://cdn.example/stale.vtt"), "selection": .string("old-selection")])
        XCTAssertTrue(provider.sources.isEmpty); XCTAssertTrue(provider.subtitles.isEmpty)
        provider.receiveFixture(["type": .string("source-session"), "sessionID": .string("current"), "revision": .integer(3), "status": .string("ready")])
        provider.receiveFixture(["type": .string("source"), "url": .string("https://cdn.example/current.m3u8")])
        provider.receiveFixture(["type": .string("subtitle"), "url": .string("https://cdn.example/current-caption"), "label": .string("English"), "language": .string("en")])
        XCTAssertEqual(provider.sources.first?.choiceID,"Provider:bee")
        XCTAssertEqual(provider.subtitles.first?.selectionRevision,provider.selectionRevision)
        XCTAssertEqual(provider.subtitles.first?.choiceID,"Provider:bee")
        let current = provider.selectionRevision
        provider.receiveFixture(["type": .string("source-session"), "sessionID": .string("current"), "revision": .integer(2), "status": .string("ready")])
        XCTAssertEqual(provider.sources.count,1); XCTAssertEqual(provider.selectionRevision,current)
        provider.receiveFixture(["type": .string("source-session"), "sessionID": .string("current"), "revision": .integer(4), "status": .string("resolving")])
        XCTAssertGreaterThan(provider.selectionRevision,current)
        XCTAssertTrue(provider.sources.isEmpty); XCTAssertTrue(provider.subtitles.isEmpty)
        XCTAssertNotEqual(provider.sourceStatus,.ready,"Clearing offers cannot leave a stale native-ready status")
        provider.stop()
    }

    func testSelectedBeeKeepsCurrentHTTPSOffersWhenResolvingCompletesAsBlob() {
        for offerBeforeResolving in [true,false] {
            let provider = MiruroProvider(fixture: true)
            provider.open(url: URL(string: "https://miruro.cx/watch/fixture/one-piece?ep=1")!,native: true)
            provider.receiveFixture(["type": .string("source-session"), "sessionID": .string("episode"), "revision": .integer(1), "status": .string("ready")])
            provider.receiveFixture(["type": .string("source"), "url": .string("https://sun.example/old.m3u8")])
            provider.receiveFixture(["type": .string("subtitle"), "url": .string("https://sun.example/old.vtt")])
            let option: JSONValue = .object(["id": .string("Provider:bee"), "label": .string("bee s-sub"), "selected": .bool(false)])
            let group: JSONValue = .object(["name": .string("Provider"), "items": .array([option])])
            provider.receiveFixture(["type": .string("source-choices"), "groups": .array([group])])
            provider.selectSourceChoice(id: "Provider:bee")
            let revision = provider.selectionRevision
            let source: JSONObject = ["type": .string("source"), "url": .string("https://bee.example/current.m3u8"), "mime": .string("application/vnd.apple.mpegurl")]
            if offerBeforeResolving { provider.receiveFixture(source) }
            provider.receiveFixture(["type": .string("source-session"), "sessionID": .string("episode"), "revision": .integer(2), "status": .string("resolving")])
            if !offerBeforeResolving { provider.receiveFixture(source) }
            provider.receiveFixture(["type": .string("subtitle"), "url": .string("https://bee.example/current.vtt"), "label": .string("English"), "language": .string("en")])
            // The real SDK completes with a blob URL, which cannot be offered to
            // AVPlayer. Its earlier request-captured HTTPS offer is still current.
            provider.receiveFixture(["type": .string("source-session"), "sessionID": .string("episode"), "revision": .integer(3), "status": .string("ready")])
            provider.receiveFixture(["type": .string("source"), "url": .string("https://sun.example/stale.m3u8"), "selection": .string("old-selection")])
            provider.receiveFixture(["type": .string("subtitle"), "url": .string("https://sun.example/stale.vtt"), "selection": .string("old-selection")])
            XCTAssertEqual(provider.sources.compactMap { $0.url.host },["bee.example"])
            XCTAssertEqual(provider.subtitles.compactMap { $0.url.host },["bee.example"])
            XCTAssertEqual(provider.sources.first?.choiceID,"Provider:bee")
            XCTAssertEqual(provider.sources.first?.selectionRevision,revision)
            XCTAssertEqual(provider.subtitles.first?.selectionRevision,revision)
            XCTAssertEqual(provider.selectionRevision,revision,"Completing a pending choice must not invalidate its captured source")
            XCTAssertEqual(provider.sourceStatus,.ready)
            provider.stop()
        }
    }

    func testInitialBlobSessionKeepsFreshDocumentOffersButNextCycleClearsThem() {
        let provider = MiruroProvider(fixture: true)
        provider.open(url: URL(string: "https://miruro.cx/watch/fixture/one-piece?ep=1")!,native: true)
        provider.receiveFixture(["type": .string("source"), "url": .string("https://bee.example/current.m3u8")])
        provider.receiveFixture(["type": .string("source-session"), "sessionID": .string("episode"), "revision": .integer(3), "status": .string("ready")])
        XCTAssertEqual(provider.sources.count,1); XCTAssertEqual(provider.sourceStatus,.ready)
        provider.receiveFixture(["type": .string("source-session"), "sessionID": .string("episode"), "revision": .integer(4), "status": .string("resolving")])
        XCTAssertTrue(provider.sources.isEmpty); XCTAssertEqual(provider.sourceStatus,.waitingForStream)
        provider.receiveFixture(["type": .string("source-session"), "sessionID": .string("episode"), "revision": .integer(5), "status": .string("ready")])
        XCTAssertTrue(provider.sources.isEmpty); XCTAssertNotEqual(provider.sourceStatus,.ready)
        provider.stop()
    }

    func testConfiguredMediaHeadersUpgradeGenericOffersWithoutDowngradingConfirmedSources() {
        for genericFirst in [true,false] {
            let provider = MiruroProvider(fixture: true)
            provider.open(url: URL(string: "https://miruro.cx/watch/fixture/one-piece?ep=1")!,native: true)
            func offer(origin: String,configured: Bool,confirmed: Bool = false) -> JSONObject {
                ["type": .string("source"), "url": .string("https://cdn.example/video.m3u8"), "configured": .bool(configured), "confirmed": .bool(confirmed), "headers": .object(["Origin": .string(origin), "Referer": .string(origin + "/")])]
            }
            let generic = offer(origin: "https://miruro.cx",configured: false)
            let configured = offer(origin: "https://strm.cx",configured: true)
            for packet in genericFirst ? [generic,configured] : [configured,generic] { provider.receiveFixture(packet) }
            XCTAssertEqual(provider.sources.count,1)
            XCTAssertEqual(provider.sources.first?.headers["Origin"],"https://strm.cx")
            XCTAssertEqual(provider.sources.first?.configured,true)
            XCTAssertEqual(provider.sources.first?.confirmed,false,"Configured headers cannot grant main-frame playback authority")
            provider.receiveFixture(offer(origin: "https://different-player.example",configured: false))
            XCTAssertEqual(provider.sources.first?.headers["Origin"],"https://strm.cx")
            provider.receiveFixture(offer(origin: "https://confirmed-player.example",configured: false,confirmed: true))
            provider.receiveFixture(configured)
            XCTAssertEqual(provider.sources.first?.headers["Origin"],"https://confirmed-player.example")
            XCTAssertEqual(provider.sources.first?.confirmed,true)
            provider.stop()
        }
    }

    func testFailedWebsiteSourceSelectionReloadsAndReopensDiscovery() {
        let provider = MiruroProvider(fixture: true)
        let page = URL(string: "https://miruro.cx/watch/fixture/one-piece?ep=1")!
        provider.open(url: page,native: true)
        let option: JSONValue = .object(["id": .string("Provider:bee"), "label": .string("bee s-sub"), "selected": .bool(false)])
        provider.receiveFixture(["type": .string("source-choices"), "groups": .array([.object(["name": .string("Provider"), "items": .array([option])])])])
        var reloads = 0
        provider.onFixtureBrowse = { _,url in XCTAssertEqual(url,page); reloads += 1 }
        provider.onFixtureSourceChoice = { _ in false }
        let revision = provider.selectionRevision
        provider.selectSourceChoice(id: "Provider:bee")
        XCTAssertEqual(reloads,1); XCTAssertEqual(provider.currentURL,page)
        XCTAssertTrue(provider.selectedChoiceID.isEmpty); XCTAssertFalse(provider.sourceChoicesLoading)
        XCTAssertGreaterThan(provider.selectionRevision,revision)
        XCTAssertTrue(provider.error?.contains("reloaded") == true)
        provider.receiveFixture(["type": .string("source"), "url": .string("https://cdn.example/fresh.m3u8"), "selection": .string("")])
        XCTAssertEqual(provider.sources.count,1,"A fresh document must not retain the failed selection token")
        XCTAssertEqual(provider.sources.first?.choiceID,"")
        provider.stop()
    }

    func testCompleteNamedEpisodeInventoryKeepsItemsBeyondFirstPageAndValidatesRoutes() {
        let provider = MiruroProvider(fixture: true)
        let page = URL(string: "https://miruro.cx/watch/fixture/one-piece?ep=1000")!
        provider.open(url: page,native: true)
        var items: [JSONValue] = []
        items.reserveCapacity(1180)
        for number in (1...1180).reversed() {
            let value = String(number)
            var item: JSONObject = [:]
            item["id"] = .string(value)
            item["number"] = .string(value)
            item["label"] = .string("Episode \(value)")
            item["title"] = .string("Actual supplied title \(value)")
            item["url"] = .string("https://miruro.cx/watch/fixture/one-piece?ep=\(value)")
            item["selected"] = .bool(number == 1000)
            items.append(.object(item))
        }
        provider.receiveFixture(["type": .string("episodes"), "complete": .bool(true), "episodes": .array(items + [items[0]])])
        XCTAssertEqual(provider.episodes.count,1180); XCTAssertTrue(provider.episodeInventoryComplete)
        XCTAssertEqual(provider.episodes.first?.number,"1"); XCTAssertEqual(provider.episodes.last?.number,"1180")
        XCTAssertEqual(provider.episodes.last?.title,"Actual supplied title 1180")
        XCTAssertEqual(provider.episodes.first(where: { $0.selected })?.number,"1000")
        XCTAssertNotNil(provider.episodes.last?.url)
        provider.receiveFixture(["type": .string("episodes"), "episodes": .array([.object(["id": .string("1"), "number": .string("1"), "label": .string("Episode 1"), "url": .string("https://miruro.cx/watch/other/anime?ep=1")])])])
        XCTAssertNil(provider.episodes.first?.url); XCTAssertFalse(provider.episodeInventoryComplete)
        provider.stop()
    }

    func testExtensionlessMediaUsesValidatedMIMEOrMediaMagic() async {
        let url = URL(string: "https://cdn.example/source.php?fixture=one")!
        XCTAssertFalse(MediaSource(url: url).nativePlayable)
        for value in ["application/x-mpegurl", "Application/Vnd.Apple.Mpegurl; charset=utf-8", "audio/mpegurl"] {
            let mime = MediaSourceProbe.canonicalMIME(value)
            XCTAssertEqual(mime,"application/vnd.apple.mpegurl")
            XCTAssertTrue(MediaSource(url: url,mimeType: mime ?? "").nativePlayable)
        }
        XCTAssertEqual(MediaSourceProbe.sniff(Data("#EXTM3U\n#EXT-X-VERSION:3\n".utf8)),"application/vnd.apple.mpegurl")
        XCTAssertEqual(MediaSourceProbe.sniff(Data([0,0,0,20,102,116,121,112,105,115,111,109])),"video/mp4")
        XCTAssertNil(MediaSourceProbe.sniff(Data("<html>not a playlist</html>".utf8)))
        XCTAssertNil(MediaSourceProbe.canonicalMIME("text/html"))
        let backend = await MediaSourceProbe.mimeType(url: AppWebPolicy.home,headers: [:])
        XCTAssertNil(backend,"Backend URLs must be rejected before creating a probe request")
    }

    func testPrivacyRulesCompileInRealWebKitAndPreservePrivateNetworkScope() async throws {
        // This is the same compiler/path used before any real provider navigation.
        // It makes no network requests, including to the blocked backend examples.
        _ = try await ProviderRuleLists.privateRequests()
        let filters = ProviderRuleLists.privateFilters
        func blocked(_ raw: String) -> Bool {
            filters.contains { raw.range(of: $0, options: .regularExpression) != nil }
        }
        for url in ["https://anime-sync.example", "https://anime-sync.example/api/progress", "https://anime-sync.example:8443/",
                    "https://anime-sync-tailnet.example:8443/", "http://10.0.0.10/", "https://10.0.0.1/",
                    "http://172.16.0.1/", "https://172.21.1.8/", "http://172.31.1.2/", "http://localhost/",
                    "https://127.0.0.1:8765/", "http://[::1]:8765/"] { XCTAssertTrue(blocked(url), url) }
        for url in ["https://miruro.cx/", "https://cdn.example/video.m3u8", "https://172.15.0.1/", "https://172.32.0.1/",
                    "https://anime-sync.example.evil.example/", "https://localhost.example/"] { XCTAssertFalse(blocked(url), url) }
    }

    func testControlPacketsRequireCurrentNonceValidJSONAndBoundedUTF8() {
        let valid: [String: Any] = ["nonce": "current", "data": "{\"type\":\"catalogue\"}"]
        XCTAssertEqual(ProviderScripts.packet(valid, nonce: "current", maximum: 200)?["type"]?.string, "catalogue")
        XCTAssertNil(ProviderScripts.packet(valid, nonce: "old", maximum: 200))
        XCTAssertNil(ProviderScripts.packet(valid, nonce: "current", maximum: 5))
        XCTAssertNil(ProviderScripts.packet(["nonce": "current", "data": ["type": "catalogue"]], nonce: "current", maximum: 200))
        XCTAssertNil(ProviderScripts.packet(["nonce": "current", "data": "[]"], nonce: "current", maximum: 200))
        XCTAssertNil(ProviderScripts.packet(["nonce": "current", "data": "{\"type\":\"ééé\"}"], nonce: "current", maximum: 15))
    }

    func testOnlyOrdinaryNonBackendHeadersReachMedia() {
        let headers = MediaBridgePolicy.headers([
            "referer": "https://player.example/watch/1", "Origin": "https://player.example", "user-agent": "Fixture WebKit",
            "Authorization": "fixture-only", "Cookie": "fixture-only", "X-Anime-Sync-Token": "fixture-only"
        ])
        XCTAssertEqual(headers, ["Referer": "https://player.example/watch/1", "Origin": "https://player.example", "User-Agent": "Fixture WebKit"])
        XCTAssertTrue(MediaBridgePolicy.headers(["Referer": AppWebPolicy.home.absoluteString, "Origin": "https://user:pass@player.example", "User-Agent": "value\r\nCookie: invalid"]).isEmpty)
        for value in ["value\r\nCookie: invalid", "value\rCookie: invalid", "value\nCookie: invalid", "value\u{0}invalid", "value\u{7F}invalid"] {
            XCTAssertTrue(MediaBridgePolicy.headers(["User-Agent": value]).isEmpty, "Control scalars must be rejected even when CRLF forms one Character")
        }
        XCTAssertTrue(MediaBridgePolicy.headers(["Referer": "https://anime-sync.example:8443/private"]).isEmpty)
        XCTAssertEqual(ProviderPolicy.ordinaryHeaders(nil, frameURL: URL(string: "https://player.example/watch/1")!)["Referer"], "https://player.example/watch/1")
        XCTAssertTrue(ProviderPolicy.ordinaryHeaders(nil, frameURL: AppWebPolicy.home).isEmpty)
    }

    func testMediaPolicyRejectsBackendCredentialsHTTPAndPrivateTargets() {
        for value in ["https://cdn.example/video.mp4?token=signed-media", "https://cdn.example:8443/index.m3u8"] {
            XCTAssertTrue(MediaBridgePolicy.allows(URL(string: value)!), value)
        }
        for value in [AppWebPolicy.home.absoluteString + "/video.mp4", "https://anime-sync.example:8443/video.mp4", AppWebPolicy.tailnet.absoluteString + "/video.mp4",
                      "http://cdn.example/video.mp4", "https://user:pass@cdn.example/video.mp4", "https://10.0.0.10/video.mp4", "https://10.0.0.5/video.mp4",
                      "https://172.22.0.1/video.mp4", "https://100.64.0.42/video.mp4", "https://127.0.0.1/video.mp4", "https://2130706433/video.mp4", "https://0x7f000001/video.mp4", "https://0177.0.0.1/video.mp4",
                      "https://localhost/video.mp4", "https://server.local/video.mp4", "https://[::1]/video.mp4", "skd://key", "data:text/plain,abc"] {
            XCTAssertFalse(MediaBridgePolicy.allows(URL(string: value)!), value)
        }
        XCTAssertTrue(MediaBridgePolicy.range("bytes=0-1")); XCTAssertTrue(MediaBridgePolicy.range("bytes=100-")); XCTAssertTrue(MediaBridgePolicy.range("bytes=-500"))
        for value in ["bytes=", "bytes=0-1,2-3", "bytes=0-1\n", "items=0-1", "bytes=0-1\r\nCookie: x"] { XCTAssertFalse(MediaBridgePolicy.range(value), value) }
    }

    func testHLSMasterVariantsAudioSubtitlesKeysAndSegmentsAreRegistryURLs() throws {
        let base = URL(string: "https://cdn.example/path/master.m3u8?token=master")!
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Japanese",URI="audio/index.m3u8?token=a"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="../sub/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="audio",SUBTITLES="subs"
        variants/720.m3u8?token=video
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=800000,URI="iframe.m3u8"
        #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example/key?token=k"
        #EXT-X-MAP:URI="init.mp4",BYTERANGE="100@0"
        #EXTINF:6,
        segments/001.m4s
        #EXT-X-PART:DURATION=0.5,URI="segments/002.m4s"
        #EXT-X-RENDITION-REPORT:URI="other.m3u8",LAST-MSN=4
        #EXT-X-ENDLIST
        """
        var mapped: [(URL, Bool)] = []
        let result = try MediaBridgePolicy.manifest(Data(text.utf8), base: base) { url, playlist in
            mapped.append((url, playlist)); return URL(string: "http://127.0.0.1:12345/capability/\(mapped.count)/asset.\(playlist ? "m3u8" : "bin")")!
        }
        let output = try XCTUnwrap(String(data: result, encoding: .utf8))
        XCTAssertEqual(mapped.count, 9)
        XCTAssertEqual(mapped.filter(\.1).count, 5)
        XCTAssertTrue(mapped.contains { $0.0.absoluteString == "https://cdn.example/path/variants/720.m3u8?token=video" && $0.1 })
        XCTAssertTrue(mapped.contains { $0.0.absoluteString == "https://keys.example/key?token=k" && !$0.1 })
        XCTAssertTrue(mapped.contains { $0.0.absoluteString == "https://cdn.example/sub/index.m3u8" && $0.1 })
        XCTAssertTrue(output.contains("#EXTM3U")); XCTAssertTrue(output.contains("BYTERANGE=\"100@0\"")); XCTAssertTrue(output.contains("#EXT-X-ENDLIST"))
        XCTAssertFalse(output.contains("https://")); XCTAssertFalse(output.contains("token="))
        XCTAssertEqual(output.components(separatedBy: "http://127.0.0.1:12345/capability/").count - 1, 9)
    }

    func testHLSUnsupportedDRMVariablesSteeringAndBackendURIsFailClosed() throws {
        let base = URL(string: "https://cdn.example/index.m3u8")!
        let invalid = [
            "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://asset\"\nseg.ts",
            "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT=\"com.apple.streamingkeydelivery\",URI=\"https://key.example/asset\"\nseg.ts",
            "#EXTM3U\n#EXT-X-DEFINE:NAME=\"path\",VALUE=\"video\"\n{$path}/seg.ts",
            "#EXTM3U\n#EXT-X-CONTENT-STEERING:SERVER-URI=\"https://cdn.example/steering.json\"\nseg.ts",
            "#EXTM3U\n" + AppWebPolicy.home.absoluteString + "/private",
            "#EXTM3U\nhttp://cdn.example/segment.ts", "#EXTM3U\ndata:text/plain,segment", "<html>challenge page</html>"
        ]
        for value in invalid {
            XCTAssertThrowsError(try MediaBridgePolicy.manifest(Data(value.utf8), base: base) { _, _ in URL(string: "http://127.0.0.1:12345/capability/resource")! }, value)
        }
        XCTAssertThrowsError(try MediaBridgePolicy.manifest(Data(repeating: 32, count: MediaBridgePolicy.maximumManifestBytes + 1), base: base) { _, _ in base })
    }

    func testHLSMultipleQuotedResourcesKeepUnicodeAndAttributeBoundaries() throws {
        let text = "#EXTM3U\n#EXT-X-MEDIA:NAME=\"日本語\",URI=\"a.m3u8\",X-URI=\"leave-as-metadata\"\n#EXT-X-MAP:URI=\"init.mp4\"\nseg.ts"
        var count = 0
        let rewritten = try MediaBridgePolicy.manifest(Data(text.utf8), base: URL(string: "https://cdn.example/path/index.m3u8")!) { _, _ in count += 1; return URL(string: "http://127.0.0.1/\(count)")! }
        let output = try XCTUnwrap(String(data: rewritten, encoding: .utf8))
        XCTAssertEqual(count, 3); XCTAssertTrue(output.contains("NAME=\"日本語\"")); XCTAssertTrue(output.contains("X-URI=\"leave-as-metadata\""))
    }

    func testNativePlayableRecognizesHLSMP4AndLeavesDASHWebMToWebsite() {
        XCTAssertTrue(MediaSource(url: URL(string: "https://cdn.example/index.m3u8")!).nativePlayable)
        XCTAssertTrue(MediaSource(url: URL(string: "https://cdn.example/video.mp4")!).nativePlayable)
        XCTAssertTrue(MediaSource(url: URL(string: "https://cdn.example/stream?token=one")!, mimeType: "application/vnd.apple.mpegurl; charset=UTF-8").nativePlayable)
        XCTAssertFalse(MediaSource(url: URL(string: "https://cdn.example/index.mpd")!).nativePlayable)
        XCTAssertFalse(MediaSource(url: URL(string: "https://cdn.example/video.webm")!).nativePlayable)
    }

    func testFixtureProviderClearsOldRouteAndBindsBrowserSamplesToCurrentIdentity() throws {
        let provider = MiruroProvider(fixture: true)
        let first = URL(string: "https://miruro.cx/watch/fixture/one-piece?ep=6")!
        provider.open(url: first, native: false)
        let metadata = AnimeMetadata(animeID: "21", episode: "6", title: "Fixture", watchURL: first)
        provider.receiveFixture(["type": .string("metadata"), "metadata": .object(metadata.json)])
        provider.receiveFixture(["type": .string("source"), "url": .string("https://cdn.example/old.m3u8"), "confirmed": .bool(true)])
        provider.receiveFixture(["type": .string("source"), "url": .string("https://cdn.example/old.mpd")])
        XCTAssertEqual(provider.sources.count, 1); XCTAssertEqual(provider.unsupportedSources.count, 1)
        provider.receiveFixture(["type": .string("source"), "url": .string("https://cdn.example/old.m3u8"), "headers": .object(["Origin": .string("https://different-player.example")])])
        XCTAssertEqual(provider.sources.first?.headers["Origin"], "https://miruro.cx", "A later unconfirmed offer cannot replace a confirmed source's headers")
        var received = 0; provider.onBrowserPlayback = { if case .started = $0 { received += 1 } }
        var wrong = metadata; wrong.episode = "7"
        provider.receiveFixture(["type": .string("playback-start"), "metadata": .object(wrong.json), "explicit": .bool(true)])
        XCTAssertEqual(received, 0)
        provider.receiveFixture(["type": .string("playback-start"), "metadata": .object(metadata.json), "explicit": .bool(true)])
        XCTAssertEqual(received, 1)
        let second = URL(string: "https://miruro.cx/watch/fixture/one-piece?ep=7")!
        provider.receiveFixture(["type": .string("route"), "url": .string(second.absoluteString)])
        XCTAssertEqual(provider.currentURL, second); XCTAssertNil(provider.metadata); XCTAssertTrue(provider.sources.isEmpty); XCTAssertTrue(provider.unsupportedSources.isEmpty)
        provider.receiveFixture(["type": .string("metadata"), "metadata": .object(metadata.json)])
        XCTAssertNil(provider.metadata)
        provider.receiveFixture(["type": .string("playback-start"), "metadata": .object(metadata.json), "explicit": .bool(true)])
        XCTAssertEqual(received, 1)
        provider.stop()
    }

    func testDashboardUsesRealCardSchemaAndKeepsAuthenticationOutOfFixture() throws {
        let dashboard = DashboardProvider(fixture: true)
        var registrations = 0; dashboard.onAuthenticated = { _, _ in registrations += 1 }
        dashboard.load(origin: AppWebPolicy.home)
        dashboard.receiveFixture(["type": .string("authenticated")])
        dashboard.receiveFixture(["type": .string("library"), "complete": .bool(true), "cards": .array([
            .object(["key": .string("miruro:21"), "title": .string("One Piece"), "url": .string("https://miruro.cx/watch/fixture/one-piece?ep=6"), "episode": .string("6"), "progress": .number(0.6), "continuing": .bool(true)]),
            .object(["key": .string("private"), "url": .string(AppWebPolicy.home.absoluteString + "/private")])
        ])])
        XCTAssertTrue(dashboard.authenticated); XCTAssertEqual(registrations, 0); XCTAssertEqual(dashboard.libraryCards.count, 1)
        XCTAssertEqual(dashboard.libraryCards.first?.progress, 0.6)
        dashboard.load(origin: AppWebPolicy.tailnet)
        XCTAssertFalse(dashboard.authenticated); XCTAssertTrue(dashboard.libraryCards.isEmpty)
    }

    func testDashboardLogoutClearsFixtureAndScopesOnlyBackendCookieDomains() async {
        XCTAssertTrue(DashboardProvider.belongsToDashboard("anime-sync.example"))
        XCTAssertTrue(DashboardProvider.belongsToDashboard(".example"))
        XCTAssertTrue(DashboardProvider.belongsToDashboard("anime-sync-tailnet.example"))
        for domain in ["miruro.cx", "cdn.example", "anime-sync.example.evil.example", "evil-anime-sync.example", ""] {
            XCTAssertFalse(DashboardProvider.belongsToDashboard(domain), domain)
        }
        let dashboard = DashboardProvider(fixture: true)
        dashboard.load(origin: AppWebPolicy.home); dashboard.receiveFixture(["type": .string("authenticated")])
        XCTAssertTrue(dashboard.authenticated)
        await dashboard.signOut()
        XCTAssertFalse(dashboard.authenticated); XCTAssertFalse(dashboard.loading); XCTAssertTrue(dashboard.libraryCards.isEmpty)
    }
}
