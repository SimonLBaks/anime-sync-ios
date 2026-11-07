import Foundation

/// Immutable deployment policy. Public builds contain generic defaults; a
/// private profile may be added to the unsigned app locally before signing.
struct AppConfiguration: Equatable {
    enum ValidationError: Error, Equatable { case invalidField(String) }
    let homeURL: URL
    let tailnetURL: URL
    let connectOverrides: [String:String]
    let defaultTVHost: String
    var dashboardOrigins: Set<String> { [homeURL.absoluteString,tailnetURL.absoluteString] }
    var dashboardHosts: Set<String> { Set([homeURL.host,tailnetURL.host].compactMap { $0 }) }

    static let generic = AppConfiguration(homeURL: URL(string: "https://anime-sync.example")!,
                                          tailnetURL: URL(string: "https://anime-sync-tailnet.example:8443")!,
                                          connectOverrides: [:],defaultTVHost: "")
    static let current: AppConfiguration = {
        let data = Bundle.main.url(forResource: "Deployment",withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        return load(data)
    }()

    private init(homeURL: URL,tailnetURL: URL,connectOverrides: [String:String],defaultTVHost: String) {
        self.homeURL = homeURL; self.tailnetURL = tailnetURL
        self.connectOverrides = connectOverrides; self.defaultTVHost = defaultTVHost
    }
    static func load(_ data: Data?) -> AppConfiguration {
        guard let data, let value = try? decode(data) else { return .generic }
        return value
    }
    static func decode(_ data: Data) throws -> AppConfiguration {
        struct Document: Decodable {
            let homeURL: String
            let tailnetURL: String
            let connectOverrides: [String:String]?
            let defaultTVHost: String?
        }
        guard data.count <= 65536 else { throw ValidationError.invalidField("document") }
        let allowedKeys: Set<String> = ["homeURL","tailnetURL","connectOverrides","defaultTVHost"]
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any],
              Set(object.keys).isSubset(of: allowedKeys), object["homeURL"] is String, object["tailnetURL"] is String,
              !object.keys.contains("connectOverrides") || object["connectOverrides"] is [String:String],
              !object.keys.contains("defaultTVHost") || object["defaultTVHost"] is String else { throw ValidationError.invalidField("document") }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self,from: data) }
        catch { throw ValidationError.invalidField("document") }
        guard let home = httpsOrigin(document.homeURL) else { throw ValidationError.invalidField("homeURL") }
        guard let tailnet = httpsOrigin(document.tailnetURL), home != tailnet else { throw ValidationError.invalidField("tailnetURL") }
        let hosts = Set([home.host!,tailnet.host!])
        var overrides: [String:String] = [:]
        for (source,target) in document.connectOverrides ?? [:] {
            let canonical = source.lowercased()
            guard hostname(source), hosts.contains(canonical), overrides[canonical] == nil,
                  let checked = privateIPv4(target) else { throw ValidationError.invalidField("connectOverrides") }
            overrides[canonical] = checked
        }
        let tv = document.defaultTVHost ?? ""
        guard tv.isEmpty || privateIPv4(tv) != nil else { throw ValidationError.invalidField("defaultTVHost") }
        return AppConfiguration(homeURL: home,tailnetURL: tailnet,connectOverrides: overrides,defaultTVHost: tv)
    }
    func connectHost(for hostname: String) -> String { connectOverrides[hostname.lowercased()] ?? hostname }
    private static func httpsOrigin(_ raw: String) -> URL? {
        guard !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let parts = URLComponents(string: raw), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", let host = parts.host?.lowercased(), hostname(host),
              parts.port == nil || parts.port == 443 || parts.port == 8443 else { return nil }
        return URL(string: "https://" + host + (parts.port == 8443 ? ":8443" : ""))
    }
    private static func hostname(_ raw: String) -> Bool {
        guard raw.count <= 253, !raw.isEmpty else { return false }
        return raw.split(separator: ".",omittingEmptySubsequences: false).allSatisfy { label in
            label.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\z",options: .regularExpression) != nil
        }
    }
    private static func privateIPv4(_ raw: String) -> String? {
        let parts = raw.split(separator: ".",omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var values: [Int] = []
        for part in parts {
            guard part.range(of: "^(0|[1-9][0-9]{0,2})\\z",options: .regularExpression) != nil,
                  let value = Int(part), value <= 255 else { return nil }
            values.append(value)
        }
        guard values[0] == 10 || values[0] == 192 && values[1] == 168 || values[0] == 172 && (16...31).contains(values[1]) else { return nil }
        return raw
    }
}
