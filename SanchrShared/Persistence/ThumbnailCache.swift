import Foundation
import UIKit

/// Downloads, decrypts, and caches vault item thumbnails.
///
/// Architecture (Signal-style, post forward-secure rewrite):
/// - Thumbnails travel inside the encrypted_metadata envelope of each vault
///   item. The client decrypts the envelope once per fetch using
///   AccessK_vault from AccessKeyStore, and the resulting JPEG bytes land
///   on VaultItem.thumbnailData.
/// - The first call to `thumbnail(for:)` downsamples the plaintext bytes,
///   caches them in memory (NSCache) and on disk (Caches directory), and
///   returns the resulting UIImage.
/// - Subsequent accesses hit memory → disk → nil in that order. Items
///   without a thumbnailData blob (e.g. sealed restores, or types that
///   don't have thumbnails) return nil so the UI can render a placeholder.
/// - Disk cache lives in Caches/ so the OS can evict it under storage
///   pressure.
public actor ThumbnailCache {
    public static let shared = ThumbnailCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskCacheDir: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskCacheDir = caches.appendingPathComponent("vault-thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheDir, withIntermediateDirectories: true)
        memoryCache.countLimit = 200
    }

    // MARK: - Public API

    /// Returns a cached thumbnail immediately if available, otherwise
    /// downsamples the item's plaintext thumbnail bytes and caches them.
    /// Returns nil for items without a thumbnail blob.
    public func thumbnail(for item: VaultItem) async -> UIImage? {
        // Already have plaintext thumbnail in memory from this session's upload
        // or from the decrypted metadata envelope on fetch.
        if let data = item.thumbnailData, let image = downsampleImage(data: data) {
            memoryCache.setObject(image, forKey: item.id as NSString)
            return image
        }

        // Memory cache
        if let cached = memoryCache.object(forKey: item.id as NSString) {
            return cached
        }

        // Disk cache
        if let image = loadFromDisk(for: item.id) {
            memoryCache.setObject(image, forKey: item.id as NSString)
            return image
        }

        return nil
    }

    /// Removes cached thumbnail for an item (call on delete).
    public func remove(for itemId: String) {
        memoryCache.removeObject(forKey: itemId as NSString)
        let diskURL = diskCacheDir.appendingPathComponent(itemId)
        try? FileManager.default.removeItem(at: diskURL)
    }

    // MARK: - Private

    private func loadFromDisk(for itemId: String) -> UIImage? {
        let url = diskCacheDir.appendingPathComponent(itemId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return downsampleImage(data: data)
    }

    private nonisolated func downsampleImage(data: Data, maxDimension: CGFloat = 320) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return nil
        }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            downsampleOptions as CFDictionary
        ) else {
            return nil
        }

        return UIImage(cgImage: image)
    }
}
