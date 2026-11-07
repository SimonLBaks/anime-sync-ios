import Foundation
import Network

/// AVPlayer receives an app-local URL. Its network requests never need private asset options,
/// browser cookies or backend credentials; the bridge adds only ordinary provider headers.
@MainActor final class MediaBridge {
    let url: URL
    private let server: MediaBridgeServer

    init(source: MediaSource) async throws {
        let server = try MediaBridgeServer(source: source)
        self.server = server
        self.url = try await server.start()
    }

    func stop() { server.stop() }
    deinit { server.stop() }
}

enum MediaBridgeFailure: LocalizedError {
    case unsupported, manifestTooLarge, unavailable
    var errorDescription: String? {
        switch self {
        case .unsupported: return "This source needs the website player."
        case .manifestTooLarge: return "This playlist needs the website player."
        case .unavailable: return "The video source could not load. Try the website player."
        }
    }
}

enum MediaBridgePolicy {
    static let maximumManifestBytes = 2 * 1024 * 1024
    static func allows(_ url: URL) -> Bool {
        guard AppWebPolicy.isMediaOrigin(url), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.fragment == nil, let host = parts.host?.lowercased(), !host.isEmpty,
              host != AppWebPolicy.home.host, host != AppWebPolicy.tailnet.host,
              host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"),
              !host.contains(":"), !host.contains("%") else { return false }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        if host.allSatisfy({ $0.isNumber || $0 == "." }), octets.count != 4 { return false }
        if octets.count == 4, octets.allSatisfy({ Int($0) != nil }) {
            let values = octets.compactMap { Int($0) }
            guard values.allSatisfy({ (0...255).contains($0) }), zip(octets,values).allSatisfy({ String($0.1) == $0.0 }) else { return false }
            if [0, 10, 127].contains(values[0]) || values[0] >= 224 ||
                values[0] == 169 && values[1] == 254 || values[0] == 172 && (16...31).contains(values[1]) ||
                values[0] == 192 && values[1] == 168 || values[0] == 100 && (64...127).contains(values[1]) { return false }
        } else {
            // Avoid legacy numeric IPv4 forms such as 0x7f000001/0177.0.0.1,
            // which a resolver can interpret as loopback despite their spelling.
            guard octets.count >= 2, octets.last?.contains(where: { $0.isLetter }) == true,
                  host.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+\\z", options: .regularExpression) != nil else { return false }
        }
        return true
    }
    static func headers(_ headers: [String: String]) -> [String: String] {
        // Case normalization also makes duplicate spellings unable to introduce Cookie/Auth.
        var ordinary: JSONObject = [:]
        for (name, value) in headers {
            if let key = ["Referer", "Origin", "User-Agent"].first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                ordinary[key] = .string(value)
            }
        }
        return ProviderPolicy.ordinaryHeaders(ordinary, frameURL: nil)
    }
    static func range(_ value: String) -> Bool {
        value.count <= 80 && value.range(of: "^bytes=([0-9]{1,20}-[0-9]{0,20}|-[0-9]{1,20})\\z", options: .regularExpression) != nil
    }
    static func manifest(_ data: Data, base: URL, map: (URL, Bool) throws -> URL) throws -> Data {
        guard data.count <= maximumManifestBytes else { throw MediaBridgeFailure.manifestTooLarge }
        guard let text = String(data: data, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
            throw MediaBridgeFailure.unsupported
        }
        // Content steering and variable substitution can introduce resources outside the registry.
        // Leave those sources in the website player until their complete protocols are implemented.
        guard !text.contains("#EXT-X-CONTENT-STEERING:"), !text.contains("#EXT-X-DEFINE:"), !text.contains("{$") else {
            throw MediaBridgeFailure.unsupported
        }
        let expression = try NSRegularExpression(pattern: "(?<![A-Za-z0-9_-])URI=\"([^\"]*)\"")
        var variant = false
        var lines: [String] = []
        func replace(_ raw: String, playlist: Bool) throws -> String {
            guard raw.count <= 16_384, let resolved = URL(string: raw, relativeTo: base)?.absoluteURL,
                  allows(resolved) else { throw MediaBridgeFailure.unsupported }
            return try map(resolved, playlist || resolved.pathExtension.lowercased() == "m3u8").absoluteString
        }
        for sourceLine in text.components(separatedBy: .newlines) {
            let line = sourceLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") {
                    if let keyFormat = line.range(of: "KEYFORMAT=\"") {
                        let rest = line[keyFormat.upperBound...]
                        guard rest.hasPrefix("identity\"") else { throw MediaBridgeFailure.unsupported }
                    }
                }
                let playlist = line.hasPrefix("#EXT-X-MEDIA:") || line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") || line.hasPrefix("#EXT-X-RENDITION-REPORT:")
                var rewritten = line
                for match in expression.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                    guard let valueRange = Range(match.range(at: 1), in: line), let fullRange = Range(match.range, in: rewritten) else { throw MediaBridgeFailure.unsupported }
                    rewritten.replaceSubrange(fullRange, with: "URI=\"\(try replace(String(line[valueRange]), playlist: playlist))\"")
                }
                lines.append(rewritten)
                if line.hasPrefix("#EXT-X-STREAM-INF:") { variant = true }
            } else if line.isEmpty { lines.append("") }
            else {
                lines.append(try replace(line, playlist: variant)); variant = false
            }
        }
        let output = Data(lines.joined(separator: "\n").utf8)
        guard output.count <= maximumManifestBytes * 4 else { throw MediaBridgeFailure.manifestTooLarge }
        return output
    }
}

