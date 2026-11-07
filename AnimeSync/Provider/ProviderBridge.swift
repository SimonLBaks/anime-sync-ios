import Foundation
import WebKit
#if !PROVIDER_RULES_ONLY
import SwiftUI

@MainActor final class ScriptReceiver: NSObject, WKScriptMessageHandler {
    weak var owner: MiruroProvider?
    weak var dashboard: DashboardProvider?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let owner { owner.receive(message) }
        else { dashboard?.receive(message) }
    }
}

enum ProviderScripts {
    static func read(_ name: String) -> String {
        // Xcode copies these three resource files into the application bundle root.
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard let path = Bundle.main.url(forResource: stem, withExtension: ext), let value = try? String(contentsOf: path, encoding: .utf8) else { return "" }
        return value
    }
    static func origin(_ frame: WKFrameInfo) -> URL? {
        let source = frame.securityOrigin
        guard source.protocol.lowercased() == "https", !source.host.isEmpty else { return nil }
        let port = source.port == 0 || source.port == 443 ? "" : ":\(source.port)"
        return URL(string: "https://\(source.host.lowercased())\(port)")
    }
    static func packet(_ body: Any, nonce: String, maximum: Int) -> JSONObject? {
        guard let envelope = body as? [String: Any], envelope["nonce"] as? String == nonce,
              let raw = envelope["data"] as? String, raw.utf8.count <= maximum,
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONObject.self, from: data)
    }
    static func bootstrap(nonce: String, handler: String, origins: Set<String>) -> String {
        let allowed = (try? JSONEncoder().encode(Array(origins))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        (()=>{if(window.top!==window||!\(allowed).includes(location.origin))return;
        window.AnimeTv={postMessage:raw=>window.webkit.messageHandlers.\(handler).postMessage({nonce:\(ProviderPolicy.jsonLiteral(nonce)),data:typeof raw==='string'?raw:JSON.stringify(raw)})};})();
        """
    }
    /// Coordinates are local UIKit points; convert them to this document's viewport.
    /// This read-only hit-test does not let provider frames send navigation commands.
    static func backSwipeHitTest(at point: CGPoint, size: CGSize) -> String {
        guard point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return "false" }
        return """
        (()=>{
          const px=\(point.x),py=\(point.y),width=\(size.width),height=\(size.height);
          if(px<0||py<0||px>width||py>height)return false;
          const x=px*innerWidth/width,y=py*innerHeight/height;
          let element=document.elementFromPoint(x,y);
          for(let depth=0;element?.shadowRoot&&depth<10;depth++){
            const inner=element.shadowRoot.elementFromPoint?.(x,y);if(!inner||inner===element)break;element=inner;
          }
          const selector='input,textarea,select,option,button,[contenteditable]:not([contenteditable="false"]),[role="slider"],[role="scrollbar"],[role="tablist"],[role="tab"],[role="listbox"],[role="combobox"],video,audio,iframe,strmcx-embed';
          for(let depth=0;element&&depth<100;depth++){
            if(element.matches?.(selector))return false;
            const style=getComputedStyle(element);
            if(/auto|scroll/.test(style.overflowX)&&element.scrollWidth>element.clientWidth+2)return false;
            element=element.parentElement||element.getRootNode?.().host;
          }
          return true;
        })();
        """
    }
}
#endif

@MainActor enum ProviderRuleLists {
    private static var request: Task<WKContentRuleList, Error>?
    static let privateFilters: [String] = {
        // WebKit's content blocker regexp grammar only permits ^/$ at the
        // expression boundaries. Split host alternatives and host endings into
        // separate rules instead of putting $ inside (:|/|$).
        let hosts = AppConfiguration.current.dashboardHosts.sorted().map(NSRegularExpression.escapedPattern(for:)) +
                    ["localhost", #"127\.0\.0\.1"#, #"\[::1\]"#]
        var filters = hosts.flatMap { ["^https?://" + $0 + "[:/]", "^https?://" + $0 + "$"] }
        filters += [#"^https?://192\.168\."#, #"^https?://10\."#,
                    #"^https?://172\.1[6-9]\."#, #"^https?://172\.2[0-9]\."#, #"^https?://172\.3[01]\."#]
        return filters
    }()
    static func privateRequests() async throws -> WKContentRuleList {
        if let request { return try await request.value }
        let task = Task { @MainActor in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WKContentRuleList, Error>) in
                let objects = privateFilters.map { ["trigger": ["url-filter": $0], "action": ["type": "block"]] }
                guard let data = try? JSONSerialization.data(withJSONObject: objects), let rules = String(data: data, encoding: .utf8) else {
                    continuation.resume(throwing: NSError(domain: "AnimeSync.ProviderRules", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Could not encode the provider privacy rules."])); return
                }
                WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "anime-sync-provider-private-boundary-v2", encodedContentRuleList: rules) { list, error in
                    if let list { continuation.resume(returning: list) }
                    else { continuation.resume(throwing: error ?? NSError(domain: "AnimeSync.ProviderRules", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "The provider privacy rule compiler did not respond."])) }
                }
            }
        }
        request = task
        do { return try await task.value } catch { request = nil; throw error }
    }
}

#if !PROVIDER_RULES_ONLY
final class ProviderWebContainer: UIView {
    private var hosted: WKWebView?
    private var edges: [NSLayoutConstraint] = []
    func install(_ view: WKWebView) {
        guard hosted !== view else { return }
        NSLayoutConstraint.deactivate(edges); hosted?.removeFromSuperview(); hosted = view
        view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view)
        edges = [view.leadingAnchor.constraint(equalTo: leadingAnchor),view.trailingAnchor.constraint(equalTo: trailingAnchor),
                 view.topAnchor.constraint(equalTo: topAnchor),view.bottomAnchor.constraint(equalTo: bottomAnchor)]
        NSLayoutConstraint.activate(edges)
    }
}
struct ProviderWebView: UIViewRepresentable {
    @ObservedObject var provider: MiruroProvider
    var visible = true
    func makeUIView(context: Context) -> ProviderWebContainer { let view = ProviderWebContainer(); view.install(provider.webView); return view }
    func updateUIView(_ uiView: ProviderWebContainer, context: Context) {
        uiView.install(provider.webView)
        let interactive = visible && provider.websiteMode
        uiView.accessibilityElementsHidden = !interactive; uiView.isUserInteractionEnabled = interactive
        provider.webView.accessibilityElementsHidden = !interactive; provider.webView.isUserInteractionEnabled = interactive
    }
}
struct DashboardWebView: UIViewRepresentable {
    @ObservedObject var dashboard: DashboardProvider
    var visible = true
    func makeUIView(context: Context) -> WKWebView { dashboard.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.accessibilityElementsHidden = !visible
        uiView.isUserInteractionEnabled = visible
    }
}
#endif
