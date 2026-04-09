import CryptoKit
import Foundation
import SanchrShared

/// Repository for the forward-secure vault.
///
/// This is the boundary used by the background-sync path (`SyncOrchestrator`),
/// the auto-vault path (`MessageRepository.routeIncomingMessageToVault`), and
/// `CreateVaultItemUseCase`. User-driven vault-view actions (upload from the
/// vault browser, delete from the vault browser) go through `VaultUseCases` +
/// `VaultDataSource` directly, NOT through this repository.
///
/// The repository's job:
/// - `fetchItems()`: hit the server, decrypt each item's metadata envelope
///   using the locally-stored AccessK_vault, return `[VaultItem]` for local
///   cache population. Sealed items (cross-device backup restore) are
///   persisted as sealed stubs but excluded from the returned list.
/// - `uploadItem(...)`: delegates to `VaultDataSource.createVaultItem` so the
///   manual and auto-vault paths share the same encryption and AccessKeyStore
///   wiring.
/// - `downloadItem(id:)`: fetch ciphertext from S3, decrypt with
///   AccessK_vault. Held inside `VaultEKFScheduler.withAccess { }` so the
///   background purge cannot race with a live decrypt.
/// - `deleteItem(id:)`: delete on server + local DB. The access key entry is
///   left in AccessKeyStore; it's useless without the matching server item
///   and the 30-day sliding TTL will reap it in due course.
/// - `storageUsed()`: sum of `sizeBytes` from the local cache.
protocol VaultRepositoryProtocol: AnyObject, Sendable {
    /// Fetches all live vault items from the server, decrypts metadata, and
    /// caches locally.
    func fetchItems() async throws -> [VaultItem]

    /// Uploads a new vault item via the manual upload path. The data is
    /// encrypted client-side with a freshly-derived AccessK_vault and the
    /// key is stored in `AccessKeyStore` keyed by the new vault_item_id.
    func uploadItem(data: Data, name: String, type: VaultItem.VaultItemType) async throws
        -> VaultItem

    /// Downloads and decrypts a vault item's ciphertext by its vault_item_id.
    func downloadItem(id: String) async throws -> Data

    /// Deletes a vault item from the server and the local cache.
    func deleteItem(id: String) async throws

    /// Returns total bytes stored in live vault items (local cache).
    func storageUsed() async throws -> Int64
}

// MARK: - Implementation

