import Foundation

struct HistoryEntry: Equatable, Identifiable {
    var site: String
    var animeID: String
    var episode: String
    var title: String
    var posterURL: URL?
    var watchURL: URL?
    var currentTime: TimeInterval
    var duration: TimeInterval
    var completed: Bool
    var updatedAt: String
    var id: String { "\(animeID):\(episode)" }
    var resumePosition: TimeInterval { AppWebPolicy.resume(position: currentTime, duration: duration, completed: completed) }
    var watchedFraction: Double? {
        if completed { return 1 }
        guard currentTime.isFinite, currentTime >= 0, duration.isFinite, duration > 0 else { return nil }
        return min(currentTime / duration, 1)
    }
    var resolverURL: URL {
        var url = URLComponents(string: "https://miruro.cx/search")!
        url.queryItems = [URLQueryItem(name: "q", value: title)]
        url.fragment = "anime-sync-id=\(animeID)&anime-sync-ep=\(episode)"
        return url.url!
    }
    var metadata: AnimeMetadata { AnimeMetadata(animeID: animeID, episode: episode, title: title, posterURL: posterURL, watchURL: resolverURL) }
    init(site: String = "miruro", animeID: String, episode: String, title: String, posterURL: URL? = nil, watchURL: URL? = nil, currentTime: TimeInterval, duration: TimeInterval, completed: Bool, updatedAt: String) {
        self.site = site; self.animeID = animeID; self.episode = episode; self.title = title; self.posterURL = posterURL; self.watchURL = watchURL
        self.currentTime = currentTime; self.duration = duration; self.completed = completed; self.updatedAt = updatedAt
    }
    init?(json: JSONObject) {
        guard let id = json["anime_id"]?.string, let ep = json["episode"]?.string else { return nil }
        self.init(site: json["site"]?.string ?? "", animeID: id, episode: ep, title: json["title"]?.string ?? "",
                  posterURL: json["poster_url"]?.string.flatMap(URL.init(string:)).flatMap { AppWebPolicy.isMediaOrigin($0) ? $0 : nil },
                  watchURL: json["watch_url"]?.string.flatMap(URL.init(string:)), currentTime: json["current_time"]?.double ?? .nan,
                  duration: json["duration"]?.double ?? .nan, completed: json["completed"]?.bool ?? false, updatedAt: json["updated_at"]?.string ?? "")
    }
}
struct HomeHistorySnapshot: Equatable {
    let continuing: [HistoryEntry]
    let recent: [HistoryEntry]
    static let empty = HomeHistorySnapshot(continuing: [], recent: [])
}
struct EpisodeProgressKey: Hashable {
    let site: String
    let animeID: String
    let episode: String
    init?(site: String,animeID: String,episode: String) {
        guard site == "miruro", AppWebPolicy.identity(animeID: animeID,episode: episode),
              let id = Int64(animeID), let number = Decimal(string: episode,locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        self.site = site; self.animeID = String(id); self.episode = NSDecimalNumber(decimal: number).stringValue
    }
}
enum WatchedEpisodeIndex {
    static func select(_ entries: [HistoryEntry]) -> Set<EpisodeProgressKey> {
        Set(entries.filter(\.completed).compactMap { EpisodeProgressKey(site: $0.site,animeID: $0.animeID,episode: $0.episode) })
    }
}
enum HomeHistory {
    static func episodeFractions(_ entries: [HistoryEntry]) -> [EpisodeProgressKey: Double] {
        var fractions: [EpisodeProgressKey: Double] = [:]
        // The progress endpoint returns newest first. Canonical legacy duplicates
        // must use the latest checkpoint, including an explicit restart at zero.
        for row in entries.reversed() {
            guard let key = EpisodeProgressKey(site: row.site,animeID: row.animeID,episode: row.episode) else { continue }
            fractions[key] = row.watchedFraction
        }
        return fractions
    }
    static func select(_ source: [HistoryEntry]) -> HomeHistorySnapshot {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var rows: [(HistoryEntry, Date)] = []
        for var row in source {
            guard let key = EpisodeProgressKey(site: row.site,animeID: row.animeID,episode: row.episode),
                  let date = formatter.date(from: row.updatedAt) ?? plain.date(from: row.updatedAt) else { continue }
            row.animeID = key.animeID; row.episode = key.episode
            row.title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            rows.append((row, date))
        }
        rows.sort { left, right in
            if left.1 != right.1 { return left.1 > right.1 }
            if left.0.animeID != right.0.animeID { return left.0.animeID < right.0.animeID }
            return left.0.episode < right.0.episode
        }
        var seen = Set<String>(), continuing: [HistoryEntry] = [], recent: [HistoryEntry] = []
        for (row, _) in rows {
            guard seen.insert(row.animeID).inserted else { continue }
            // Deduplicate before eligibility: a bad/latest row must not resurrect an old episode.
            guard !row.title.isEmpty, row.currentTime.isFinite, row.currentTime >= 0, row.duration.isFinite, row.duration >= 0 else { continue }
            if recent.count < 10 { recent.append(row) }
            if row.resumePosition > 0 && continuing.count < 24 { continuing.append(row) }
        }
        return HomeHistorySnapshot(continuing: continuing, recent: recent)
    }
}