private struct BridgeResource {
    let url: URL
    var playlist: Bool
}

/// All mutable server/connection state lives on this one queue. URLSession delegate callbacks
/// run on that queue too, so stopping and applying network backpressure cannot race a callback.
private final class MediaBridgeServer {
    let queue = DispatchQueue(label: "xyz.loibaks.animesync.media")
    let headers: [String: String]
    private let source: MediaSource
    private let capability = UUID().uuidString.lowercased()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, Error>?
    private var startupTimeout: DispatchWorkItem?
    private var stopped = false
    private var port: UInt16?
    private var resources: [String: BridgeResource] = [:]
    private var resourceIDs: [String: String] = [:]
    private var exchanges: [UUID: MediaExchange] = [:]

    init(source: MediaSource) throws {
        guard MediaBridgePolicy.allows(source.url), source.nativePlayable else { throw MediaBridgeFailure.unsupported }
        self.source = source; self.headers = MediaBridgePolicy.headers(source.headers)
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { pending in
            queue.async {
                guard !self.stopped else { pending.resume(throwing: MediaBridgeFailure.unavailable); return }
                self.continuation = pending
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters, on: .any)
                    self.listener = listener
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        guard let self, !self.stopped else { return }
                        switch state {
                        case .ready:
                            guard let port = listener?.port?.rawValue else { self.failStart(); return }
                            self.port = port
                            do {
                                let mime = self.source.mimeType.lowercased()
                                let url = try self.register(self.source.url, playlist: self.source.url.pathExtension.lowercased() == "m3u8" || mime.contains("mpegurl"))
                                self.startupTimeout?.cancel(); self.startupTimeout = nil
                                let result = self.continuation; self.continuation = nil; result?.resume(returning: url)
                            } catch { self.failStart() }
                        case .failed: self.failStart()
                        default: break
                        }
                    }
                    let timeout = DispatchWorkItem { [weak self] in self?.failStart() }
                    self.startupTimeout = timeout; self.queue.asyncAfter(deadline: .now() + 8, execute: timeout)
                    listener.start(queue: self.queue)
                } catch { self.failStart() }
            }
        }
    }
    func stop() { queue.async { self.finish() } }
    private func failStart() {
        let result = continuation; continuation = nil
        result?.resume(throwing: MediaBridgeFailure.unavailable); finish()
    }
    private func finish() {
        guard !stopped else { return }; stopped = true
        let pending = continuation; continuation = nil; pending?.resume(throwing: MediaBridgeFailure.unavailable)
        startupTimeout?.cancel(); startupTimeout = nil; listener?.cancel(); listener = nil
        let active = Array(exchanges.values); exchanges.removeAll(); active.forEach { $0.cancel() }
        resources.removeAll(); resourceIDs.removeAll()
    }
    private func accept(_ connection: NWConnection) {
        guard !stopped, exchanges.count < 16 else { connection.cancel(); return }
        let id = UUID()
        let exchange = MediaExchange(server: self, connection: connection) { [weak self] in self?.exchanges.removeValue(forKey: id) }
        exchanges[id] = exchange; exchange.start()
    }
    func register(_ upstream: URL, playlist: Bool) throws -> URL {
        guard !stopped, let port, MediaBridgePolicy.allows(upstream) else { throw MediaBridgeFailure.unsupported }
        let key = upstream.absoluteString
        let id: String
        if let existing = resourceIDs[key] {
            id = existing
            if playlist, var resource = resources[id] { resource.playlist = true; resources[id] = resource }
        } else {
            guard resources.count < 8192 else { throw MediaBridgeFailure.manifestTooLarge }
            id = UUID().uuidString.lowercased(); resourceIDs[key] = id; resources[id] = BridgeResource(url: upstream, playlist: playlist)
        }
        let ext = playlist ? "m3u8" : (["mp4", "m4v", "ts", "m4s", "aac", "vtt"].contains(upstream.pathExtension.lowercased()) ? upstream.pathExtension.lowercased() : "bin")
        return URL(string: "http://127.0.0.1:\(port)/\(capability)/\(id)/asset.\(ext)")!
    }
    func resource(_ rawPath: String) -> BridgeResource? {
        guard let path = URLComponents(string: rawPath), path.scheme == nil, path.host == nil, path.fragment == nil else { return nil }
        let pieces = path.path.split(separator: "/")
        guard pieces.count == 3, pieces[0] == Substring(capability), let resource = resources[String(pieces[1])], pieces[2].hasPrefix("asset.") else { return nil }
        guard let query = path.queryItems, !query.isEmpty else { return path.percentEncodedQuery == nil ? resource : nil }
        guard resource.playlist, query.count <= 3, Set(query.map(\.name)).count == query.count,
              query.allSatisfy({ item in
                  guard let value = item.value, value.count <= 20 else { return false }
                  switch item.name {
                  case "_HLS_msn", "_HLS_part": return value.range(of: "^[0-9]+\\z", options: .regularExpression) != nil
                  case "_HLS_skip": return ["YES", "v2"].contains(value)
                  default: return false
                  }
              }), var upstream = URLComponents(url: resource.url, resolvingAgainstBaseURL: false) else { return nil }
        let names = Set(query.map(\.name)); upstream.queryItems = (upstream.queryItems ?? []).filter { !names.contains($0.name) } + query
        guard let url = upstream.url else { return nil }
        return BridgeResource(url: url, playlist: true)
    }
}

