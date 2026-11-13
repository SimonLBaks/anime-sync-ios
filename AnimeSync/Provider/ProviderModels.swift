import Foundation

struct CatalogueCard: Identifiable, Equatable {
    var id: String { url.absoluteString }
    var title: String
    var posterURL: URL?
    var url: URL
    var badge: String
    init(title: String, posterURL: URL? = nil, url: URL, badge: String = "") {
        self.title = title; self.posterURL = posterURL; self.url = url; self.badge = badge
    }
    init?(json: JSONObject) {
        guard let text = json["title"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let value = json["url"]?.string, let url = URL(string: value), AppWebPolicy.isProvider(url) else { return nil }
        self.init(title: String(text.prefix(500)), posterURL: ProviderPolicy.imageURL(json["poster"]?.string), url: url,
                  badge: String((json["badge"]?.string ?? "").prefix(120)))
    }
}
struct CatalogueGroup: Identifiable, Equatable {
    var id: String { title }
    var title: String
    var items: [CatalogueCard]
    init(title: String, items: [CatalogueCard]) { self.title = title; self.items = items }
}
struct SearchSuggestion: Identifiable, Equatable {
    let card: CatalogueCard
    let year: String
    let format: String
    let episodeCount: String
    let score: String
    var id: String { card.id }

