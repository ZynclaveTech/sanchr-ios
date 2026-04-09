import CryptoKit
import Foundation
import SanchrShared

/// Data source for the forward-secure vault.
///
/// Calls the `VaultService` gRPC endpoints and the `MediaService` upload/
/// download helpers. Encrypts the metadata envelope client-side with the
/// per-item `AccessK_vault` so the server never sees filename, mime type,
/// thumbnail, or any other descriptive field.
///
/// The key lifecycle is:
/// 1. Generate a fresh `vault_item_id` (UUIDv4) on the client
/// 2. Generate a random 32-byte salt
/// 3. Derive `AccessK_vault = HKDF(dls, salt, "sanchr-vault-manual-v1-<id>")`
/// 4. Encrypt the file ciphertext and the metadata envelope with that key
/// 5. Store the key in `AccessKeyStore` keyed by `vault_item_id`, kind: .vaultManual
/// 6. Send only the opaque ciphertext + encrypted metadata to the server
///
/// On fetch:
/// 1. Receive the `VaultItem` from the server (opaque bytes)
/// 2. Look up `AccessK_vault` in `AccessKeyStore` via `getAndTouch`
/// 3. Decrypt the metadata envelope locally
final class VaultDataSource: @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol
    private let accessKeyStore: AccessKeyStoreProtocol
    private let mediaKeyDerivation: MediaKeyDerivationProtocol
    private let deviceSecretProvider: DeviceSecretProviderProtocol
    private let mediaEncryption: MediaEncryptionProtocol

    private var vaultClient: Vync_Vault_VaultServiceAsyncClientProtocol {
        grpcClient.vaultService
    }

    private var mediaClient: Vync_Media_MediaServiceAsyncClientProtocol {
        grpcClient.mediaService
    }

    init(
        grpcClient: GRPCClientProtocol,
        accessKeyStore: AccessKeyStoreProtocol,
        mediaKeyDerivation: MediaKeyDerivationProtocol,
        deviceSecretProvider: DeviceSecretProviderProtocol,
        mediaEncryption: MediaEncryptionProtocol
    ) {
        self.grpcClient = grpcClient
        self.accessKeyStore = accessKeyStore
        self.mediaKeyDerivation = mediaKeyDerivation
        self.deviceSecretProvider = deviceSecretProvider
        self.mediaEncryption = mediaEncryption
    }

    // MARK: - List

    /// Fetches the next page of vault items. Returns the raw proto response;
    /// the repository/use-case layer decrypts the metadata envelope per-item
    /// using `AccessKeyStore`.
    func getVaultItems(
        limit: Int32 = 20,
        cursor: String = ""
    ) async throws -> Vync_Vault_GetVaultItemsResponse {
        SanchrLogger.network.info(
            "VaultDataSource: getVaultItems limit=\(limit) cursor.len=\(cursor.count)"
        )
        var request = Vync_Vault_GetVaultItemsRequest()
        request.limit = limit
        request.pagingToken = cursor
        return try await vaultClient.getVaultItems(request)
    }

    /// Point-lookup for a single vault item by ID. Returns the raw proto.
    func getVaultItem(vaultItemId: String) async throws -> Vync_Vault_VaultItem {
        var request = Vync_Vault_GetVaultItemRequest()
        request.vaultItemID = vaultItemId
        return try await vaultClient.getVaultItem(request)
    }

    // MARK: - Create

    /// Manual upload path. Derives a new AccessK_vault, encrypts the payload
    /// AND metadata client-side, uploads the ciphertext to S3, registers the
    /// vault item server-side, and stores the key in AccessKeyStore.
    ///
    /// - Returns: the server's echoed `VaultItem` (opaque) + the locally
    ///   decrypted metadata as a `VaultItemMetadata` helper struct.
    func createVaultItem(
        data: Data,
        fileName: String,
        mediaType: String,
        thumbnailData: Data? = nil,
        expiresAt: Int64 = 0,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> (proto: Vync_Vault_VaultItem, metadata: VaultItemMetadata) {
        // 1. Generate a fresh vault_item_id and salt.
        let vaultItemId = UUID().uuidString.lowercased()
        var saltBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes)
        guard status == errSecSuccess else {
            throw VaultDataSourceError.randomGenerationFailed
        }
        let salt = Data(saltBytes)

        // 2. Derive AccessK_vault from the device master secret.
        let dls = try deviceSecretProvider.mediaAccessSecret()
        let accessKey = mediaKeyDerivation.deriveVaultAccessKeyManual(
            deviceSecret: dls,
            salt: salt,
            vaultItemId: vaultItemId
        )

        // 3. Encrypt the payload with AccessK_vault.
        let ciphertext = try mediaEncryption.encrypt(data: data, withKey: accessKey)

        SanchrLogger.media.info(
            "VaultDataSource: encrypted \(data.count) -> \(ciphertext.count) bytes for \(vaultItemId.prefix(8))..."
        )

        // 4. Get a presigned upload URL from the media service.
        let contentType = Self.contentType(for: mediaType)
        let hash = SHA256.hash(data: ciphertext).map { String(format: "%02x", $0) }.joined()

        var uploadReq = Vync_Media_GetUploadUrlRequest()
        uploadReq.fileSize = Int64(ciphertext.count)
        uploadReq.contentType = contentType
        uploadReq.sha256Hash = hash
        uploadReq.purpose = .attachment
        let presigned = try await mediaClient.getUploadUrl(uploadReq)

        onProgress?(0.1)

        // 5. PUT the ciphertext to S3 via presigned URL.
        try await Self.uploadToS3(
            data: ciphertext,
            url: presigned.url,
            contentType: contentType
        ) { fraction in
            onProgress?(0.1 + fraction * 0.8)
        }

        // 6. Confirm upload with the media service.
        var confirmReq = Vync_Media_ConfirmUploadRequest()
        confirmReq.mediaID = presigned.mediaID
        confirmReq.fileSize = Int64(ciphertext.count)
        _ = try await mediaClient.confirmUpload(confirmReq)

        onProgress?(0.95)

        // 7. Build and encrypt the metadata envelope.
        let metadata = VaultItemMetadata(
            name: fileName,
            mimeType: contentType,
            sizeBytes: Int64(data.count),
            thumbnailJpeg: thumbnailData,
            originalSenderId: nil,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            kind: AccessKeyEntry.Kind.vaultManual.rawValue
        )
        let metadataJson = try JSONEncoder().encode(metadata)
        guard metadataJson.count <= 64 * 1024 else {
            throw VaultDataSourceError.metadataTooLarge(actual: metadataJson.count)
        }
        let encryptedMetadata = try mediaEncryption.encrypt(
            data: metadataJson,
            withKey: accessKey
        )

        // 8. Create the vault item row on the server.
        var createReq = Vync_Vault_CreateVaultItemRequest()
        createReq.vaultItemID = vaultItemId
        createReq.mediaID = presigned.mediaID
        createReq.encryptedMetadata = encryptedMetadata
        createReq.expiresAt = expiresAt

        SanchrLogger.network.info(
            "VaultDataSource: createVaultItem \(vaultItemId.prefix(8))..."
        )
        let vaultProto = try await vaultClient.createVaultItem(createReq)

        // 9. Persist AccessK_vault locally. The vault_item_id is used as the
        //    access-key-store primary key (field name is `mediaId` for
        //    historical reasons; see the comment on AccessKeyEntry.mediaId).
        try await accessKeyStore.store(
            mediaId: vaultItemId,
            accessKey: accessKey,
            conversationId: "",
            kind: .vaultManual
        )

        onProgress?(1.0)
        return (vaultProto, metadata)
    }

    // MARK: - Delete

    func deleteVaultItem(vaultItemId: String) async throws {
        SanchrLogger.network.info(
            "VaultDataSource: deleteVaultItem \(vaultItemId.prefix(8))..."
        )
        var request = Vync_Vault_DeleteVaultItemRequest()
        request.vaultItemID = vaultItemId
        _ = try await vaultClient.deleteVaultItem(request)
    }

    // MARK: - Helpers

    private static func contentType(for mediaType: String) -> String {
        switch mediaType {
        case "photo": return "image/jpeg"
        case "video": return "video/mp4"
        case "audio": return "audio/m4a"
        case "document": return "application/octet-stream"
        case "note": return "text/plain"
        default: return "application/octet-stream"
        }
    }

    private static func uploadToS3(
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

        guard
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            SanchrLogger.media.error("S3 upload failed with response: \(response)")
            throw AppError.mediaUploadFailed
        }
        SanchrLogger.media.info("S3 upload complete: \(data.count) bytes")
    }
}

/// The metadata envelope carried inside `encrypted_metadata`. Never sent as
/// plaintext; the server only sees the AES-GCM ciphertext of this struct.
struct VaultItemMetadata: Codable, Sendable {
    let name: String
    let mimeType: String
    let sizeBytes: Int64
    let thumbnailJpeg: Data?
    let originalSenderId: String?
    let createdAtMs: Int64
    let kind: String  // AccessKeyEntry.Kind rawValue
}

enum VaultDataSourceError: Error, Sendable {
    case randomGenerationFailed
    case metadataTooLarge(actual: Int)
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