private final class MediaExchange: NSObject, URLSessionDataDelegate {
    private weak var server: MediaBridgeServer?
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let finished: () -> Void
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var requestBuffer = Data()
    private var resource: BridgeResource?
    private var headOnly = false
    private var closed = false
    private var sentHeader = false
    private var playlist = false
    private var manifest = Data()
    private var response: HTTPURLResponse?
    private var redirects = 0
    private var pending: [Data] = []
    private var queuedBytes = 0
    private var sending = false
    private var suspended = false
    private var complete = false
    private var finishing = false
    private var chunked = false
    private var headerTimeout: DispatchWorkItem?

    init(server: MediaBridgeServer, connection: NWConnection, finished: @escaping () -> Void) {
        self.server = server; self.connection = connection; self.queue = server.queue; self.finished = finished
    }
    func start() {
        let timeout = DispatchWorkItem { [weak self] in self?.cancel() }
        headerTimeout = timeout; queue.asyncAfter(deadline: .now() + 8, execute: timeout)
        connection.stateUpdateHandler = { [weak self] state in
            switch state { case .ready: self?.readRequest(); case .failed, .cancelled: self?.cancel(); default: break }
        }
        connection.start(queue: queue)
    }
    func cancel() {
        guard !closed else { return }; closed = true
        headerTimeout?.cancel(); headerTimeout = nil
        task?.cancel(); task = nil; session?.invalidateAndCancel(); session = nil
        pending.removeAll(); connection.cancel(); finished()
    }
    private func readRequest() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if let data { self.requestBuffer.append(data) }
            guard error == nil, self.requestBuffer.count <= 16_384 else { self.cancel(); return }
            guard let delimiter = self.requestBuffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done { self.cancel() } else { self.readRequest() }; return
            }
            guard let text = String(data: self.requestBuffer[..<delimiter.lowerBound], encoding: .utf8) else { self.reply(400); return }
            self.requestBuffer.removeAll()
            let lines = text.components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ")
            guard first.count == 3, ["GET", "HEAD"].contains(String(first[0])), first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { self.reply(405); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { self.reply(400); return }
                let key = String(line[..<colon]).lowercased()
                guard headers[key] == nil else { self.reply(400); return }
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["transfer-encoding"] == nil, headers["content-length"] == nil || headers["content-length"] == "0",
                  let server = self.server, let resource = server.resource(String(first[1])) else { self.reply(404); return }
            self.headerTimeout?.cancel(); self.headerTimeout = nil
            self.headOnly = first[0] == "HEAD"; self.resource = resource; self.playlist = resource.playlist
            var request = URLRequest(url: resource.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 35)
            // GET lets a manifest HEAD report its rewritten length; binary HEAD stops at headers.
            request.httpMethod = "GET"; request.httpShouldHandleCookies = false
            server.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if !resource.playlist, let range = headers["range"] {
                guard MediaBridgePolicy.range(range) else { self.reply(416); return }
                request.setValue(range, forHTTPHeaderField: "Range")
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
            configuration.httpShouldSetCookies = false; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 35; configuration.timeoutIntervalForResource = 3600
            let delegates = OperationQueue(); delegates.maxConcurrentOperationCount = 1; delegates.underlyingQueue = self.queue
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegates)
            self.session = session; let task = session.dataTask(with: request); self.task = task; task.resume()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard !closed, redirects < 5, let url = request.url, MediaBridgePolicy.allows(url) else { completionHandler(nil); reply(502); return }
        redirects += 1
        var clean = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 35)
        clean.httpMethod = "GET"; clean.httpShouldHandleCookies = false
        server?.headers.forEach { clean.setValue($0.value, forHTTPHeaderField: $0.key) }
        clean.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") { clean.setValue(range, forHTTPHeaderField: "Range") }
        completionHandler(clean)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !closed, let response = response as? HTTPURLResponse, let url = response.url, MediaBridgePolicy.allows(url) else { completionHandler(.cancel); reply(502); return }
        guard (200...299).contains(response.statusCode) else {
            completionHandler(.cancel)
            if response.statusCode == 416 { reply(416, extra: safeResponseHeaders(response, names: ["Content-Range"])) }
            else { reply(response.statusCode == 404 ? 404 : 502) }; return
        }
        self.response = response
        let mime = response.mimeType?.lowercased() ?? ""
        playlist = playlist || mime.contains("mpegurl") || url.pathExtension.lowercased() == "m3u8"
        if playlist {
            guard response.statusCode == 200, response.expectedContentLength <= Int64(MediaBridgePolicy.maximumManifestBytes) else { completionHandler(.cancel); reply(502); return }
            completionHandler(.allow); return
        }
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased() ?? "identity"
        let length = encoding == "identity" && response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        var headers = safeResponseHeaders(response, names: ["Content-Type", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified"])
        if let length { headers["Content-Length"] = String(length) }
        else if !headOnly { headers["Transfer-Encoding"] = "chunked"; chunked = true }
        if headers["Content-Type"] == nil { headers["Content-Type"] = "application/octet-stream" }
        sendHeader(status: response.statusCode, headers: headers)
        if headOnly { complete = true; completionHandler(.cancel); drain(); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !closed else { return }
        if playlist {
            guard manifest.count + data.count <= MediaBridgePolicy.maximumManifestBytes else { reply(502); return }
            manifest.append(data)
        } else {
            guard queuedBytes + data.count <= 2 * 1024 * 1024 else { cancel(); return }
            if chunked {
                var part = Data(String(data.count, radix: 16).utf8); part.append(Data("\r\n".utf8)); part.append(data); part.append(Data("\r\n".utf8)); enqueue(part)
            } else { enqueue(data) }
            if queuedBytes >= 262_144, !suspended { dataTask.suspend(); suspended = true }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !closed, !complete else { return }
        if error != nil { if sentHeader { cancel() } else { reply(502) }; return }
        if playlist {
            guard let server, let response, let base = response.url else { reply(502); return }
            do {
                let output = try MediaBridgePolicy.manifest(manifest, base: base) { try server.register($0, playlist: $1) }
                manifest.removeAll()
                sendHeader(status: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl", "Content-Length": String(output.count)])
                if !headOnly { enqueue(output) }
            } catch { reply(502); return }
        } else if chunked { enqueue(Data("0\r\n\r\n".utf8)) }
        complete = true; drain()
    }
    private func safeResponseHeaders(_ response: HTTPURLResponse, names: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for name in names {
            if let value = response.value(forHTTPHeaderField: name), value.count <= 4000, ProviderPolicy.validHeaderValue(value) { result[name] = value }
        }
        return result
    }
    private func reply(_ status: Int, extra: [String: String] = [:]) {
        guard !closed else { return }
        guard !sentHeader else { cancel(); return }
        task?.cancel(); task = nil
        var headers = extra; headers["Content-Length"] = "0"
        sendHeader(status: status, headers: headers); complete = true; drain()
    }
    private func sendHeader(status: Int, headers: [String: String]) {
        guard !sentHeader else { return }; sentHeader = true
        let reason: String
        switch status { case 200: reason = "OK"; case 206: reason = "Partial Content"; case 400: reason = "Bad Request"; case 404: reason = "Not Found"; case 405: reason = "Method Not Allowed"; case 416: reason = "Range Not Satisfiable"; default: reason = "Bad Gateway" }
        var header = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        for name in headers.keys.sorted() { header += "\(name): \(headers[name]!)\r\n" }
        header += "\r\n"; enqueue(Data(header.utf8))
    }
    private func enqueue(_ data: Data) {
        guard !closed, !data.isEmpty else { return }; pending.append(data); queuedBytes += data.count; drain()
    }
    private func drain() {
        guard !closed, !sending else { return }
        guard !pending.isEmpty else {
            if complete, !finishing {
                finishing = true
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.cancel() })
            }
            return
        }
        sending = true; let data = pending.removeFirst()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            self.sending = false; self.queuedBytes -= data.count
            guard error == nil else { self.cancel(); return }
            if self.suspended, self.queuedBytes < 65_536 { self.suspended = false; self.task?.resume() }
            self.drain()
        })
    }
}

