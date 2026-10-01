import Foundation

struct SubscriptionUserInfo: Codable, Sendable, Equatable {
    var upload: UInt64?
    var download: UInt64?
    var total: UInt64?
    var expire: Date?

    static func parse(_ header: String?) -> Self? {
        guard let header, header.utf8.count <= 4_096 else { return nil }
        var numbers: [String: UInt64] = [:]
        for item in header.split(separator: ";") {
            let pair = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard pair.count == 2, ["upload", "download", "total", "expire"].contains(pair[0]),
                  !pair[1].isEmpty, pair[1].utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = UInt64(pair[1]), numbers[pair[0]] == nil else { continue }
            numbers[pair[0]] = value
        }
        guard !numbers.isEmpty else { return nil }
        let expiration = numbers["expire"].flatMap { $0 > 0 && $0 <= 253_402_300_799 ? Date(timeIntervalSince1970: Double($0)) : nil }
        return Self(upload: numbers["upload"], download: numbers["download"], total: numbers["total"], expire: expiration)
    }
}

struct SubscriptionDownload: Sendable {
    var data: Data
    var userInfo: SubscriptionUserInfo?
}

protocol SubscriptionFetching: Sendable {
    func fetch(_ url: URL) async throws -> SubscriptionDownload
}

enum SubscriptionError: LocalizedError {
    case invalidURL, responseTooLarge, invalidResponse, httpStatus(Int), unsafeRedirect, transport, staleRequest
    var errorDescription: String? {
        switch self {
        case .invalidURL: "订阅地址必须是有效 HTTPS URL，不能含登录用户名、密码或片段。"
        case .responseTooLarge: "订阅内容超过 1 MiB 限制。"
        case .invalidResponse: "服务器没有返回有效的订阅响应。"
        case .httpStatus(let status): "订阅服务器返回 HTTP \(status)。"
        case .unsafeRedirect: "订阅重定向不是 HTTPS，或重定向次数过多，已拒绝。"
        case .transport: "订阅下载失败；请检查网络或服务器。地址和凭据已隐藏。"
        case .staleRequest: "订阅在下载期间已变更；旧响应未保存。"
        }
    }
}

struct SubscriptionService: SubscriptionFetching {
    static let maximumBytes = AppConstants.maximumMessageBytes

    static func validatedURL(_ text: String) throws -> URL {
        guard text.utf8.count <= 8_192,
              let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true,
              let url = components.url else { throw SubscriptionError.invalidURL }
        return url
    }

    func fetch(_ url: URL) async throws -> SubscriptionDownload {
        let checked = try Self.validatedURL(url.absoluteString)
        let operation = SubscriptionDownloadOperation(url: checked)
        return try await withTaskCancellationHandler {
            try await operation.execute()
        } onCancel: { operation.cancel() }
    }
}

/// A bounded streaming download. URLSession.data(for:) would buffer an unlimited response first.
private final class SubscriptionDownloadOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var continuation: CheckedContinuation<SubscriptionDownload, any Error>?
    private var terminal: Result<SubscriptionDownload, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var userInfo: SubscriptionUserInfo?
    private var redirectCount = 0

    init(url: URL) { self.url = url }

    func execute() async throws -> SubscriptionDownload {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let terminal { lock.unlock(); continuation.resume(with: terminal); return }
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 45
            configuration.httpShouldSetCookies = false
            configuration.httpMaximumConnectionsPerHost = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            request.setValue("ClairRoute/1", forHTTPHeaderField: "User-Agent")
            request.setValue("application/yaml, text/yaml, text/plain, application/octet-stream", forHTTPHeaderField: "Accept")
            self.session = session
            let task = session.dataTask(with: request)
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<SubscriptionDownload, any Error>) {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return }
        terminal = result
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        task = nil
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failure(SubscriptionError.invalidResponse)); return
        }
        guard (200...299).contains(response.statusCode) else {
            completionHandler(.cancel); finish(.failure(SubscriptionError.httpStatus(response.statusCode))); return
        }
        guard response.expectedContentLength <= SubscriptionService.maximumBytes else {
            completionHandler(.cancel); finish(.failure(SubscriptionError.responseTooLarge)); return
        }
        lock.lock()
        userInfo = SubscriptionUserInfo.parse(response.value(forHTTPHeaderField: "subscription-userinfo"))
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return }
        guard data.count <= SubscriptionService.maximumBytes - buffer.count else {
            lock.unlock(); finish(.failure(SubscriptionError.responseTooLarge)); return
        }
        buffer.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if error != nil { finish(.failure(SubscriptionError.transport)); return }
        lock.lock()
        let result = SubscriptionDownload(data: buffer, userInfo: userInfo)
        lock.unlock()
        if result.data.isEmpty { finish(.failure(SubscriptionError.invalidResponse)) }
        else { finish(.success(result)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.lock()
        redirectCount += 1
        let withinLimit = redirectCount <= 5
        lock.unlock()
        guard withinLimit, let url = request.url, (try? SubscriptionService.validatedURL(url.absoluteString)) != nil else {
            completionHandler(nil); finish(.failure(SubscriptionError.unsafeRedirect)); return
        }
        var safe = request
        safe.setValue(nil, forHTTPHeaderField: "Authorization")
        safe.setValue(nil, forHTTPHeaderField: "Cookie")
        safe.setValue(nil, forHTTPHeaderField: "Referer")
        safe.httpShouldHandleCookies = false
        completionHandler(safe)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Use system TLS validation. Never search the user's Keychain for subscription HTTP credentials.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}
