import XCTest
import SanchrShared
@testable import Sanchr

/// A link preview is fetched because a message said so. These are the checks
/// on where that fetch is allowed to go — the URL, what its name resolves to,
/// every redirect, and the peer actually reached.
final class GuardedLinkFetcherTests: XCTestCase {

    // MARK: - Before connecting

    private func refusal(
        _ url: String,
        resolvesTo addresses: [String] = ["93.184.216.34"],
        proxy: Bool = false
    ) -> GuardedLinkFetcher.Refusal? {
        GuardedLinkFetcher.refusal(for: URL(string: url)!, resolve: { _ in addresses }, proxyConfigured: { proxy })
    }

    func testAPublicLinkThatResolvesPubliclyMayBeFetched() {
        XCTAssertNil(refusal("https://example.com/a"))
        XCTAssertNil(refusal("https://example.com/a", resolvesTo: ["93.184.216.34", "2606:4700:4700::1111"]))
    }

    func testALinkThePolicyRefusesIsNeverResolved() {
        var resolved = false
        let result = GuardedLinkFetcher.refusal(
            for: URL(string: "http://192.168.1.1/")!,
            resolve: { _ in resolved = true; return ["93.184.216.34"] },
            proxyConfigured: { false })
        XCTAssertEqual(result, .notFetchable)
        XCTAssertFalse(resolved)
    }

    /// The part the text of a link cannot answer.
    func testAPublicNameThatResolvesPrivatelyIsRefused() {
        XCTAssertEqual(refusal("https://innocent.example/a", resolvesTo: ["192.168.1.1"]), .privateAddress)
        XCTAssertEqual(refusal("https://innocent.example/a", resolvesTo: ["::1"]), .privateAddress)
    }

    /// One private record among public ones is the rebinding trick.
    func testOnePrivateRecordRefusesTheWholeName() {
        XCTAssertEqual(refusal("https://rebind.example/a", resolvesTo: ["93.184.216.34", "127.0.0.1"]), .privateAddress)
    }

    func testANameThatDoesNotResolveOrResolvesToNonsenseIsRefused() {
        XCTAssertEqual(refusal("https://nowhere.example/a", resolvesTo: []), .privateAddress)
        XCTAssertEqual(refusal("https://odd.example/a", resolvesTo: [""]), .privateAddress)
        XCTAssertEqual(refusal("https://odd.example/a", resolvesTo: ["not-an-address"]), .privateAddress)
    }

    func testNothingIsFetchedAroundAConfiguredProxy() {
        XCTAssertEqual(refusal("https://example.com/a", proxy: true), .proxyConfigured)
    }

