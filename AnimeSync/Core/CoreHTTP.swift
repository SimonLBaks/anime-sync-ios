import Foundation

enum CoreError: LocalizedError, Equatable {
    case invalidTVAddress, invalidResponse, responseTooLarge, unauthorized, canceled, invalidMetadata
    case http(Int), conflict(String), message(String)
    var errorDescription: String? {
        switch self {
        case .invalidTVAddress: return "Enter the TV’s private home-network IPv4 address"
        case .invalidResponse: return "The server did not return a valid response"
        case .responseTooLarge: return "The server response was too large"
        case .unauthorized: return "Sign in or pair again"
        case .canceled: return "Canceled"
        case .invalidMetadata: return "Choose a valid Miruro episode first"
        case .http(let code): return "Server request failed (\(code))"
        case .conflict(let message), .message(let message): return message
        }
    }
}
struct HTTPReply { let status: Int; let body: Data }
protocol HTTPTransport {
    func request(_ request: URLRequest, maxBytes: Int) async throws -> HTTPReply
}

/// Each operation is single-attempt, rejects redirects and stops reading at its body limit.
final class CoreHTTPTransport: HTTPTransport {
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        self.configuration.httpCookieStorage = nil
        self.configuration.urlCredentialStorage = nil
        self.configuration.httpShouldSetCookies = false
        self.configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.configuration.urlCache = nil
    }
    static func isSafeHeaderValue(_ value: String) -> Bool {
        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    func request(_ request: URLRequest, maxBytes: Int) async throws -> HTTPReply {
        guard (request.allHTTPHeaderFields ?? [:]).allSatisfy({ Self.isSafeHeaderValue($0.key) && Self.isSafeHeaderValue($0.value) }) else { throw CoreError.invalidResponse }
        let operation = BoundedHTTPOperation(configuration: configuration, maxBytes: maxBytes)
        return try await operation.perform(request)
    }
}

private final class BoundedHTTPOperation: NSObject, URLSessionDataDelegate {
    private let configuration: URLSessionConfiguration
    private let maxBytes: Int
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<HTTPReply, Error>?
    private var canceled = false
    private var response: HTTPURLResponse?
    private var body = Data()
    init(configuration: URLSessionConfiguration, maxBytes: Int) { self.configuration = configuration; self.maxBytes = maxBytes }
    func perform(_ request: URLRequest) async throws -> HTTPReply {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if canceled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                let task = session.dataTask(with: request); self.task = task
                lock.unlock(); task.resume()
            }
        }, onCancel: { self.cancel() })
    }
    private func cancel() { lock.lock(); canceled = true; lock.unlock(); finish(.failure(CancellationError())) }
    private func finish(_ result: Result<HTTPReply, Error>) {
        lock.lock()
        let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil; self.task = nil
        lock.unlock()
        session?.invalidateAndCancel(); continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); finish(.failure(CoreError.invalidResponse)); return }
        guard response.expectedContentLength <= Int64(maxBytes) else { completionHandler(.cancel); finish(.failure(CoreError.responseTooLarge)); return }
        self.response = http; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count <= maxBytes - data.count else { finish(.failure(CoreError.responseTooLarge)); return }
        body.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error { finish(.failure(error)) }
        else if let response = response { finish(.success(HTTPReply(status: response.statusCode, body: body))) }
        else { finish(.failure(CoreError.invalidResponse)) }
    }
}

/// Serialize the entire logical operation, not merely its individual URL requests.
@MainActor final class AsyncOperationQueue {
    private var tail: Task<Void, Never>?
    func run<T>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let predecessor = tail
        let work = Task { @MainActor in
            if let predecessor = predecessor { await predecessor.value }
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task { @MainActor in _ = try? await work.value }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }
}
