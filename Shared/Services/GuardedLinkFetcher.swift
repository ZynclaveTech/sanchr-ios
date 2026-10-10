import Foundation
import SanchrShared

/// Fetches a URL that came out of someone else's message, without letting
/// that message steer the device somewhere it should not go.
///
/// A link preview is a request made on a sender's instruction.
/// `LinkPreviewHostPolicy` can judge the link as written, but not what its
/// name resolves to or where the page redirects — and the system's
/// link-metadata provider, which did the fetching before this, offers no way
/// to ask. So the fetch is done here, and each hop is checked three ways:
///
/// - the URL itself, by `LinkPreviewHostPolicy.isFetchable`;
/// - every address its host resolves to, before connecting — every one,
///   since a single private record among public ones is the rebinding trick;
/// - the address the connection actually reached, afterwards. A response
///   from a private peer is thrown away unread.
///
/// It also refuses outright when the device is set to use a proxy. Through
/// one, the name is resolved by the proxy and the peer is the proxy, so the
/// checks above would be looking at the wrong thing — and going around it
/// would show the user's own address to whatever site a message linked to.
///
/// Nothing is kept between requests: no cookies, no cache, no credentials.
final class GuardedLinkFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = GuardedLinkFetcher()

    /// For an attachment's own bytes rather than a preview card: the same
    /// checks, with long enough to bring down a large file.
    static let attachments = GuardedLinkFetcher(resourceTimeout: 600)

    struct Response: Sendable {
        let data: Data
        let mimeType: String?
        /// Where the bytes came from, after any redirects.
        let finalURL: URL
    }

    enum Refusal: Error, Equatable {
        case notFetchable
        case proxyConfigured
        case privateAddress
        case tooManyRedirects
        case tooLarge
        case badStatus
    }

    static let maxRedirects = 5

    private let resolve: @Sendable (String) -> [String]
    private let proxyConfigured: @Sendable () -> Bool
    private let peerIsPublic: @Sendable (URLSessionTaskMetrics) -> Bool
    private let protocolClasses: [AnyClass]?
    private let resourceTimeout: TimeInterval

    private let lock = NSLock()
    private var states: [Int: TaskState] = [:]
    private lazy var session: URLSession = makeSession()

    private struct TaskState {
        var data = Data()
        var response: URLResponse?
        var redirects = 0
        var refusal: Refusal?
        var truncated = false
        var peerVerified = false
        let maxBytes: Int
        let truncate: Bool
        let continuation: CheckedContinuation<Response, Error>
    }

    init(
        resolve: @escaping @Sendable (String) -> [String] = GuardedLinkFetcher.systemResolve,
        proxyConfigured: @escaping @Sendable () -> Bool = GuardedLinkFetcher.systemProxyConfigured,
        peerIsPublic: @escaping @Sendable (URLSessionTaskMetrics) -> Bool = GuardedLinkFetcher.everyPeerIsPublic,
        protocolClasses: [AnyClass]? = nil,
        resourceTimeout: TimeInterval = 20
    ) {
        self.resourceTimeout = resourceTimeout
        self.resolve = resolve
        self.proxyConfigured = proxyConfigured
        self.peerIsPublic = peerIsPublic
        self.protocolClasses = protocolClasses
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// - Parameters:
    ///   - maxBytes: the most that will be read.
    ///   - truncate: at the limit, whether to stop and return what was read
    ///     (a page, whose tags are near the top) or to refuse (an image, of
    ///     which part is no use).
    func fetch(_ url: URL, accept: String, maxBytes: Int, truncate: Bool) async throws -> Response {
        let (resolve, proxyConfigured) = (self.resolve, self.proxyConfigured)
        // Resolving blocks, so not on the caller's executor.
        let refusal = await Task.detached(priority: .utility) {
            Self.refusal(for: url, resolve: resolve, proxyConfigured: proxyConfigured)
        }.value
        if let refusal { throw refusal }

        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (iPhone) SanchrLinkPreview/1.0", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false

        let task = session.dataTask(with: request)
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            states[task.taskIdentifier] = TaskState(maxBytes: maxBytes, truncate: truncate, continuation: continuation)
            lock.unlock()
            task.resume()
        }
    }

    /// Why `url` must not be connected to, or nil when it may be.
    static func refusal(
        for url: URL,
        resolve: (String) -> [String],
        proxyConfigured: () -> Bool
    ) -> Refusal? {
        guard LinkPreviewHostPolicy.isFetchable(url), let host = url.host else { return .notFetchable }
        if proxyConfigured() { return .proxyConfigured }
        let addresses = resolve(host)
        // No answer is not a public answer.
        guard !addresses.isEmpty, addresses.allSatisfy(LinkPreviewHostPolicy.isPublicAddress) else {
            return .privateAddress
        }
        return nil
    }

    // MARK: - URLSession delegate

    private func update(_ task: URLSessionTask, _ change: (inout TaskState) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard var state = states[task.taskIdentifier] else { return }
        change(&state)
        states[task.taskIdentifier] = state
    }

    private func stop(_ task: URLSessionTask, because refusal: Refusal) {
        update(task) { $0.refusal = $0.refusal ?? refusal }
        task.cancel()
    }

    /// Every redirect is a new URL nobody has looked at yet.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        var hops = 0
        update(task) {
            $0.redirects += 1
            hops = $0.redirects
        }
        // Never from an encrypted connection down to a plain one: a link that
        // was `https` when it was judged must not end as a request anyone on
        // the path can read or answer.
        let downgrade = response.url?.scheme?.lowercased() == "https" && request.url?.scheme?.lowercased() != "https"
        let refusal: Refusal? =
            hops > Self.maxRedirects
            ? .tooManyRedirects
            : request.url.flatMap { Self.refusal(for: $0, resolve: resolve, proxyConfigured: proxyConfigured) }
                ?? (request.url == nil || downgrade ? .notFetchable : nil)
        if let refusal {
            completionHandler(nil)
            stop(task, because: refusal)
        } else {
            completionHandler(request)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        var limit = 0
        var truncate = false
        update(dataTask) {
            $0.response = response
            limit = $0.maxBytes
            truncate = $0.truncate
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            completionHandler(.cancel)
            stop(dataTask, because: .badStatus)
        } else if !truncate, response.expectedContentLength > Int64(limit) {
            completionHandler(.cancel)
            stop(dataTask, because: .tooLarge)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var over = false
        var truncate = false
        update(dataTask) {
            guard !$0.truncated else { return }
            $0.data.append(data)
            if $0.data.count >= $0.maxBytes {
                over = $0.data.count > $0.maxBytes || $0.truncate
                truncate = $0.truncate
                if $0.truncate {
                    $0.data = $0.data.prefix($0.maxBytes)
                    $0.truncated = true
                }
            }
        }
        guard over else { return }
        if truncate { dataTask.cancel() } else { stop(dataTask, because: .tooLarge) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let isPublic = peerIsPublic(metrics)
        update(task) {
            $0.peerVerified = isPublic
            if !isPublic { $0.refusal = $0.refusal ?? .privateAddress }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let state = states.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let state else { return }

        if let refusal = state.refusal {
            state.continuation.resume(throwing: refusal)
        } else if let error, !state.truncated {
            state.continuation.resume(throwing: error)
        } else if !state.peerVerified {
            // Nothing vouched for where this came from, so it is not used.
            state.continuation.resume(throwing: Refusal.privateAddress)
        } else if let response = state.response, let finalURL = response.url {
            state.continuation.resume(
                returning: Response(data: state.data, mimeType: response.mimeType, finalURL: finalURL))
        } else {
            state.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }

    // MARK: - The real checks

    /// Every address `host` resolves to, as literals. Empty when it does not
    /// resolve.
    static let systemResolve: @Sendable (String) -> [String] = { host in
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0, let first = head else { return [] }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
            // An address that cannot be printed cannot be judged; the empty
            // string fails every check.
            addresses.append(status == 0 ? String(cString: buffer) : "")
            cursor = entry.pointee.ai_next
        }
        return addresses
    }

    /// Whether the device sends web traffic through a proxy. If the settings
    /// cannot be read the answer is yes — unknown is not "none".
    static let systemProxyConfigured: @Sendable () -> Bool = {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return true
        }
        return proxyIsConfigured(in: settings)
    }

    static func proxyIsConfigured(in settings: [String: Any]) -> Bool {
        ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable"].contains {
            (settings[$0] as? NSNumber)?.boolValue == true
        }
    }

    /// Every connection the task made went to a public address, and it made
    /// at least one.
    static let everyPeerIsPublic: @Sendable (URLSessionTaskMetrics) -> Bool = { metrics in
        let loads = metrics.transactionMetrics.filter { $0.resourceFetchType == .networkLoad }
        return !loads.isEmpty && loads.allSatisfy { $0.remoteAddress.map(LinkPreviewHostPolicy.isPublicAddress) ?? false }
    }
}
