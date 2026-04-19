import CryptoKit
import Foundation
import LinkPresentation
import SanchrShared

/// Fetches and caches Open Graph metadata for URLs.
/// Two-tier cache: in-memory NSCache + disk JSON cache.
/// Actor-based for safe concurrent access.
actor LinkPreviewService {
    static let shared = LinkPreviewService()

    private let memoryCache = NSCache<NSString, LinkPreviewData>()
    private var pending: [URL: [CheckedContinuation<LinkPreviewData?, Never>]] = [:]
    /// URLs that failed to fetch — don't retry until app restart
    private var failedURLs: Set<URL> = []
    private let diskCacheDir: URL

    private init() {
        memoryCache.countLimit = 300

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskCacheDir = caches.appendingPathComponent("LinkPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheDir, withIntermediateDirectories: true)
    }

    /// Returns cached preview (memory → disk) or fetches from network.
    func preview(for url: URL) async -> LinkPreviewData? {
        let key = url.absoluteString as NSString

        // 1. Memory cache (instant)
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }

        // 2. Disk cache (sub-ms file read)
        if let diskCached = loadFromDisk(url: url) {
            memoryCache.setObject(diskCached, forKey: key)
            return diskCached
        }

        // 3. Skip if previously failed
        if failedURLs.contains(url) {
            return nil
        }

        // 4. Coalesce concurrent requests for the same URL
        if pending[url] != nil {
            return await withCheckedContinuation { continuation in
                pending[url]?.append(continuation)
            }
        }

        pending[url] = []

        // 5. Fetch from network (background)
        let result = await fetchMetadata(for: url)

        if let result {
            memoryCache.setObject(result, forKey: key)
            saveToDisk(result)
        } else {
            failedURLs.insert(url)
        }

        let continuations = pending.removeValue(forKey: url) ?? []
        for cont in continuations {
            cont.resume(returning: result)
        }

        return result
    }

    // MARK: - Disk Cache

    private nonisolated func diskCacheKey(for url: URL) -> String {
        let data = Data(url.absoluteString.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated func loadFromDisk(url: URL) -> LinkPreviewData? {
        let filename = diskCacheKey(for: url)
        let fileURL = diskCacheDir.appendingPathComponent(filename + ".json")

        guard let data = try? Data(contentsOf: fileURL),
              let entry = try? JSONDecoder().decode(DiskCacheEntry.self, from: data) else {
            return nil
        }

        // Expire after 7 days
        if Date().timeIntervalSince(entry.cachedAt) > 7 * 24 * 3600 {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }

        return LinkPreviewData(
            url: url,
            title: entry.title,
            domain: entry.domain,
            imageData: entry.imageData
        )
    }

    private nonisolated func saveToDisk(_ preview: LinkPreviewData) {
        let filename = diskCacheKey(for: preview.url)
        let fileURL = diskCacheDir.appendingPathComponent(filename + ".json")

        let entry = DiskCacheEntry(
            title: preview.title,
            domain: preview.domain,
            imageData: preview.imageData,
            cachedAt: Date()
        )

        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Network Fetch

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
    ///
    /// Performance notes:
    /// - `NSDataDetector` instantiation is expensive; we reuse a single
    ///   thread-safe detector. `NSDataDetector` is documented as safe for
    ///   concurrent reads (a subclass of `NSRegularExpression` with the
    ///   same guarantees).
    /// - Results are cached by text so repeat renders of the same message
    ///   bubble during a scroll pay O(1) instead of O(n) regex cost.
    nonisolated static func firstURL(in text: String) -> URL? {
        if let cached = urlDetectionCache.object(forKey: text as NSString) {
            return cached.url
        }
        guard let detector = sharedLinkDetector else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        let url = detector.firstMatch(in: text, range: range)?.url
        urlDetectionCache.setObject(CachedURL(url: url), forKey: text as NSString)
        return url
    }

    /// Single shared `NSDataDetector` instance. Creating one per call was
    /// costing us multiple samples per scroll in Time Profiler.
    /// `NSRegularExpression` (NSDataDetector's superclass) is documented as
    /// safe for concurrent reads, so `nonisolated(unsafe)` is correct here.
    nonisolated(unsafe) private static let sharedLinkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    /// Bounded cache of detection results keyed by source text. The wrapper
    /// lets us cache the `nil` outcome too (NSCache requires non-nil values).
    /// NSCache is documented thread-safe; `nonisolated(unsafe)` encodes that.
    nonisolated(unsafe) private static let urlDetectionCache: NSCache<NSString, CachedURL> = {
        let cache = NSCache<NSString, CachedURL>()
        cache.countLimit = 500 // ~typical loaded transcript size; bounded
        return cache
    }()

    private final class CachedURL: NSObject, @unchecked Sendable {
        let url: URL?
        init(url: URL?) { self.url = url }
    }
}

// MARK: - Cache Models

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

private struct DiskCacheEntry: Codable {
    let title: String?
    let domain: String
    let imageData: Data?
    let cachedAt: Date
}