    init?(json: JSONObject, page: URL) {
        guard let card = CatalogueCard(json: json), AppWebPolicy.origin(card.url) == AppWebPolicy.origin(page),
              card.url.path.range(of: #"^/watch/[A-Za-z0-9_-]{1,160}/[^/]+/?\z"#,options: .regularExpression) != nil,
              card.url.fragment == nil else { return nil }
        self.card = card
        year = Self.field(json["year"],pattern: #"^[0-9]{4}\z"#)
        format = Self.field(json["format"],pattern: #"^[A-Za-z0-9][A-Za-z0-9 _-]{0,23}\z"#)
        episodeCount = Self.field(json["episode_count"],pattern: #"^[0-9]{1,5}\z"#)
        score = Self.field(json["score"],pattern: #"^(?:[0-9]{1,2}|100)\z"#)
    }

    private static func field(_ value: JSONValue?, pattern: String) -> String {
        let text = value?.string ?? ""
        guard text.count <= 24, text.range(of: pattern,options: .regularExpression) != nil else { return "" }
        return text
    }
}
struct CatalogueHero: Equatable {
    var title: String
    var logoURL: URL?
    var backdropURL: URL?
    var description: String
    var meta: String
    var url: URL?
    init(title: String, logoURL: URL? = nil, backdropURL: URL? = nil, description: String = "", meta: String = "", url: URL? = nil) {
        self.title = title; self.logoURL = logoURL; self.backdropURL = backdropURL; self.description = description; self.meta = meta; self.url = url
    }
    init(json: JSONObject) {
        self.init(title: String((json["title"]?.string ?? "").prefix(500)), logoURL: ProviderPolicy.imageURL(json["logo"]?.string),
                  backdropURL: ProviderPolicy.imageURL(json["backdrop"]?.string), description: String((json["description"]?.string ?? "").prefix(6000)),
                  meta: String((json["meta"]?.string ?? "").prefix(500)), url: json["url"]?.string.flatMap(URL.init(string:)).flatMap { AppWebPolicy.isProvider($0) ? $0 : nil })
    }
}
struct SeasonChoice: Identifiable, Equatable {
    let id: String
    let label: String
    let title: String
    let year: String
    let posterURL: URL?
    let url: URL
    let selected: Bool

    init?(json: JSONObject, page: URL) {
        guard let raw = json["url"]?.string, raw.count <= 2048, let target = URL(string: raw),
              let normalized = ProviderPolicy.documentURL(target,native: true),
              AppWebPolicy.origin(normalized) == AppWebPolicy.origin(page),
              let currentID = Self.watchID(page), let targetID = Self.watchID(normalized),
              var parts = URLComponents(url: normalized,resolvingAgainstBaseURL: false),
              let label = json["label"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
        let episode = (parts.queryItems ?? []).filter { $0.name == "ep" }
        guard episode.isEmpty || (episode.count == 1 && AppWebPolicy.identity(animeID: "1",episode: episode[0].value ?? "")) else { return nil }
        parts.queryItems = episode.isEmpty ? nil : episode
        parts.fragment = nil
        guard let url = parts.url else { return nil }
        self.id = targetID
        self.label = String(label.prefix(80))
        self.title = String((json["title"]?.string ?? "").prefix(240))
        let year = json["year"]?.string ?? ""
        self.year = year.range(of: #"^[0-9]{4}$"#,options: .regularExpression) == nil ? "" : year
        self.posterURL = ProviderPolicy.imageURL(json["poster"]?.string)
        self.url = url
        self.selected = currentID == targetID
    }

    private static func watchID(_ url: URL) -> String? {
        let path = url.path.split(separator: "/")
        guard (2...3).contains(path.count), path[0] == "watch",
              path[1].range(of: #"^[A-Za-z0-9_-]{1,160}$"#,options: .regularExpression) != nil else { return nil }
        return String(path[1])
    }
}
struct EpisodeChoice: Identifiable, Equatable {
    var id: String
    var label: String
    var number: String
    var title: String
    var selected: Bool
    var url: URL?
    init(id: String,label: String,number: String = "",title: String = "",selected: Bool = false,url: URL? = nil) {
        self.id = id; self.label = label; self.number = number; self.title = title; self.selected = selected; self.url = url
    }
}
extension EpisodeChoice {
    static func next(in choices: [EpisodeChoice], after metadata: AnimeMetadata) -> EpisodeChoice? {
        guard let current = Double(metadata.episode), metadata.watchURL.path.hasPrefix("/watch/") else { return nil }
        let ordered = choices.compactMap { choice -> (EpisodeChoice, Double)? in
            guard AppWebPolicy.identity(animeID: metadata.animeID,episode: choice.number),
                  let number = Double(choice.number), number > current else { return nil }
            return (choice,number)
        }.sorted { $0.1 < $1.1 }
        guard let (choice,number) = ordered.first else { return nil }
        let firstNumber = ordered.prefix { $0.1 == number }
        for (candidate,_) in firstNumber {
            guard let url = candidate.url, AppWebPolicy.isProvider(url),
                  AppWebPolicy.origin(url) == AppWebPolicy.origin(metadata.watchURL), url.path == metadata.watchURL.path,
                  var parts = URLComponents(url: url,resolvingAgainstBaseURL: false),
                  let query = parts.queryItems?.filter({ $0.name == "ep" }), query.count == 1,
                  query[0].value.flatMap(Double.init) == number else { continue }
            parts.queryItems = [URLQueryItem(name: "ep",value: choice.number)]
            parts.fragment = nil
            var target = candidate; target.url = parts.url
            return target
        }
        return nil
    }
}

struct PlaybackSegment: Equatable {
    enum Kind: String {
        case intro, outro
        var title: String { self == .intro ? "Skip opening" : "Skip ending" }
    }
    let kind: Kind
    let start: TimeInterval
    let end: TimeInterval
    static func parse(_ entries: [JSONValue]) -> [PlaybackSegment] {
        entries.prefix(16).compactMap { entry in
            guard let item = entry.object, let kind = item["kind"]?.string.flatMap(Kind.init(rawValue:)),
                  let start = item["start"]?.double, let end = item["end"]?.double,
                  start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
            return PlaybackSegment(kind: kind,start: start,end: end)
        }
    }
    func contains(_ position: TimeInterval, duration: TimeInterval) -> Bool {
        duration.isFinite && start < duration && end <= duration + 1 && position >= start && position < end && position < duration
    }
}

struct WebsiteSourceChoice: Identifiable, Equatable {
    var id: String
    var kind: String
    var label: String
    var selected: Bool
}
enum NativeSourceStatus: String {
    case loadingPlayer = "Loading the website player…"
    case waitingForStream = "Waiting for the player to select a stream…"
    case checkingFormat = "Checking the selected stream format…"
    case ready = "Native stream ready"
    case gestureRequired = "The website player needs a direct Play tap."
}
struct MediaSource: Identifiable, Equatable {
    var id: String { url.absoluteString }
    var url: URL
    var headers: [String: String]
    var confirmed: Bool
    var mimeType: String
    var choiceID: String
    var selectionRevision: UInt64
    var configured: Bool
    var segments: [PlaybackSegment]
    init(url: URL, headers: [String: String] = [:], confirmed: Bool = false, mimeType: String = "",choiceID: String = "",selectionRevision: UInt64 = 0,configured: Bool = false,segments: [PlaybackSegment] = []) {
        self.url = url; self.headers = headers; self.confirmed = confirmed; self.mimeType = mimeType; self.choiceID = choiceID; self.selectionRevision = selectionRevision; self.configured = configured; self.segments = segments
    }
    var nativePlayable: Bool {
        ["m3u8", "mp4", "m4v"].contains(url.pathExtension.lowercased()) ||
        ["application/vnd.apple.mpegurl", "application/x-mpegurl", "video/mp4"].contains(mimeType.lowercased().split(separator: ";").first.map(String.init) ?? "")
    }
}
struct SubtitleSource: Identifiable, Equatable {
    var id: String { url.absoluteString }
    var url: URL
    var label: String
    var language: String
    var headers: [String: String]
    var choiceID: String
    var selectionRevision: UInt64
    var configured: Bool
    init(url: URL, label: String = "Subtitles", language: String = "und", headers: [String: String] = [:],choiceID: String = "",selectionRevision: UInt64 = 0,configured: Bool = false) {
        self.url = url; self.label = label; self.language = language; self.headers = headers; self.choiceID = choiceID; self.selectionRevision = selectionRevision; self.configured = configured
    }
}
struct SyncLibraryCard: Identifiable, Equatable {
    var id: String
    var title: String
    var posterURL: URL?
    var url: URL
    var episode: String
    var progress: Double
    var continuing: Bool
    var hasNew: Bool
    var nextURL: URL?
    var nextEpisode: String
    var checkpointEpisode: String
    init?(json: JSONObject) {
        guard let key = json["key"]?.string, let value = json["url"]?.string,
              let url = URL(string: value), AppWebPolicy.isProvider(url), !key.isEmpty else { return nil }
        id = key; title = String((json["title"]?.string ?? "Untitled").prefix(500)); self.url = url
        posterURL = ProviderPolicy.imageURL(json["poster"]?.string); episode = Self.episodeText(json["episode"])
        let progressValue = json["progress"]?.double ?? 0; progress = progressValue.isFinite ? min(1, max(0, progressValue)) : 0
        continuing = json["continuing"]?.bool ?? false; hasNew = json["has_new"]?.bool ?? false
        nextURL = json["next_url"]?.string.flatMap(URL.init(string:)).flatMap { AppWebPolicy.isProvider($0) ? $0 : nil }
        nextEpisode = Self.episodeText(json["next_episode"])
        checkpointEpisode = Self.episodeText(json["checkpoint_episode"])
    }
    private static func episodeText(_ value: JSONValue?) -> String {
        String((value?.string ?? value?.integer.map { String($0) } ?? "").prefix(80))
    }
    func nextAfter(_ checkpoint: HistoryEntry) -> String? {
        guard checkpoint.completed,
              let tracked = EpisodeProgressKey(site: "miruro",animeID: checkpoint.animeID,episode: checkpointEpisode),
              let displayed = EpisodeProgressKey(site: "miruro",animeID: checkpoint.animeID,episode: episode),
              let next = EpisodeProgressKey(site: "miruro",animeID: checkpoint.animeID,episode: nextEpisode),
              tracked.episode == checkpoint.episode, displayed == next,
              let nextNumber = Double(next.episode), let trackedNumber = Double(tracked.episode),
              nextNumber > trackedNumber else { return nil }
        return next.episode
    }
}
struct BrowserHandoffSnapshot {
    let metadata: AnimeMetadata
    let position: TimeInterval
    let duration: TimeInterval
    let ended: Bool
    let paused: Bool
}
enum BrowserPlaybackEvent {
    case started(AnimeMetadata, explicit: Bool)
    case progress(AnimeMetadata, position: TimeInterval, duration: TimeInterval, ended: Bool, playing: Bool)
    case stopped(AnimeMetadata, position: TimeInterval, duration: TimeInterval, ended: Bool)
    case resumeFailed
    case routeChanged(URL)
}
enum ProviderFailure: LocalizedError {
    case invalidURL, staleNavigation, missingPlayer, timeout, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Choose a valid Miruro page."
        case .staleNavigation: return "The episode changed. Try the action again."
        case .missingPlayer: return "The website player could not pause. Try the action after playback starts."
        case .timeout: return "The website player did not respond. Try again."
        case .unavailable: return "The page could not load. Check the connection and try again."
        }
    }
}

enum ProviderPolicy {
    static func isLegacyNativeHistoryURL(_ url: URL) -> Bool {
        guard let origin = AppWebPolicy.origin(url) else { return false }
        // Classification sends a trusted history identity to modern catalogue
        // search; it does not authorize navigation to these older hosts.
        return ["https://www.miruro.cx", "https://miruro.to", "https://www.miruro.to",
                "https://miruro.tv", "https://www.miruro.tv"].contains(origin)
    }
    static func documentURL(_ url: URL,native: Bool) -> URL? {
        guard AppWebPolicy.isProvider(url) else { return nil }
        guard native, url.host?.lowercased() == "www.miruro.cx" else { return url }
        // This verified host serves the legacy player layout. Its public watch
        // routes also exist on the modern apex site used by native extraction.
        guard var parts = URLComponents(url: url,resolvingAgainstBaseURL: false) else { return nil }
        parts.host = "miruro.cx"
        guard let result = parts.url, AppWebPolicy.isProvider(result) else { return nil }
        return result
    }
    static func imageURL(_ value: String?) -> URL? {
        value.flatMap(URL.init(string:)).flatMap { AppWebPolicy.isMediaOrigin($0) ? $0 : nil }
    }
    static func nativeMedia(_ url: URL, mimeType: String = "") -> Bool {
        AppWebPolicy.isMediaOrigin(url) && MediaSource(url: url, mimeType: mimeType).nativePlayable
    }
    static func ordinaryHeaders(_ values: JSONObject?, frameURL: URL?) -> [String: String] {
        var result: [String: String] = [:]
        if let frameURL, safeHeaderURL(frameURL), let origin = AppWebPolicy.origin(frameURL) {
            result["Origin"] = origin; result["Referer"] = frameURL.absoluteString
        }
        for name in ["Referer", "Origin", "User-Agent"] {
            guard let value = values?[name]?.string, value.count <= 2000, validHeaderValue(value) else { continue }
            if name != "User-Agent" {
                guard let url = URL(string: value), safeHeaderURL(url) else { continue }
            }
            result[name] = value
        }
        return result
    }
    static func validHeaderValue(_ value: String) -> Bool {
        // CRLF is a single Swift Character. Inspect scalars so paired delimiters,
        // lone delimiters and other control bytes cannot escape the header guard.
        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private static func safeHeaderURL(_ url: URL) -> Bool {
        guard AppWebPolicy.isMediaOrigin(url), let host = url.host?.lowercased() else { return false }
        return host != AppWebPolicy.home.host && host != AppWebPolicy.tailnet.host
    }
    static func jsonLiteral(_ value: String) -> String {
        // JSON string encoding, never interpolation of website text as JavaScript code.
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
