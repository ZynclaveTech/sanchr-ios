import Foundation

/// Manages downloading, decrypting, and caching received media.
/// Media URLs use the `sanchr-media://{mediaId}` scheme — the manager
/// calls GetDownloadUrl(mediaId) to get a fresh presigned GET URL,
/// downloads the encrypted blob, decrypts with the key from the E2EE
/// message, and caches the plaintext locally.
actor MediaDownloadManager {
    private let mediaEncryption: MediaEncryptionProtocol
    private let grpcClient: GRPCClientProtocol
    private let cacheDir: URL
    private var inFlight: Set<String> = []

    init(mediaEncryption: MediaEncryptionProtocol, grpcClient: GRPCClientProtocol) {
        self.mediaEncryption = mediaEncryption
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

        // Decrypt with key from E2EE message
        let plaintext = try mediaEncryption.decrypt(
            ciphertext: encryptedData,
            key: attachment.encryptionKey,
            iv: attachment.encryptionIV
        )

        // Cache to local disk
        let outputURL = cacheDir.appendingPathComponent("\(messageId).\(ext)")
        try plaintext.write(to: outputURL, options: .atomic)

        SanchrLogger.media.info("Media cached for message \(messageId.prefix(8)): \(plaintext.count) bytes plaintext")
        return outputURL
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
