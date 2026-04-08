import Foundation
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
    private let cacheDir: URL
    private var inFlight: Set<String> = []

    init(
        mediaEncryption: MediaEncryptionProtocol,
        accessKeyStore: AccessKeyStoreProtocol,
        grpcClient: GRPCClientProtocol
    ) {
        self.mediaEncryption = mediaEncryption
        self.accessKeyStore = accessKeyStore
        self.grpcClient = grpcClient

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = caches.appendingPathComponent("MediaMessages", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Returns the local file URL if already cached.
    func cachedURL(for messageId: String, ext: String) -> URL? {
        let fileURL = cacheDir.appendingPathComponent("\(messageId).\(ext)")
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// Wipes the cached decrypted file for a message. No-op if the
    /// file doesn't exist. Used by `deleteViewOnceMessage` to ensure
    /// the bytes are gone before the bubble flips to the tombstone.
    /// We don't know the extension here without re-reading the
    /// attachment, so glob the directory for any file starting with
    /// the messageId prefix and remove all matches.
    func removeCachedFile(messageId: String) {
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
        let ext = extensionForMime(attachment.mimeType)

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

            var request = Vync_Media_GetDownloadUrlRequest()
            request.mediaID = mediaId
            let response = try await grpcClient.mediaService.getDownloadUrl(request)

            guard let url = URL(string: response.url) else {
                SanchrLogger.media.error("Invalid download URL from server")
                throw AppError.mediaDownloadFailed
            }
            downloadURL = url
            SanchrLogger.media.info("Got presigned download URL, downloading...")
        } else if attachment.url.isFileURL {
            // Local file — sender's own media, should be cached already
            SanchrLogger.media.warning("Download called for local file URL, skipping")
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
        } else if let mediaId = extractMediaId(from: attachment),
                  let accessKey = try await accessKeyStore.retrieve(mediaId: mediaId) {
            // Re-access path: use device-local AccessK
            SanchrLogger.media.info("Using AccessK for re-access of \(mediaId.prefix(8))")
            plaintext = try mediaEncryption.decrypt(
                ciphertext: encryptedData,
                key: accessKey,
                iv: attachment.encryptionIV
            )
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

    private func extensionForMime(_ mime: String) -> String {
        switch mime {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/heic": return "heic"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "audio/aac", "audio/m4a": return "m4a"
        case "application/pdf": return "pdf"
        default: return "bin"
        }
    }
}