final class VaultRepositoryImpl: VaultRepositoryProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol
    private let localDatabase: LocalDatabaseProtocol
    private let accessKeyStore: AccessKeyStoreProtocol
    private let mediaEncryption: MediaEncryptionProtocol
    private let vaultDataSource: VaultDataSource
    private let ekfScheduler: VaultEKFScheduler

    init(
        grpcClient: GRPCClientProtocol,
        localDatabase: LocalDatabaseProtocol,
        accessKeyStore: AccessKeyStoreProtocol,
        mediaEncryption: MediaEncryptionProtocol,
        vaultDataSource: VaultDataSource,
        ekfScheduler: VaultEKFScheduler
    ) {
        self.grpcClient = grpcClient
        self.localDatabase = localDatabase
        self.accessKeyStore = accessKeyStore
        self.mediaEncryption = mediaEncryption
        self.vaultDataSource = vaultDataSource
        self.ekfScheduler = ekfScheduler
    }

    // MARK: - Fetch

    func fetchItems() async throws -> [VaultItem] {
        SanchrLogger.media.info("Fetching vault items from server")

        var allItems: [VaultItem] = []
        var cursor = ""
        repeat {
            let response = try await vaultDataSource.getVaultItems(limit: 100, cursor: cursor)
            for protoItem in response.items {
                if let item = try await decryptToItem(protoItem) {
                    allItems.append(item)
                }
            }
            cursor = response.nextCursor
        } while !cursor.isEmpty

        // Cache live items locally. Sealed items were already persisted by
        // `decryptToItem` as a side effect.
        for item in allItems where item.status == .live {
            try? await localDatabase.saveVaultItem(item)
        }

        let liveItems = allItems.filter { $0.status == .live }
        SanchrLogger.media.info(
            "Fetched \(liveItems.count) live vault items (\(allItems.count - liveItems.count) sealed)"
        )
        return liveItems
    }

    // MARK: - Upload

    func uploadItem(data: Data, name: String, type: VaultItem.VaultItemType) async throws
        -> VaultItem
    {
        SanchrLogger.media.info("Uploading vault item via manual path: \(name)")

        let mediaType = Self.mediaTypeString(for: type)
        let (proto, metadata) = try await vaultDataSource.createVaultItem(
            data: data,
            fileName: name,
            mediaType: mediaType
        )

        let item = VaultItem(
            id: proto.vaultItemID,
            mediaId: proto.mediaID,
            name: metadata.name,
            type: type,
            sizeBytes: metadata.sizeBytes,
            thumbnailData: metadata.thumbnailJpeg,
            createdAt: Date(timeIntervalSince1970: TimeInterval(proto.createdAt) / 1000.0),
            updatedAt: Date(),
            isCachedLocally: false,
            status: .live
        )
        try await localDatabase.saveVaultItem(item)
        return item
    }

    // MARK: - Download

    func downloadItem(id: String) async throws -> Data {
        SanchrLogger.media.info("Downloading vault item: \(id.prefix(8))...")

        // Hold the EKF access lock for the duration of the decrypt so a
        // scheduled purge cannot race.
        return try await ekfScheduler.withAccess {
            // 1. Look up AccessK_vault (bumps sliding TTL).
            guard let accessKey = try await self.accessKeyStore.getAndTouch(mediaId: id) else {
                throw AppError.decryptionFailed(reason: "No access key for vault item \(id)")
            }

            // 2. Get the item's mediaId. Prefer the local cache; fall back to
            //    a server point-lookup if missing.
            let cachedItems = try await self.localDatabase.fetchAllVaultItems()
            let mediaId: String
            if let cached = cachedItems.first(where: { $0.id == id }), !cached.mediaId.isEmpty {
                mediaId = cached.mediaId
            } else {
                let fresh = try await self.vaultDataSource.getVaultItem(vaultItemId: id)
                mediaId = fresh.mediaID
            }

            // 3. Presigned download URL.
            var downloadReq = Vync_Media_GetDownloadUrlRequest()
            downloadReq.mediaID = mediaId
            let presigned = try await self.grpcClient.mediaService.getDownloadUrl(downloadReq)

            // 4. Download ciphertext from S3.
            guard let downloadURL = URL(string: presigned.url) else {
                throw AppError.mediaDownloadFailed
            }
            let (ciphertext, response) = try await URLSession.shared.data(from: downloadURL)
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else {
                throw AppError.mediaDownloadFailed
            }

            // 5. Decrypt with AccessK_vault. The iv parameter is ignored by
            //    the MediaEncryptor (sealed-box combined form carries its
            //    own nonce).
            let plaintext = try self.mediaEncryption.decrypt(
                ciphertext: ciphertext,
                key: accessKey,
                iv: Data()
            )
            SanchrLogger.media.info(
                "Vault item downloaded and decrypted: \(plaintext.count) bytes"
            )
            return plaintext
        }
    }

    // MARK: - Delete

    func deleteItem(id: String) async throws {
        SanchrLogger.media.info("Deleting vault item: \(id.prefix(8))...")

        // Delete on server first. If that succeeds, clean up local state.
        try await vaultDataSource.deleteVaultItem(vaultItemId: id)
        try await localDatabase.deleteVaultItem(id: id)
        // Access key entry is left in the store — it's useless without a
        // matching server row, and the 30-day sliding TTL will reap it.
    }

    // MARK: - Storage

    func storageUsed() async throws -> Int64 {
        let items = try await localDatabase.fetchVaultItems()
        return items.reduce(0) { $0 + $1.sizeBytes }
    }

    // MARK: - Private helpers

    /// Decrypts a single proto item's metadata envelope and returns a domain
    /// `VaultItem`. Persists a sealed stub (and returns it so the caller can
    /// filter on `.status`) if the AccessK_vault is missing.
    private func decryptToItem(_ proto: Vync_Vault_VaultItem) async throws -> VaultItem? {
        let vaultItemId = proto.vaultItemID

        guard let accessKey = try await accessKeyStore.retrieve(mediaId: vaultItemId) else {
            // Sealed item: persist a stub so forensic/restore tooling can
            // reason about it via fetchAllVaultItems.
            let sealedStub = VaultItem(
                id: vaultItemId,
                mediaId: proto.mediaID,
                name: "",
                type: .document,
                sizeBytes: 0,
                createdAt: Date(timeIntervalSince1970: TimeInterval(proto.createdAt) / 1000.0),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(proto.createdAt) / 1000.0),
                isCachedLocally: false,
                status: .sealed
            )
            try? await localDatabase.saveVaultItem(sealedStub)
            return sealedStub  // caller filters by status
        }

        let metadataJson = try mediaEncryption.decrypt(
            ciphertext: proto.encryptedMetadata,
            key: accessKey,
            iv: Data()
        )
        let metadata = try JSONDecoder().decode(VaultItemMetadata.self, from: metadataJson)

        let type = Self.vaultItemType(fromMimeType: metadata.mimeType)
        return VaultItem(
            id: vaultItemId,
            mediaId: proto.mediaID,
            name: metadata.name,
            type: type,
            sizeBytes: metadata.sizeBytes,
            thumbnailData: metadata.thumbnailJpeg,
            createdAt: Date(timeIntervalSince1970: TimeInterval(proto.createdAt) / 1000.0),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(proto.createdAt) / 1000.0),
            isCachedLocally: false,
            status: .live
        )
    }

    private static func mediaTypeString(for type: VaultItem.VaultItemType) -> String {
        switch type {
        case .photo: return "photo"
        case .video: return "video"
        case .audio: return "audio"
        case .document: return "document"
        case .note: return "note"
        }
    }

    private static func vaultItemType(fromMimeType mime: String) -> VaultItem.VaultItemType {
        if mime.hasPrefix("image/") { return .photo }
        if mime.hasPrefix("video/") { return .video }
        if mime.hasPrefix("audio/") { return .audio }
        if mime == "text/plain" { return .note }
        return .document
    }
}