    func testProxySettingsAreReadForEveryKindOfProxy() {
        XCTAssertFalse(GuardedLinkFetcher.proxyIsConfigured(in: [:]))
        XCTAssertFalse(GuardedLinkFetcher.proxyIsConfigured(in: ["HTTPEnable": 0, "__SCOPED__": ["utun2": [:]]]))
        for key in ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable"] {
            XCTAssertTrue(GuardedLinkFetcher.proxyIsConfigured(in: [key: 1]), key)
        }
    }

    // MARK: - On the wire

    private func fetcher(
        resolvesTo addresses: @escaping @Sendable (String) -> [String] = { _ in ["93.184.216.34"] },
        peerIsPublic: Bool = true
    ) -> GuardedLinkFetcher {
        GuardedLinkFetcher(
            resolve: addresses,
            proxyConfigured: { false },
            peerIsPublic: { _ in peerIsPublic },
            protocolClasses: [StubProtocol.self])
    }

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
    }

    private func html(_ body: String) -> StubProtocol.Answer {
        .init(status: 200, headers: ["Content-Type": "text/html"], body: Data(body.utf8))
    }

    private func redirect(to location: String) -> StubProtocol.Answer {
        .init(status: 302, headers: ["Location": location], body: Data())
    }

    func testAPageIsReturnedWithItsTypeAndFinalURL() async throws {
        StubProtocol.answers["https://example.com/a"] = html("<title>Hi</title>")

        let response = try await fetcher().fetch(
            URL(string: "https://example.com/a")!, accept: "text/html", maxBytes: 1024, truncate: true)

        XCTAssertEqual(String(decoding: response.data, as: UTF8.self), "<title>Hi</title>")
        XCTAssertEqual(response.mimeType, "text/html")
        XCTAssertEqual(response.finalURL.absoluteString, "https://example.com/a")
    }

    func testARedirectToAPublicPageIsFollowed() async throws {
        StubProtocol.answers["https://example.com/a"] = redirect(to: "https://example.com/b")
        StubProtocol.answers["https://example.com/b"] = html("b")

        let response = try await fetcher().fetch(
            URL(string: "https://example.com/a")!, accept: "text/html", maxBytes: 1024, truncate: true)

        XCTAssertEqual(response.finalURL.absoluteString, "https://example.com/b")
    }

    func testARedirectToAPrivateAddressIsRefusedAndNeverRequested() async {
        for target in ["http://127.0.0.1/admin", "http://192.168.1.1/", "http://router.local/", "http://[::1]/"] {
            StubProtocol.reset()
            StubProtocol.answers["https://example.com/a"] = redirect(to: target)
            StubProtocol.answers[target] = html("secret")

            do {
                _ = try await fetcher().fetch(
                    URL(string: "https://example.com/a")!, accept: "text/html", maxBytes: 1024, truncate: true)
                XCTFail("followed a redirect to \(target)")
            } catch {
                XCTAssertEqual(error as? GuardedLinkFetcher.Refusal, .notFetchable, target)
            }
            XCTAssertEqual(StubProtocol.requested, ["https://example.com/a"], target)
        }
    }

    func testARedirectToANameThatResolvesPrivatelyIsRefused() async {
        StubProtocol.answers["https://example.com/a"] = redirect(to: "https://internal.example/x")
        StubProtocol.answers["https://internal.example/x"] = html("secret")
        let fetcher = fetcher(resolvesTo: { host in host == "internal.example" ? ["10.0.0.5"] : ["93.184.216.34"] })

        do {
            _ = try await fetcher.fetch(
                URL(string: "https://example.com/a")!, accept: "text/html", maxBytes: 1024, truncate: true)
            XCTFail("followed a redirect to a privately-resolving name")
        } catch {
            XCTAssertEqual(error as? GuardedLinkFetcher.Refusal, .privateAddress)
        }
        XCTAssertEqual(StubProtocol.requested, ["https://example.com/a"])
    }

    func testARedirectMayNotDowngradeFromHTTPSToHTTP() async {
        StubProtocol.answers["https://example.com/a"] = redirect(to: "http://example.com/a")
        StubProtocol.answers["http://example.com/a"] = html("plain")

        do {
            _ = try await fetcher().fetch(
                URL(string: "https://example.com/a")!, accept: "text/html", maxBytes: 1024, truncate: true)
            XCTFail("followed a redirect down to http")
        } catch {
            XCTAssertEqual(error as? GuardedLinkFetcher.Refusal, .notFetchable)
        }
        XCTAssertEqual(StubProtocol.requested, ["https://example.com/a"])
    }

    func testOnlyAPublicHTTPSLinkIsFetchedAsAnAttachment() {
        XCTAssertTrue(MediaDownloadManager.isFetchableSenderLink(URL(string: "https://cdn.example.com/a.jpg")!))
        for link in [
            "http://cdn.example.com/a.jpg", "https://192.168.1.1/a.jpg", "https://localhost/a.jpg",
            "https://example.com@10.0.0.1/a.jpg", "file:///var/mobile/x", "ftp://example.com/a",
        ] {
            XCTAssertFalse(MediaDownloadManager.isFetchableSenderLink(URL(string: link)!), link)
        }
    }

    func testARedirectLoopEnds() async {
        StubProtocol.answers["https://example.com/a"] = redirect(to: "https://example.com/a")

        do {
            _ = try await fetcher().fetch(
                URL(string: "https://example.com/a")!, accept: "text/html", maxBytes: 1024, truncate: true)
            XCTFail("a redirect loop returned")
        } catch {
            XCTAssertEqual(error as? GuardedLinkFetcher.Refusal, .tooManyRedirects)
        }
    }

    /// The name was checked before connecting; this is the check after, on
    /// the address the connection actually reached.
    func testAResponseFromAPeerThatIsNotPublicIsDiscarded() async {
        StubProtocol.answers["https://example.com/a"] = html("secret")

        do {
            _ = try await fetcher(peerIsPublic: false).fetch(
                URL(string: "https://example.com/a")!, accept: "text/html", maxBytes: 1024, truncate: true)
            XCTFail("used a response from an unverified peer")
        } catch {
            XCTAssertEqual(error as? GuardedLinkFetcher.Refusal, .privateAddress)
        }
    }

    func testAnErrorStatusIsNotAPreview() async {
        StubProtocol.answers["https://example.com/a"] = .init(status: 404, headers: ["Content-Type": "text/html"], body: Data("no".utf8))

        do {
            _ = try await fetcher().fetch(
                URL(string: "https://example.com/a")!, accept: "text/html", maxBytes: 1024, truncate: true)
            XCTFail("a 404 returned")
        } catch {
            XCTAssertEqual(error as? GuardedLinkFetcher.Refusal, .badStatus)
        }
    }

    func testALongPageIsCutAtTheLimitRatherThanRefused() async throws {
        StubProtocol.answers["https://example.com/a"] = html(String(repeating: "x", count: 5000))

        let response = try await fetcher().fetch(
            URL(string: "https://example.com/a")!, accept: "text/html", maxBytes: 100, truncate: true)

        XCTAssertEqual(response.data.count, 100)
    }

    func testAnImageOverTheLimitIsRefused() async {
        StubProtocol.answers["https://example.com/a.png"] = .init(
            status: 200, headers: ["Content-Type": "image/png"], body: Data(count: 5000))

        do {
            _ = try await fetcher().fetch(
                URL(string: "https://example.com/a.png")!, accept: "image/*", maxBytes: 100, truncate: false)
            XCTFail("an oversized image returned")
        } catch {
            XCTAssertEqual(error as? GuardedLinkFetcher.Refusal, .tooLarge)
        }
    }

    func testTheRealPeerCheckFailsClosedWithNothingToInspect() {
        XCTAssertFalse(LinkPreviewHostPolicy.isPublicAddress(""))
        XCTAssertFalse(LinkPreviewHostPolicy.isPublicAddress("example.com"))
        XCTAssertFalse(LinkPreviewHostPolicy.isPublicAddress("127.0.0.1"))
        XCTAssertFalse(LinkPreviewHostPolicy.isPublicAddress("fe80::1%en0"))
        XCTAssertTrue(LinkPreviewHostPolicy.isPublicAddress("93.184.216.34"))
        XCTAssertTrue(LinkPreviewHostPolicy.isPublicAddress("2606:4700:4700::1111"))
    }
}

/// Answers requests from a table, and records what was asked for.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Answer {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _answers: [String: Answer] = [:]
    nonisolated(unsafe) private static var _requested: [String] = []

    static var answers: [String: Answer] {
        get { lock.lock(); defer { lock.unlock() }; return _answers }
        set { lock.lock(); _answers = newValue; lock.unlock() }
    }

    static var requested: [String] { lock.lock(); defer { lock.unlock() }; return _requested }

    static func reset() {
        lock.lock()
        _answers = [:]
        _requested = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self._requested.append(url.absoluteString)
        let answer = Self._answers[url.absoluteString]
        Self.lock.unlock()

        guard let answer,
              let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if (300..<400).contains(answer.status), let location = answer.headers["Location"],
           let target = URL(string: location, relativeTo: url) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
