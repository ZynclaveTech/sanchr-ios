import CryptoKit
import Foundation

/// Protocol defining vault (encrypted file storage) operations.
protocol VaultRepositoryProtocol: AnyObject, Sendable {
    /// Fetches all vault items for the current user.
    func fetchItems() async throws -> [VaultItem]

    /// Uploads an encrypted item to the vault.
    func uploadItem(data: Data, name: String, type: VaultItem.VaultItemType) async throws
        -> VaultItem

    /// Downloads and decrypts a vault item.
    func downloadItem(id: String) async throws -> Data

    /// Deletes a vault item from both local and remote storage.
    func deleteItem(id: String) async throws

    /// Returns the total storage used by vault items (in bytes).
    func storageUsed() async throws -> Int64
}

// MARK: - Implementation

final class VaultRepositoryImpl: VaultRepositoryProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol
    private let localDatabase: LocalDatabaseProtocol
    private let mediaEncryption: MediaEncryptionProtocol

    init(
        grpcClient: GRPCClientProtocol,
        localDatabase: LocalDatabaseProtocol,
        mediaEncryption: MediaEncryptionProtocol
    ) {
        self.grpcClient = grpcClient
        self.localDatabase = localDatabase
        self.mediaEncryption = mediaEncryption
    }

    func fetchItems() async throws -> [VaultItem] {
        SanchrLogger.media.info("Fetching vault items from server")

        var request = Vync_Vault_GetVaultItemsRequest()
        request.filter = "all"

        let response = try await grpcClient.vaultService.getVaultItems(request)

        let items = response.items.map { protoItem -> VaultItem in
            VaultItem(
                id: protoItem.itemID,
                name: protoItem.fileName,
                type: Self.mapMediaType(protoItem.mediaType),
                sizeBytes: protoItem.fileSize,
                encryptionKey: protoItem.encryptedKey,
                encryptionIV: Data(), // IV stored alongside encrypted key
                thumbnailData: nil,
                createdAt: Date(timeIntervalSince1970: TimeInterval(protoItem.createdAt) / 1000.0),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(protoItem.createdAt) / 1000.0),
                isCachedLocally: false,
                remoteURL: URL(string: protoItem.encryptedURL),
                localURL: nil
            )
        }

        // Cache items locally
        for item in items {
            try? await localDatabase.saveVaultItem(item)
        }

        SanchrLogger.media.info("Fetched \(items.count) vault items")
        return items
    }

    func uploadItem(data: Data, name: String, type: VaultItem.VaultItemType) async throws
        -> VaultItem
    {
        SanchrLogger.media.info("Uploading vault item: \(name)")

        // 1. Encrypt data with AES-GCM
        let (ciphertext, key, iv) = try mediaEncryption.encrypt(data: data)

        // 2. Compute SHA256 hash of encrypted blob for dedup
        let sha256Hash = SHA256.hash(data: ciphertext)
        let hashHex = sha256Hash.compactMap { String(format: "%02x", $0) }.joined()

        // 3. Get presigned upload URL from server
        var uploadRequest = Vync_Media_GetUploadUrlRequest()
        uploadRequest.fileSize = Int64(ciphertext.count)
        uploadRequest.contentType = Self.mimeType(for: type)
        uploadRequest.sha256Hash = hashHex

        let uploadUrlResponse = try await grpcClient.mediaService.getUploadUrl(uploadRequest)

        guard let uploadURL = URL(string: uploadUrlResponse.url) else {
            throw AppError.mediaUploadFailed
        }

        // 4. Upload encrypted data to S3 via presigned URL
        var urlRequest = URLRequest(url: uploadURL)
        urlRequest.httpMethod = "PUT"
        urlRequest.httpBody = ciphertext
        urlRequest.setValue(Self.mimeType(for: type), forHTTPHeaderField: "Content-Type")

        let (_, uploadHTTPResponse) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = uploadHTTPResponse as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AppError.mediaUploadFailed
        }

        // 5. Confirm upload with server
        var confirmRequest = Vync_Media_ConfirmUploadRequest()
        confirmRequest.mediaID = uploadUrlResponse.mediaID
        confirmRequest.fileSize = Int64(ciphertext.count)

        _ = try await grpcClient.mediaService.confirmUpload(confirmRequest)

        // 6. Create vault item record on server
        var createRequest = Vync_Vault_CreateVaultItemRequest()
        createRequest.mediaType = Self.mediaTypeString(for: type)
        createRequest.encryptedURL = uploadUrlResponse.url
        createRequest.encryptedKey = key
        createRequest.fileName = name
        createRequest.fileSize = Int64(data.count)

        let vaultItem = try await grpcClient.vaultService.createVaultItem(createRequest)

        // 7. Create domain model and save locally
        let item = VaultItem(
            id: vaultItem.itemID,
            name: name,
            type: type,
            sizeBytes: Int64(data.count),
            encryptionKey: key,
            encryptionIV: iv,
            thumbnailData: nil,
            createdAt: Date(timeIntervalSince1970: TimeInterval(vaultItem.createdAt) / 1000.0),
            updatedAt: Date(),
            isCachedLocally: false,
            remoteURL: URL(string: vaultItem.encryptedURL),
            localURL: nil
        )

        try await localDatabase.saveVaultItem(item)

        SanchrLogger.media.info("Vault item uploaded: \(item.id)")
        return item
    }

    func downloadItem(id: String) async throws -> Data {
        SanchrLogger.media.info("Downloading vault item: \(id)")

        // 1. Get download URL from media service
        var downloadRequest = Vync_Media_GetDownloadUrlRequest()
        downloadRequest.mediaID = id

        let downloadUrlResponse = try await grpcClient.mediaService.getDownloadUrl(downloadRequest)

        guard let downloadURL = URL(string: downloadUrlResponse.url) else {
            throw AppError.mediaDownloadFailed
        }

        // 2. Download encrypted data from S3
        let (ciphertext, httpResponse) = try await URLSession.shared.data(from: downloadURL)
        guard let response = httpResponse as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            throw AppError.mediaDownloadFailed
        }

        // 3. Retrieve encryption key from local database
        let items = try await localDatabase.fetchVaultItems()
        guard let item = items.first(where: { $0.id == id }) else {
            throw AppError.decryptionFailed(reason: "No encryption key found for vault item \(id)")
        }

        // 4. Decrypt and return plaintext
        let plaintext = try mediaEncryption.decrypt(
            ciphertext: ciphertext,
            key: item.encryptionKey,
            iv: item.encryptionIV
        )

        SanchrLogger.media.info("Vault item downloaded and decrypted: \(plaintext.count) bytes")
        return plaintext
    }

    func deleteItem(id: String) async throws {
        SanchrLogger.media.info("Deleting vault item: \(id)")

        // Delete from server
        var request = Vync_Vault_DeleteVaultItemRequest()
        request.itemID = id

        _ = try await grpcClient.vaultService.deleteVaultItem(request)

        // Delete locally
        try await localDatabase.deleteVaultItem(id: id)
    }

    func storageUsed() async throws -> Int64 {
        SanchrLogger.media.info("Fetching storage usage from server")

        let request = Vync_Settings_GetStorageUsageRequest()
        let response = try await grpcClient.settingsService.getStorageUsage(request)

        return response.totalBytes
    }

    // MARK: - Helpers

    private static func mapMediaType(_ typeString: String) -> VaultItem.VaultItemType {
        switch typeString.lowercased() {
        case "photo", "image": return .photo
        case "video": return .video
        case "audio": return .audio
        case "document", "file": return .document
        case "note": return .note
        default: return .document
        }
    }

    private static func mediaTypeString(for type: VaultItem.VaultItemType) -> String {
        switch type {
        case .photo: return "photo"
        case .video: return "video"
        case .audio: return "audio"
        case .document: return "file"
        case .note: return "file"
        }
    }

    private static func mimeType(for type: VaultItem.VaultItemType) -> String {
        switch type {
        case .photo: return "image/jpeg"
        case .video: return "video/mp4"
        case .audio: return "audio/aac"
        case .document: return "application/octet-stream"
        case .note: return "text/plain"
        }
    }
}
