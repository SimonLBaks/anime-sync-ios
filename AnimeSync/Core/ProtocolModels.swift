import Foundation
import Combine
import CoreFoundation

/// Integer protocol generations/revisions remain integers throughout encoding.
enum JSONValue: Codable, Equatable {
    case null, bool(Bool), integer(Int64), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let x = try? box.decode(Bool.self) { self = .bool(x) }
        else if let x = try? box.decode(Int64.self) { self = .integer(x) }
        else if let x = try? box.decode(Double.self) { self = .number(x) }
        else if let x = try? box.decode(String.self) { self = .string(x) }
        else if let x = try? box.decode([JSONValue].self) { self = .array(x) }
        else { self = .object(try box.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .null: try box.encodeNil()
        case .bool(let x): try box.encode(x)
        case .integer(let x): try box.encode(x)
        case .number(let x): try box.encode(x)
        case .string(let x): try box.encode(x)
        case .array(let x): try box.encode(x)
        case .object(let x): try box.encode(x)
        }
    }
    /// Foundation's typed JSONDecoder can coerce 1.0 into Int64. Protocol fences
    /// require the wire's integer type, so response objects use this parser.
    static func parseObject(_ data: Data) throws -> JSONObject {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CoreError.invalidResponse }
        func convert(_ value: Any) throws -> JSONValue {
            if value is NSNull { return .null }
            if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
                let kind = String(cString: number.objCType)
                if kind == "d" || kind == "f" { return .number(number.doubleValue) }
                if let integer = Int64(number.stringValue) { return .integer(integer) }
                return .number(number.doubleValue)
            }
            if let string = value as? String { return .string(string) }
            if let array = value as? [Any] { return .array(try array.map(convert)) }
            if let object = value as? [String: Any] { return .object(try object.mapValues(convert)) }
            throw CoreError.invalidResponse
        }
        return try object.mapValues(convert)
    }
    var string: String? { if case .string(let x) = self { return x }; return nil }
    var bool: Bool? { if case .bool(let x) = self { return x }; return nil }
    var integer: Int64? { if case .integer(let x) = self { return x }; return nil }
    var double: Double? { switch self { case .integer(let x): return Double(x); case .number(let x): return x; default: return nil } }
    var object: [String: JSONValue]? { if case .object(let x) = self { return x }; return nil }
    var array: [JSONValue]? { if case .array(let x) = self { return x }; return nil }
}
typealias JSONObject = [String: JSONValue]

struct AnimeMetadata: Codable, Equatable {
    var site: String = "miruro"
    var animeID: String
    var episode: String
    var title: String
    var posterURL: URL?
    var watchURL: URL
    var slug: String = ""
    init(site: String = "miruro", animeID: String, episode: String, title: String, posterURL: URL? = nil, watchURL: URL, slug: String = "") {
        self.site = site; self.animeID = animeID; self.episode = episode; self.title = title
        self.posterURL = posterURL; self.watchURL = watchURL; self.slug = slug
    }
    enum CodingKeys: String, CodingKey { case site, animeID = "anime_id", episode, title, posterURL = "poster_url", watchURL = "watch_url", slug }
    var isValid: Bool { site == "miruro" && AppWebPolicy.identity(animeID: animeID, episode: episode) && AppWebPolicy.isProvider(watchURL) }
    var json: JSONObject {
        ["site": .string(site), "anime_id": .string(animeID), "episode": .string(episode), "title": .string(title),
         "poster_url": .string(posterURL?.absoluteString ?? ""), "watch_url": .string(watchURL.absoluteString), "slug": .string(slug)]
    }
    init?(json: JSONObject) {
        guard let id = json["anime_id"]?.string, let episode = json["episode"]?.string,
              let urlString = json["watch_url"]?.string, let url = URL(string: urlString), AppWebPolicy.isProvider(url),
              AppWebPolicy.identity(animeID: id, episode: episode) else { return nil }
        let poster = json["poster_url"]?.string.flatMap(URL.init(string:)).flatMap { AppWebPolicy.isMediaOrigin($0) ? $0 : nil }
        self.init(animeID: id, episode: episode, title: json["title"]?.string ?? "", posterURL: poster, watchURL: url, slug: json["slug"]?.string ?? "")
    }
}

struct ResumeSnapshot: Equatable {
    let position: TimeInterval
    let generation: Int64
    let sessionID: String?
}

@MainActor final class PlaybackLease: ObservableObject, Identifiable {
    let id: String
    let generation: Int64
    let accountEpoch: UInt64
    @Published private(set) var isValid: Bool = true
    private(set) var sequence: Int64 = 0
    init(id: String, generation: Int64, accountEpoch: UInt64 = 0) { self.id = id; self.generation = generation; self.accountEpoch = accountEpoch }
    func invalidate() { isValid = false }
    func nextSequence() -> Int64? { guard isValid, sequence < Int64.max else { invalidate(); return nil }; sequence += 1; return sequence }
}

struct PlaybackStart {
    let allowed: Bool
    let lease: PlaybackLease?
    let resumePosition: TimeInterval?
    let message: String?
}
struct HandoffSnapshot {
    let saved: Bool
    let position: TimeInterval?
    let generation: Int64?
}

struct TVControlSnapshot: Equatable {
    let supported: Bool
    let available: Bool
    let mine: Bool
    let ownerName: String
    let revision: Int64
    init(supported: Bool, available: Bool, mine: Bool, ownerName: String, revision: Int64) {
        let valid = supported && revision >= 0 && !(available && mine)
        self.supported = valid; self.available = valid && available; self.mine = valid && mine
        self.ownerName = String(ownerName.filter { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(80))
        self.revision = valid ? revision : -1
    }
    static let unsupported = TVControlSnapshot(supported: false, available: false, mine: false, ownerName: "", revision: -1)
}
struct TVControlLease: Equatable {
    let connection: UInt64
    let revision: Int64
}
struct TVState: Equatable {
    var host = AppConfiguration.current.defaultTVHost
    var paired = false
    var online = false
    var message = "Connect TV"
    var title = "Anime Sync TV"
    var episode = ""
    var watchURL: URL?
    var posterURL: URL?
    var playing = false
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var connection: UInt64 = 0
    var handoffGeneration: Int64?
    var handoffSaved = false
    var capabilities: Set<String> = []
    var control = TVControlSnapshot.unsupported
    var canLoad: Bool { paired && online && capabilities.contains("load") && control.supported }
    var controlDescription: String {
        guard online else { return message }
        guard control.supported else { return "Update Anime Sync TV to use controls" }
        if control.mine { return "You control this TV" }
        if control.available { return "View only · TV control is available" }
        return "View only · \(control.ownerName.isEmpty ? "Another device" : control.ownerName) controls this TV"
    }
}