/// Safari's native HLS loader need not call fetch/XHR. A DOM video URL can be a
/// PHP/extensionless endpoint, so identify its format before offering AVPlayer.
enum MediaSourceProbe {
    static func mimeType(url: URL,headers: [String:String]) async -> String? {
        guard MediaBridgePolicy.allows(url) else { return nil }
        return await MediaProbeOperation(url: url,headers: MediaBridgePolicy.headers(headers)).run()
    }
    static func canonicalMIME(_ mime: String) -> String? {
        let value = mime.lowercased().split(separator: ";",maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if ["application/vnd.apple.mpegurl","application/x-mpegurl","application/mpegurl","audio/mpegurl","audio/x-mpegurl"].contains(value) { return "application/vnd.apple.mpegurl" }
        if ["video/mp4","video/x-m4v"].contains(value) { return "video/mp4" }
        return nil
    }
    static func sniff(_ data: Data) -> String? {
        let prefix = Data(data.prefix(2048))
        if String(decoding: prefix,as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") { return "application/vnd.apple.mpegurl" }
        if prefix.count >= 12, String(data: prefix[4..<8],encoding: .ascii) == "ftyp" { return "video/mp4" }
        return nil
    }
}

private final class MediaProbeOperation: NSObject, URLSessionDataDelegate {
    private let url: URL
    private let headers: [String:String]
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?,Never>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false
    private var redirects = 0
    private var bytes = Data()
    init(url: URL,headers: [String:String]) { self.url = url; self.headers = headers }
    func run() async -> String? {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard !finished else { lock.unlock(); continuation.resume(returning: nil); return }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
                configuration.httpShouldSetCookies = false; configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 15
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration,delegate: self,delegateQueue: queue)
                self.session = session
                let task = session.dataTask(with: request(url)); self.task = task
                lock.unlock(); task.resume()
            }
        },onCancel: { self.finish(nil) })
    }
    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url,cachePolicy: .reloadIgnoringLocalCacheData,timeoutInterval: 8)
        request.httpMethod = "GET"; request.httpShouldHandleCookies = false
        headers.forEach { request.setValue($0.value,forHTTPHeaderField: $0.key) }
        request.setValue("bytes=0-2047",forHTTPHeaderField: "Range"); request.setValue("identity",forHTTPHeaderField: "Accept-Encoding")
        return request
    }
    private func finish(_ mime: String?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }; finished = true
        let pending = continuation; continuation = nil
        let active = session; session = nil; task = nil
        lock.unlock()
        active?.invalidateAndCancel(); pending?.resume(returning: mime)
    }
    func urlSession(_ session: URLSession,task: URLSessionTask,willPerformHTTPRedirection response: HTTPURLResponse,newRequest request: URLRequest,completionHandler: @escaping (URLRequest?) -> Void) {
        guard redirects < 3, let target = request.url, MediaBridgePolicy.allows(target) else { completionHandler(nil); finish(nil); return }
        redirects += 1; completionHandler(self.request(target))
    }
    func urlSession(_ session: URLSession,task: URLSessionTask,didReceive challenge: URLAuthenticationChallenge,completionHandler: @escaping (URLSession.AuthChallengeDisposition,URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge,nil)
    }
    func urlSession(_ session: URLSession,dataTask: URLSessionDataTask,didReceive response: URLResponse,completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, let url = response.url, MediaBridgePolicy.allows(url),
              [200,206].contains(response.statusCode) else { completionHandler(.cancel); finish(nil); return }
        if let mime = MediaSourceProbe.canonicalMIME(response.mimeType ?? "") { completionHandler(.cancel); finish(mime); return }
        if ["text/html","application/json"].contains(response.mimeType?.lowercased() ?? "") { completionHandler(.cancel); finish(nil); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession,dataTask: URLSessionDataTask,didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if bytes.count + data.count > 65_536 { lock.unlock(); finish(nil); return }
        bytes.append(data); let sample = bytes; lock.unlock()
        if let mime = MediaSourceProbe.sniff(sample) { finish(mime) }
        else if sample.count >= 2048 { finish(nil) }
    }
    func urlSession(_ session: URLSession,task: URLSessionTask,didCompleteWithError error: Error?) {
        lock.lock(); let sample = bytes; lock.unlock()
        finish(error == nil ? MediaSourceProbe.sniff(sample) : nil)
    }
}
