import Foundation
import LinkPresentation

/// Fetches and caches Open Graph metadata for URLs.
/// Thread-safe with NSCache for in-memory caching.
final class LinkPreviewService: @unchecked Sendable {
    static let shared = LinkPreviewService()

    private let cache = NSCache<NSString, LinkPreviewData>()
    private let inFlight = NSLock()
    private var pending: [URL: [CheckedContinuation<LinkPreviewData?, Never>]] = [:]

    private init() {
        cache.countLimit = 200
    }

    /// Returns cached preview or fetches from network.
    func preview(for url: URL) async -> LinkPreviewData? {
        let key = url.absoluteString as NSString

        // Check cache
        if let cached = cache.object(forKey: key) {
            return cached
        }

        // Coalesce concurrent requests for the same URL
        return await withCheckedContinuation { continuation in
            inFlight.lock()
            if var existing = pending[url] {
                existing.append(continuation)
                pending[url] = existing
                inFlight.unlock()
                return
            }
            pending[url] = [continuation]
            inFlight.unlock()

            Task.detached(priority: .utility) { [weak self] in
                let result = await self?.fetchMetadata(for: url)
                self?.inFlight.lock()
                let continuations = self?.pending.removeValue(forKey: url) ?? []
                self?.inFlight.unlock()

                if let result {
                    self?.cache.setObject(result, forKey: key)
                }
                for cont in continuations {
                    cont.resume(returning: result)
                }
            }
        }
    }

    private func fetchMetadata(for url: URL) async -> LinkPreviewData? {
        let provider = LPMetadataProvider()
        provider.timeout = 10

        do {
            let metadata = try await provider.startFetchingMetadata(for: url)
            let title = metadata.title
            let domain = url.host ?? url.absoluteString

            var imageData: Data?
            if let imageProvider = metadata.imageProvider {
                imageData = try? await withCheckedThrowingContinuation { cont in
                    imageProvider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, error in
                        if let data {
                            cont.resume(returning: data)
                        } else {
                            cont.resume(throwing: error ?? NSError(domain: "", code: 0))
                        }
                    }
                }
            }

            return LinkPreviewData(
                url: url,
                title: title,
                domain: domain,
                imageData: imageData
            )
        } catch {
            return nil
        }
    }

    /// Detect first URL in a text string.
    static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, range: range),
              let url = match.url else {
            return nil
        }
        return url
    }
}

/// Cached link preview data.
final class LinkPreviewData: NSObject {
    let url: URL
    let title: String?
    let domain: String
    let imageData: Data?

    init(url: URL, title: String?, domain: String, imageData: Data?) {
        self.url = url
        self.title = title
        self.domain = domain
        self.imageData = imageData
    }
}
