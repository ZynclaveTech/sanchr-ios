import CryptoKit
import Foundation
import SanchrShared

/// Data source for vault-related gRPC service calls.
/// Orchestrates VaultService and MediaService RPCs for encrypted vault operations.
final class VaultDataSource: @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol
    private let mediaEncryption: MediaEncryptionProtocol

    private var vaultClient: Vync_Vault_VaultServiceAsyncClientProtocol {
        grpcClient.vaultService
    }

    private var mediaClient: Vync_Media_MediaServiceAsyncClientProtocol {
        grpcClient.mediaService
    }

    init(
        grpcClient: GRPCClientProtocol,
        mediaEncryption: MediaEncryptionProtocol
    ) {
        self.grpcClient = grpcClient
        self.mediaEncryption = mediaEncryption
    }

    // MARK: - Get Vault Items

    /// Fetches vault items with optional filter and cursor-based pagination.
    func getVaultItems(
        filter: String = "all",
        limit: Int32 = 20,
        cursor: String = ""
    ) async throws -> Vync_Vault_GetVaultItemsResponse {
        var request = Vync_Vault_GetVaultItemsRequest()
        request.filter = filter
        request.limit = limit
        request.beforeItemID = cursor

        SanchrLogger.network.info("VaultDataSource: getVaultItems filter=\(filter) limit=\(limit)")
        return try await vaultClient.getVaultItems(request)
    }

    // MARK: - Create Vault Item (Upload Flow)

    /// Full upload pipeline: encrypt -> get presigned URL -> upload to S3 -> create vault record.
    /// If `thumbnailData` is provided, encrypts it with the same key and uploads as a separate blob.
    func createVaultItem(
        data: Data,
        fileName: String,
        mediaType: String,
        senderID: String,
        ttlSeconds: Int64 = 0,
        thumbnailData: Data? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Vync_Vault_VaultItem {
        // 1. Encrypt main file with AES-GCM
        let encrypted = try mediaEncryption.encrypt(data: data)
        let ciphertext = encrypted.ciphertext
        let encryptionKey = encrypted.key

        SanchrLogger.media.info(
            "VaultDataSource: encrypted \(data.count) -> \(ciphertext.count) bytes")

        // 2. Compute SHA-256 hash of ciphertext for dedup
        let digest = SHA256.hash(data: ciphertext)
        let hashHex = digest.map { String(format: "%02x", $0) }.joined()

        // 3. Get presigned upload URL from MediaService
        let contentType = Self.mimeType(for: mediaType)
        var uploadRequest = Vync_Media_GetUploadUrlRequest()
        uploadRequest.fileSize = Int64(ciphertext.count)
        uploadRequest.contentType = contentType
        uploadRequest.sha256Hash = hashHex

        let uploadUrlResponse = try await mediaClient.getUploadUrl(uploadRequest)
        let presignedURL = uploadUrlResponse.url
        let mediaID = uploadUrlResponse.mediaID

        SanchrLogger.media.info("VaultDataSource: got presigned URL, mediaID=\(mediaID)")

        onProgress?(0.05)

        // 4. Upload encrypted thumbnail (if provided) — same AES key, separate blob
        var thumbnailURL = ""
        if let thumbData = thumbnailData {
            let encryptedThumb = try mediaEncryption.encrypt(data: thumbData, withKey: encryptionKey)
            let thumbDigest = SHA256.hash(data: encryptedThumb)
            let thumbHash = thumbDigest.map { String(format: "%02x", $0) }.joined()

            var thumbUploadReq = Vync_Media_GetUploadUrlRequest()
            thumbUploadReq.fileSize = Int64(encryptedThumb.count)
            thumbUploadReq.contentType = "application/octet-stream"
            thumbUploadReq.sha256Hash = thumbHash

            let thumbUrlResponse = try await mediaClient.getUploadUrl(thumbUploadReq)
            try await uploadToS3(
                data: encryptedThumb,
                url: thumbUrlResponse.url,
                contentType: "application/octet-stream"
            )

            var thumbConfirm = Vync_Media_ConfirmUploadRequest()
            thumbConfirm.mediaID = thumbUrlResponse.mediaID
            thumbConfirm.fileSize = Int64(encryptedThumb.count)
            _ = try await mediaClient.confirmUpload(thumbConfirm)

            // Strip query params to get the permanent S3 path
            if let components = URLComponents(string: thumbUrlResponse.url) {
                var clean = components
                clean.queryItems = nil
                thumbnailURL = clean.url?.absoluteString ?? thumbUrlResponse.url
            } else {
                thumbnailURL = thumbUrlResponse.url
            }
            SanchrLogger.media.info("VaultDataSource: encrypted thumbnail uploaded (\(encryptedThumb.count) bytes)")
        }

        onProgress?(0.1)

        // 5. Upload main ciphertext to S3 via presigned URL
        try await uploadToS3(data: ciphertext, url: presignedURL, contentType: contentType) { fraction in
            onProgress?(0.1 + fraction * 0.8)
        }

        // 6. Confirm the upload
        var confirmRequest = Vync_Media_ConfirmUploadRequest()
        confirmRequest.mediaID = mediaID
        confirmRequest.fileSize = Int64(ciphertext.count)
        _ = try await mediaClient.confirmUpload(confirmRequest)

        onProgress?(0.95)

        // 7. Create vault item record on the server
        var createRequest = Vync_Vault_CreateVaultItemRequest()
        createRequest.mediaType = mediaType
        createRequest.encryptedURL = presignedURL
        createRequest.encryptedKey = encryptionKey
        createRequest.thumbnailURL = thumbnailURL
        createRequest.fileName = fileName
        createRequest.fileSize = Int64(data.count)
        createRequest.senderID = senderID
        createRequest.ttlSeconds = ttlSeconds

        SanchrLogger.network.info("VaultDataSource: createVaultItem \(fileName)")
        return try await vaultClient.createVaultItem(createRequest)
    }

    // MARK: - Delete Vault Item

    /// Deletes a vault item by ID.
    func deleteVaultItem(itemId: String) async throws {
        var request = Vync_Vault_DeleteVaultItemRequest()
        request.itemID = itemId

        SanchrLogger.network.info("VaultDataSource: deleteVaultItem \(itemId.prefix(8))...")
        _ = try await vaultClient.deleteVaultItem(request)
    }

    // MARK: - Share Vault Item

    /// Shares a vault item with another user by re-encrypting the media key.
    func shareVaultItem(
        itemId: String,
        recipientId: String,
        reEncryptedKey: String
    ) async throws {
        var request = Vync_Vault_ShareVaultItemRequest()
        request.itemID = itemId
        request.recipientID = recipientId
        request.reEncryptedKey = reEncryptedKey

        SanchrLogger.network.info(
            "VaultDataSource: shareVaultItem \(itemId.prefix(8))... -> \(recipientId.prefix(8))...")
        _ = try await vaultClient.shareVaultItem(request)
    }

    // MARK: - Media URLs

    /// Gets a presigned upload URL from MediaService.
    func getUploadUrl(
        fileSize: Int64,
        contentType: String,
        hash: String
    ) async throws -> Vync_Media_PresignedUrlResponse {
        var request = Vync_Media_GetUploadUrlRequest()
        request.fileSize = fileSize
        request.contentType = contentType
        request.sha256Hash = hash

        SanchrLogger.network.info("VaultDataSource: getUploadUrl")
        return try await mediaClient.getUploadUrl(request)
    }

    /// Gets a presigned download URL from MediaService.
    func getDownloadUrl(mediaId: String) async throws -> Vync_Media_PresignedUrlResponse {
        var request = Vync_Media_GetDownloadUrlRequest()
        request.mediaID = mediaId

        SanchrLogger.network.info("VaultDataSource: getDownloadUrl \(mediaId.prefix(8))...")
        return try await mediaClient.getDownloadUrl(request)
    }

    // MARK: - Private Helpers

    /// Uploads raw data to an S3 presigned URL via HTTP PUT with progress tracking.
    private func uploadToS3(
        data: Data,
        url: String,
        contentType: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard let uploadURL = URL(string: url) else {
            throw AppError.mediaUploadFailed
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")

        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (_, response) = try await session.upload(for: request, from: data)

        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            SanchrLogger.media.error("S3 upload failed with response: \(response)")
            throw AppError.mediaUploadFailed
        }

        SanchrLogger.media.info("S3 upload complete: \(data.count) bytes")
    }

    /// Returns a MIME type string for a vault media type.
    static func mimeType(for mediaType: String) -> String {
        switch mediaType {
        case "photo": return "image/jpeg"
        case "video": return "video/mp4"
        case "file": return "application/octet-stream"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Upload Progress Delegate

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let onProgress: (@Sendable (Double) -> Void)?

    init(onProgress: (@Sendable (Double) -> Void)?) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        onProgress?(fraction)
    }
}
