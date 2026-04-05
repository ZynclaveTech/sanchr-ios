import Foundation
import LinkPresentation

/// Fetches and caches Open Graph metadata for URLs.
/// Actor-based for safe concurrent access.
actor LinkPreviewService {
    static let shared = LinkPreviewService()

    private let cache = NSCache<NSString, LinkPreviewData>()
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
        if pending[url] != nil {
            return await withCheckedContinuation { continuation in
                pending[url]?.append(continuation)
            }
        }

        pending[url] = []

        let result = await fetchMetadata(for: url)

        if let result {
            cache.setObject(result, forKey: key)
        }

        let continuations = pending.removeValue(forKey: url) ?? []
        for cont in continuations {
            cont.resume(returning: result)
        }

        return result
    }

    private nonisolated func fetchMetadata(for url: URL) async -> LinkPreviewData? {
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
    nonisolated static func firstURL(in text: String) -> URL? {
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
final class LinkPreviewData: NSObject, Sendable {
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
