import Foundation

/// Manages downloading, decrypting, and caching received media.
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
    func download(
        messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL {
        let ext = extensionForMime(attachment.mimeType)

        // Check cache
        if let cached = cachedURL(for: messageId, ext: ext) {
            return cached
        }

        // Prevent duplicate downloads
        guard !inFlight.contains(messageId) else {
            // Wait for existing download
            while inFlight.contains(messageId) {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms poll
            }
            if let cached = cachedURL(for: messageId, ext: ext) {
                return cached
            }
            throw AppError.mediaDownloadFailed
        }
        inFlight.insert(messageId)
        defer { inFlight.remove(messageId) }

        // Download encrypted blob
        let (encryptedData, response) = try await URLSession.shared.data(from: attachment.url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AppError.mediaDownloadFailed
        }

        // Decrypt
        let plaintext = try mediaEncryption.decrypt(
            ciphertext: encryptedData,
            key: attachment.encryptionKey,
            iv: attachment.encryptionIV
        )

        // Cache to disk
        let outputURL = cacheDir.appendingPathComponent("\(messageId).\(ext)")
        try plaintext.write(to: outputURL, options: .atomic)

        SanchrLogger.media.info("Downloaded + decrypted media for message \(messageId.prefix(8)): \(plaintext.count) bytes")
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
