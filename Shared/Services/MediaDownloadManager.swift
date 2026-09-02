import Foundation
import GRPC
import SanchrShared

/// Manages downloading, decrypting, and caching received media.
/// Media URLs use the `sanchr-media://{mediaId}` scheme — the manager
/// calls GetDownloadUrl(mediaId) to get a fresh presigned GET URL,
/// downloads the encrypted blob, decrypts with the key from the E2EE
/// message, and caches the plaintext locally.
actor MediaDownloadManager {
    private let mediaEncryption: MediaEncryptionProtocol
    private let accessKeyStore: AccessKeyStoreProtocol
    private let grpcClient: GRPCClientProtocol
    private let vaultEKFScheduler: VaultEKFScheduler
    private let cacheDir: URL
    private var inFlight: Set<String> = []

    init(
        mediaEncryption: MediaEncryptionProtocol,
        accessKeyStore: AccessKeyStoreProtocol,
        grpcClient: GRPCClientProtocol,
        vaultEKFScheduler: VaultEKFScheduler
    ) {
        self.mediaEncryption = mediaEncryption
        self.accessKeyStore = accessKeyStore
        self.grpcClient = grpcClient
        self.vaultEKFScheduler = vaultEKFScheduler

        // Store cached decrypted media inside the App Group container
        // rather than .cachesDirectory. cachesDirectory contents are purged
        // by iOS at will (low disk, background maintenance, iCloud optimized
        // storage) — causing users to see placeholder bubbles even for media
        // that's already been downloaded and decrypted.
        cacheDir = AppGroup.mediaCacheURL
            .appendingPathComponent("MediaMessages", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // One-time migration: move any existing files from the previous
        // cachesDirectory location into the persistent App Group location.
        // Safe to run on every init — it's a no-op once the old dir is empty.
        Self.migrateLegacyCachesDirectoryIfNeeded(to: cacheDir)
    }

    /// Moves any pre-existing decrypted media files from the legacy
    /// `.cachesDirectory/MediaMessages` location into the new App Group
    /// cache. Leaves the old directory in place so other readers (e.g.,
    /// MediaBubbleImage.thumbCacheDir fallbacks) can still find anything
    /// we fail to move, but removes each file we successfully relocated.
    private static func migrateLegacyCachesDirectoryIfNeeded(to newCacheDir: URL) {
        let fm = FileManager.default
        let legacy = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MediaMessages", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path),
              let entries = try? fm.contentsOfDirectory(atPath: legacy.path),
              !entries.isEmpty
        else {
            return
        }
        for entry in entries {
            let src = legacy.appendingPathComponent(entry)
            let dst = newCacheDir.appendingPathComponent(entry)
            // If the new location already has it (e.g., mid-migration
            // crash), keep the new copy and drop the legacy one.
            if fm.fileExists(atPath: dst.path) {
                try? fm.removeItem(at: src)
                continue
            }
            do {
                try fm.moveItem(at: src, to: dst)
            } catch {
                // Best effort — leave the legacy file for fallback reads.
                SanchrLogger.media.warning(
                    "Legacy media-cache migration skipped \(entry): \(error.localizedDescription)"
                )
            }
        }
    }

    /// Returns the local file URL if already cached.
    func cachedURL(for messageId: String, ext: String) -> URL? {
        let fileURL = cacheDir.appendingPathComponent("\(messageId).\(ext)")
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// Puts the sender's own file into the cache under `messageId`.
    ///
    /// Sending used to seed the cache only *after* the server replied, keyed by
    /// the server's message id. For the whole upload — which for a large video
    /// is not brief — the optimistic row had no cache entry at all and its
    /// bubbles depended entirely on the picker temp file still being where it
    /// was. When it was not, every fallback missed and the bubble asked to
    /// download a `file://` URL, which cannot be fetched by definition.
    ///
    /// Seeding up front closes that window; `recache(from:to:)` then re-keys
    /// the same copy once the id is known, rather than copying the source a
    /// second time.
    func cacheLocalCopy(of fileURL: URL, messageId: String, mimeType: String) {
        guard fileURL.isFileURL else { return }
        let destination = cacheDir
            .appendingPathComponent(MediaCacheFile.fileName(messageId: messageId, mimeType: mimeType))
        // copyItem refuses to overwrite, and a retry can legitimately land here
        // with a previous copy already in place.
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: fileURL, to: destination)
    }

    /// Re-keys an already-seeded copy from the optimistic id to the server id.
    ///
    /// A move, not a copy: leaving the optimistic entry behind would double the
    /// disk cost of every send and orphan the old file, since nothing ever
    /// looks up that id again.
    func recache(from oldMessageId: String, to newMessageId: String, mimeType: String) {
        let source = cacheDir
            .appendingPathComponent(MediaCacheFile.fileName(messageId: oldMessageId, mimeType: mimeType))
        let destination = cacheDir
            .appendingPathComponent(MediaCacheFile.fileName(messageId: newMessageId, mimeType: mimeType))
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: source, to: destination)
    }

    /// Wipes the cached decrypted file for a message. No-op if the
    /// file doesn't exist. Used by `deleteViewOnceMessage` to ensure
    /// the bytes are gone before the bubble flips to the tombstone.
    /// We don't know the extension here without re-reading the
    /// attachment, so glob the directory for any file starting with
    /// the messageId prefix and remove all matches.
    func removeCachedFile(messageId: String) {
        // The QuickLook hard link is a second name for the same bytes;
        // without this the plaintext survived the cache removal.
        QuickLookDisplayLinks.remove(messageId: messageId)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: cacheDir.path) else { return }
        for entry in entries where entry.hasPrefix(messageId + ".") {
            try? fm.removeItem(at: cacheDir.appendingPathComponent(entry))
        }
    }

    /// Download, decrypt, and cache media for a message.
    /// Handles both `sanchr-media://` (Vault mediaId) and direct HTTPS URLs.
    func download(
        messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL {
        let ext = MediaCacheFile.fileExtension(for: attachment.mimeType)

        // Check cache first
        if let cached = cachedURL(for: messageId, ext: ext) {
            return cached
        }

        // Prevent duplicate downloads
        guard !inFlight.contains(messageId) else {
            while inFlight.contains(messageId) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if let cached = cachedURL(for: messageId, ext: ext) {
                return cached
            }
            throw AppError.mediaDownloadFailed
        }
        inFlight.insert(messageId)
        defer { inFlight.remove(messageId) }

        // Resolve download URL
        let downloadURL: URL
        if attachment.url.scheme == "sanchr-media" {
            // Vault media — get presigned GET URL from server
            let mediaId = attachment.url.host ?? attachment.url.lastPathComponent
            SanchrLogger.media.info("Resolving download URL for mediaId=\(mediaId.prefix(8))...")

            var request = Sanchr_Media_GetDownloadUrlRequest()
            request.mediaID = mediaId
            let presignedURL: String
            do {
                presignedURL = try await grpcClient.mediaService.getDownloadUrl(request).url
            } catch let status as GRPCStatus where status.code == .notFound {
                // The server has already reaped the object. Nothing to retry.
                SanchrLogger.media.info("Media \(mediaId.prefix(8)) is gone from the server")
                throw AppError.mediaExpired
            }

            guard let url = URL(string: presignedURL) else {
                SanchrLogger.media.error("Invalid download URL from server")
                throw AppError.mediaDownloadFailed
            }
            downloadURL = url
            SanchrLogger.media.info("Got presigned download URL, downloading...")
        } else if attachment.url.isFileURL {
            // The sender's own media, whose temp file is gone and which was
            // never seeded into the cache. There is nothing to fetch — a
            // `file://` URL has no server behind it — so this is a cache miss
            // rather than a network failure, and is logged as one. Callers
            // already suppress the retry affordance for local URLs.
            SanchrLogger.media.info("No cached copy for local media \(messageId.prefix(8)); nothing to download")
            throw AppError.mediaDownloadFailed
        } else {
            // Direct HTTPS URL (legacy or CDN)
            downloadURL = attachment.url
            SanchrLogger.media.info("Using direct URL for download")
        }

        // Download encrypted blob
        let (encryptedData, response) = try await URLSession.shared.data(from: downloadURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            SanchrLogger.media.error("Download failed: HTTP \(status)")
            // The storage answered and said no: the object is gone or the
            // presigned URL will never be honoured. A retry would get the
            // same answer.
            if [403, 404, 410].contains(status) {
                throw AppError.mediaExpired
            }
            throw AppError.mediaDownloadFailed
        }
        SanchrLogger.media.info("Downloaded \(encryptedData.count) bytes, decrypting...")

        // Decrypt — try E2EE message key first, fall back to AccessK
        let plaintext: Data
        if !attachment.encryptionKey.isEmpty {
            // Primary path: key from E2EE message (first open)
            plaintext = try mediaEncryption.decrypt(
                ciphertext: encryptedData,
                key: attachment.encryptionKey,
                iv: attachment.encryptionIV
            )
        } else if let mediaId = extractMediaId(from: attachment) {
            // Re-access path: use device-local AccessK for chat media that
            // no longer carries an E2EE message key (view-once re-opens,
            // restored backups, etc.). Held inside the EKF access lock for
            // the duration of getAndTouch + decrypt so a scheduled purge
            // cannot race with the live decrypt, and bumped via
            // `getAndTouch` so each re-access refreshes the 30-day sliding
            // TTL on the stored AccessK.
            let store = self.accessKeyStore
            let crypto = self.mediaEncryption
            let iv = attachment.encryptionIV
            plaintext = try await vaultEKFScheduler.withAccess { () -> Data in
                guard let accessKey = try await store.getAndTouch(mediaId: mediaId) else {
                    // The AccessK was purged by the 30-day sliding TTL (or
                    // never stored). The ciphertext is unreadable on this
                    // device for good.
                    SanchrLogger.media.error(
                        "No AccessK available for re-access of \(mediaId.prefix(8))"
                    )
                    throw AppError.mediaExpired
                }
                SanchrLogger.media.info(
                    "Using AccessK for re-access of \(mediaId.prefix(8))"
                )
                return try crypto.decrypt(
                    ciphertext: encryptedData,
                    key: accessKey,
                    iv: iv
                )
            }
        } else {
            SanchrLogger.media.error("No decryption key available (E2EE key empty, no AccessK)")
            throw AppError.mediaDownloadFailed
        }

        // Cache to local disk
        let outputURL = cacheDir.appendingPathComponent("\(messageId).\(ext)")
        try plaintext.write(to: outputURL, options: .atomic)

        SanchrLogger.media.info("Media cached for message \(messageId.prefix(8)): \(plaintext.count) bytes plaintext")
        return outputURL
    }

    private func extractMediaId(from attachment: Message.MediaAttachment) -> String? {
        if attachment.url.scheme == "sanchr-media" {
            return attachment.url.host ?? attachment.url.lastPathComponent
        }
        return nil
    }

}
