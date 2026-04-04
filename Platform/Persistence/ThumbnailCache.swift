import CryptoKit
import Foundation
import UIKit

/// Downloads, decrypts, and caches vault item thumbnails.
///
/// Architecture (Signal-style):
/// - Thumbnails are encrypted with the same AES-256-GCM key as the main vault file.
/// - On first access, the encrypted blob is downloaded from S3, decrypted client-side,
///   and cached both in memory (NSCache) and on disk (Caches directory).
/// - Subsequent accesses hit memory → disk → network in that order.
/// - Cache is keyed by vault item ID, not URL (URLs may change/expire).
/// - Disk cache lives in Caches/ so the OS can evict it under storage pressure.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskCacheDir: URL

    /// Tracks in-flight downloads to avoid duplicate requests for the same item.
    private var inFlightTasks: [String: Task<UIImage?, Never>] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskCacheDir = caches.appendingPathComponent("vault-thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheDir, withIntermediateDirectories: true)
        memoryCache.countLimit = 200
    }

    // MARK: - Public API

    /// Returns a cached thumbnail immediately if available, otherwise fetches, decrypts, and caches.
    /// Returns nil for items without a thumbnail URL.
    func thumbnail(for item: VaultItem) async -> UIImage? {
        // Already have plaintext thumbnail in memory from this session's upload
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

        // No encrypted thumbnail URL — nothing to fetch
        guard let url = item.encryptedThumbnailURL, !item.encryptionKey.isEmpty else {
            return nil
        }

        // Deduplicate in-flight requests
        if let existing = inFlightTasks[item.id] {
            return await existing.value
        }

        let itemId = item.id
        let encryptionKey = item.encryptionKey
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            let image = await self.fetchAndDecrypt(url: url, key: encryptionKey, itemId: itemId)
            await self.clearInFlight(for: itemId)
            return image
        }
        inFlightTasks[item.id] = task

        return await task.value
    }

    /// Removes cached thumbnail for an item (call on delete).
    func remove(for itemId: String) {
        memoryCache.removeObject(forKey: itemId as NSString)
        inFlightTasks.removeValue(forKey: itemId)
        let diskURL = diskCacheDir.appendingPathComponent(itemId)
        try? FileManager.default.removeItem(at: diskURL)
    }

    // MARK: - Private

    private func clearInFlight(for itemId: String) {
        inFlightTasks.removeValue(forKey: itemId)
    }

    private nonisolated func fetchAndDecrypt(url: URL, key: Data, itemId: String) async -> UIImage? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                SanchrLogger.media.error("ThumbnailCache: download failed for \(itemId)")
                return nil
            }

            // Decrypt with the vault item's AES key
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            let symmetricKey = SymmetricKey(data: key)
            let plaintext = try AES.GCM.open(sealedBox, using: symmetricKey)

            guard let image = self.downsampleImage(data: plaintext) else {
                SanchrLogger.media.error("ThumbnailCache: decrypted data is not a valid image for \(itemId)")
                return nil
            }

            // Cache to disk (nonisolated-safe — disk ops don't need actor)
            let diskURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("vault-thumbnails", isDirectory: true)
                .appendingPathComponent(itemId)
            try? plaintext.write(to: diskURL, options: .atomic)

            SanchrLogger.media.info("ThumbnailCache: fetched + decrypted thumbnail for \(itemId)")
            return image
        } catch {
            SanchrLogger.media.error("ThumbnailCache: fetch/decrypt failed for \(itemId): \(error)")
            return nil
        }
    }

    private func saveToDisk(_ data: Data, for itemId: String) {
        let url = diskCacheDir.appendingPathComponent(itemId)
        try? data.write(to: url, options: .atomic)
    }

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
