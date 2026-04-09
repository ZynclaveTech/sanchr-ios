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
        // 32-byte salt via CryptoKit. Matches the canonical pattern in
        // MediaEncryptor.generateMediaKey() and is guaranteed to succeed;
        // the old SecRandomCopyBytes path occasionally surfaced as an
        // opaque "error 0" on real devices and was never the right
        // abstraction level for this codebase.
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }

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
        let presigned: Vync_Media_PresignedUrlResponse
        do {
            presigned = try await mediaClient.getUploadUrl(uploadReq)
        } catch {
            SanchrLogger.media.error(
                "VaultDataSource: getUploadUrl failed for \(vaultItemId.prefix(8)): \(error.localizedDescription)"
            )
            throw VaultDataSourceError.uploadURLRequestFailed(underlying: error.localizedDescription)
        }

        onProgress?(0.1)

        // 5. PUT the ciphertext to S3 via presigned URL.
        do {
            try await Self.uploadToS3(
                data: ciphertext,
                url: presigned.url,
                contentType: contentType
            ) { fraction in
                onProgress?(0.1 + fraction * 0.8)
            }
        } catch let VaultDataSourceError.s3UploadFailed(statusCode, underlying) {
            SanchrLogger.media.error(
                "VaultDataSource: S3 upload failed for \(vaultItemId.prefix(8)): status=\(statusCode ?? -1) \(underlying ?? "")"
            )
            throw VaultDataSourceError.s3UploadFailed(statusCode: statusCode, underlying: underlying)
        } catch {
            SanchrLogger.media.error(
                "VaultDataSource: S3 upload failed for \(vaultItemId.prefix(8)): \(error.localizedDescription)"
            )
            throw VaultDataSourceError.s3UploadFailed(statusCode: nil, underlying: error.localizedDescription)
        }

        // 6. Confirm upload with the media service.
        var confirmReq = Vync_Media_ConfirmUploadRequest()
        confirmReq.mediaID = presigned.mediaID
        confirmReq.fileSize = Int64(ciphertext.count)
        do {
            _ = try await mediaClient.confirmUpload(confirmReq)
        } catch {
            SanchrLogger.media.error(
                "VaultDataSource: confirmUpload failed for \(vaultItemId.prefix(8)): \(error.localizedDescription)"
            )
            throw VaultDataSourceError.confirmUploadFailed(underlying: error.localizedDescription)
        }

        onProgress?(0.95)

        // 7. Build and encrypt the metadata envelope.
        //
        // Defensive truncation: a 4 KiB filename cap is overkill for human
        // typing but catches pathological cases where a document picker
        // returns an encoded opaque identifier as the last path component.
        // Keeping the original extension is critical for the UI.
        let safeFileName = Self.truncateFileName(fileName, maxBytes: 4 * 1024)

        // Thumbnail cap: 48 KiB raw. Combined with a safe filename we stay
        // comfortably under the server's 64 KiB metadata ceiling even with
        // base64 overhead in the JSON encoding.
        let safeThumbnail = Self.capThumbnail(thumbnailData, maxBytes: 48 * 1024)

        let metadata = VaultItemMetadata(
            name: safeFileName,
            mimeType: contentType,
            sizeBytes: Int64(data.count),
            thumbnailJpeg: safeThumbnail,
            originalSenderId: nil,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            kind: AccessKeyEntry.Kind.vaultManual.rawValue
        )
        let metadataJson = try JSONEncoder().encode(metadata)
        if metadataJson.count > 64 * 1024 {
            // Diagnostic: log per-field byte sizes so the next failure
            // tells us which field bloated the envelope. Pre-fix user
            // reports saw 130 KiB for a PDF via fileImporter, which is
            // theoretically impossible with this struct shape — the log
            // will catch whatever weird iOS behavior produced it.
            let nameBytes = safeFileName.data(using: .utf8)?.count ?? -1
            let mimeBytes = contentType.utf8.count
            let thumbBytes = safeThumbnail?.count ?? 0
            SanchrLogger.media.error(
                "VaultDataSource: metadata too large: total=\(metadataJson.count) name=\(nameBytes) mime=\(mimeBytes) thumbnail=\(thumbBytes) fileName=\(safeFileName.prefix(80))"
            )
            throw VaultDataSourceError.metadataTooLarge(actual: metadataJson.count)
        }
        let encryptedMetadata: Data
        do {
            encryptedMetadata = try mediaEncryption.encrypt(
                data: metadataJson,
                withKey: accessKey
            )
        } catch {
            throw VaultDataSourceError.metadataEncryptionFailed(underlying: error.localizedDescription)
        }

        // 8. Create the vault item row on the server.
        var createReq = Vync_Vault_CreateVaultItemRequest()
        createReq.vaultItemID = vaultItemId
        createReq.mediaID = presigned.mediaID
        createReq.encryptedMetadata = encryptedMetadata
        createReq.expiresAt = expiresAt

        SanchrLogger.network.info(
            "VaultDataSource: createVaultItem \(vaultItemId.prefix(8))..."
        )
        let vaultProto: Vync_Vault_VaultItem
        do {
            vaultProto = try await vaultClient.createVaultItem(createReq)
        } catch {
            SanchrLogger.network.error(
                "VaultDataSource: createVaultItem server call failed for \(vaultItemId.prefix(8)): \(error.localizedDescription)"
            )
            throw VaultDataSourceError.createVaultItemFailed(underlying: error.localizedDescription)
        }

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

    /// Trims a filename to at most `maxBytes` UTF-8 bytes while preserving
    /// the file extension. Document pickers in some apps return encoded
    /// opaque identifiers as the last path component; this catches those
    /// and ensures the metadata envelope stays well under the 64 KiB cap.
    private static func truncateFileName(_ fileName: String, maxBytes: Int) -> String {
        guard fileName.utf8.count > maxBytes else { return fileName }

        let fileExtension: String
        let stem: String
        if let dotIndex = fileName.lastIndex(of: ".") {
            fileExtension = String(fileName[dotIndex...])
            stem = String(fileName[..<dotIndex])
        } else {
            fileExtension = ""
            stem = fileName
        }

        // Reserve bytes for the extension and the truncation marker.
        let marker = "…"
        let reserved = fileExtension.utf8.count + marker.utf8.count
        let stemBudget = max(16, maxBytes - reserved)

        var truncatedStem = ""
        var used = 0
        for scalar in stem.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            if used + scalarBytes > stemBudget { break }
            truncatedStem.unicodeScalars.append(scalar)
            used += scalarBytes
        }

        return truncatedStem + marker + fileExtension
    }

    /// Caps a raw thumbnail blob at `maxBytes`. If the thumbnail is larger,
    /// drops it entirely (better to have no thumbnail than to overflow the
    /// server's metadata ceiling). JPEG base64 encoding adds ~33% overhead
    /// so a 48 KiB raw cap yields a ~64 KiB JSON field before the rest of
    /// the envelope.
    private static func capThumbnail(_ thumbnail: Data?, maxBytes: Int) -> Data? {
        guard let thumbnail else { return nil }
        return thumbnail.count <= maxBytes ? thumbnail : nil
    }

    private static func uploadToS3(
        data: Data,
        url: String,
        contentType: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard let uploadURL = URL(string: url) else {
            throw VaultDataSourceError.s3UploadFailed(statusCode: nil, underlying: "invalid presigned URL")
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")

        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let response: URLResponse
        do {
            (_, response) = try await session.upload(for: request, from: data)
        } catch {
            throw VaultDataSourceError.s3UploadFailed(statusCode: nil, underlying: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw VaultDataSourceError.s3UploadFailed(statusCode: nil, underlying: "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            SanchrLogger.media.error("S3 upload failed with HTTP \(http.statusCode)")
            throw VaultDataSourceError.s3UploadFailed(statusCode: http.statusCode, underlying: nil)
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

enum VaultDataSourceError: LocalizedError, Sendable {
    case randomGenerationFailed
    case metadataTooLarge(actual: Int)
    case uploadURLRequestFailed(underlying: String)
    case s3UploadFailed(statusCode: Int?, underlying: String?)
    case confirmUploadFailed(underlying: String)
    case createVaultItemFailed(underlying: String)
    case metadataEncryptionFailed(underlying: String)

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed:
            return "Couldn't generate a secure random salt. Please try again."
        case .metadataTooLarge(let actual):
            let limit = 64 * 1024
            return "File metadata is too large (\(actual) bytes > \(limit) bytes). Try a shorter filename or a smaller thumbnail."
        case .uploadURLRequestFailed(let underlying):
            return "Couldn't get an upload URL from the server: \(underlying)"
        case .s3UploadFailed(let statusCode, let underlying):
            if let code = statusCode {
                return "Upload to storage failed (HTTP \(code))."
            }
            return "Upload to storage failed: \(underlying ?? "network error")"
        case .confirmUploadFailed(let underlying):
            return "Server failed to confirm the upload: \(underlying)"
        case .createVaultItemFailed(let underlying):
            return "Server rejected the vault item: \(underlying)"
        case .metadataEncryptionFailed(let underlying):
            return "Couldn't encrypt file metadata: \(underlying)"
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
