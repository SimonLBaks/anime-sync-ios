import Foundation

enum AppWebPolicy {
    static let home = AppConfiguration.current.homeURL
    static let tailnet = AppConfiguration.current.tailnetURL
    static let dashboards = AppConfiguration.current.dashboardOrigins
    static let providers: Set<String> = ["https://miruro.cx", "https://www.miruro.cx", "https://miruro.to", "https://www.miruro.to"]
    static func origin(_ url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.user == nil, parts.password == nil,
              let host = parts.host?.lowercased(), !host.isEmpty, let scheme = parts.scheme?.lowercased() else { return nil }
        let port = parts.port
        return "\(scheme)://\(host)" + ((port == nil || scheme == "https" && port == 443) ? "" : ":\(port!)")
    }
    static func isDashboard(_ url: URL) -> Bool { origin(url).map(dashboards.contains) ?? false }
    static func isProvider(_ url: URL) -> Bool { origin(url).map(providers.contains) ?? false }
    static func isMediaOrigin(_ url: URL) -> Bool { origin(url)?.hasPrefix("https://") == true && !isDashboard(url) }
    static func isMedia(_ url: URL) -> Bool { isMediaOrigin(url) && ["m3u8", "mp4", "mpd", "webm"].contains(url.pathExtension.lowercased()) }
    static func isSubtitle(_ url: URL) -> Bool { isMediaOrigin(url) && ["vtt", "srt", "ass", "ssa", "ttml"].contains(url.pathExtension.lowercased()) }
    static func identity(animeID: String, episode: String) -> Bool {
        animeID.range(of: "^[0-9]{1,12}\\z", options: .regularExpression) != nil && episode.range(of: "^[0-9]{1,5}(\\.[0-9]{1,3})?\\z", options: .regularExpression) != nil
    }
    static func resume(position: Double, duration: Double, completed: Bool) -> TimeInterval {
        guard !completed, position.isFinite, duration.isFinite, position >= 5, duration > position + 5 else { return 0 }
        return position
    }
    static func resolvedWatch(page: URL, target: URL, animeID: String, episode: String) -> Bool {
        guard isProvider(page), isProvider(target), origin(page) == origin(target), identity(animeID: animeID, episode: episode),
              page.path == "/search", target.path.range(of: "^/watch/[^/]+/[^/]+/?\\z", options: .regularExpression) != nil,
              let request = parameters(URLComponents(url: page, resolvingAgainstBaseURL: false)?.percentEncodedFragment),
              let query = parameters(URLComponents(url: target, resolvingAgainstBaseURL: false)?.percentEncodedQuery),
              let fragment = parameters(URLComponents(url: target, resolvingAgainstBaseURL: false)?.percentEncodedFragment),
              request["anime-sync-id"] == animeID, request["anime-sync-ep"] == episode,
              query.count == 1, query["ep"] == episode else { return false }
        if let resume = request["anime-sync-t"] { return fragment.count == 1 && fragment["anime-sync-t"] == resume }
        return fragment.isEmpty
    }
    private static func parameters(_ encoded: String?) -> [String: String]? {
        guard let encoded = encoded, !encoded.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for pair in encoded.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let value = (parts.count > 1 ? String(parts[1]) : "").replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  result[key] == nil else { return nil }
            result[key] = value
        }
        return result
    }
}

enum TVAddress {
    static func host(_ input: String) throws -> String {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URLComponents(string: raw.contains("://") ? raw : "http://" + raw), u.scheme == "http", u.user == nil, u.password == nil,
              u.query == nil, u.fragment == nil, u.port == nil || u.port == 8765, u.path.isEmpty || u.path == "/", let host = u.host else { throw CoreError.invalidTVAddress }
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { throw CoreError.invalidTVAddress }
        var octets: [Int] = []
        for part in pieces {
            guard part.range(of: "^(0|[1-9][0-9]{0,2})\\z", options: .regularExpression) != nil, let n = Int(part), n <= 255 else { throw CoreError.invalidTVAddress }
            octets.append(n)
        }
        guard octets[0] == 10 || octets[0] == 192 && octets[1] == 168 || octets[0] == 172 && (16...31).contains(octets[1]) else { throw CoreError.invalidTVAddress }
        return host
    }
    static func base(_ input: String) throws -> URL { URL(string: "http://\(try host(input)):8765")! }
}
