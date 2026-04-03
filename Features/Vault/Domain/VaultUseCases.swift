import Foundation
import UIKit

/// Domain use cases for vault operations.
enum VaultUseCases {

    /// Fetches vault items with filter and pagination support.
    struct GetVaultItems: Sendable {
        private let vaultDataSource: VaultDataSource

        init(vaultDataSource: VaultDataSource) {
            self.vaultDataSource = vaultDataSource
        }

        /// Fetches vault items with the given filter and cursor for pagination.
        func execute(
            filter: String = "all",
            limit: Int32 = 20,
            cursor: String = ""
        ) async throws -> (items: [VaultItem], totalPhotos: Int32, totalVideos: Int32, totalFiles: Int32) {
            let response = try await vaultDataSource.getVaultItems(
                filter: filter,
                limit: limit,
                cursor: cursor
            )

            let items = response.items.map(Self.mapToVaultItem)

            return (
                items: items,
                totalPhotos: response.totalPhotos,
                totalVideos: response.totalVideos,
                totalFiles: response.totalFiles
            )
        }

        /// Maps a gRPC VaultItem to the domain VaultItem model.
        static func mapToVaultItem(_ proto: Vync_Vault_VaultItem) -> VaultItem {
            let type: VaultItem.VaultItemType = {
                switch proto.mediaType {
                case "photo": return .photo
                case "video": return .video
                case "file": return .document
                default: return .document
                }
            }()

            return VaultItem(
                id: proto.itemID,
                name: proto.fileName,
                type: type,
                sizeBytes: proto.fileSize,
                encryptionKey: proto.encryptedKey,
                encryptionIV: Data(),
                thumbnailData: nil,
                createdAt: Date(timeIntervalSince1970: TimeInterval(proto.createdAt)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(proto.createdAt)),
                isCachedLocally: false,
                remoteURL: URL(string: proto.encryptedURL),
                localURL: nil
            )
        }
    }

    /// Uploads an encrypted item to the vault.
    /// Pipeline: pick media -> encrypt with AES-GCM -> get presigned URL -> upload -> create vault item.
    struct UploadToVault: Sendable {
        private let vaultDataSource: VaultDataSource
        private let mediaManager: MediaManagerProtocol

        init(vaultDataSource: VaultDataSource, mediaManager: MediaManagerProtocol) {
            self.vaultDataSource = vaultDataSource
            self.mediaManager = mediaManager
        }

        /// Compresses (if needed), encrypts, and uploads to vault.
        func execute(
            data: Data,
            fileName: String,
            mediaType: String,
            senderID: String,
            ttlSeconds: Int64 = 0
        ) async throws -> VaultItem {
            var processedData = data

            // Compress images before encrypting
            if mediaType == "photo", let image = UIImage(data: data) {
                processedData = try await mediaManager.compressImage(image, maxSizeKB: 2048)
            }

            let protoItem = try await vaultDataSource.createVaultItem(
                data: processedData,
                fileName: fileName,
                mediaType: mediaType,
                senderID: senderID,
                ttlSeconds: ttlSeconds
            )

            return GetVaultItems.mapToVaultItem(protoItem)
        }
    }

    /// Shares a vault item with another user by re-encrypting the media key.
    struct ShareVaultItem: Sendable {
        private let vaultDataSource: VaultDataSource

        init(vaultDataSource: VaultDataSource) {
            self.vaultDataSource = vaultDataSource
        }

        /// Re-encrypts the media key for the recipient's public key and calls ShareVaultItem.
        func execute(
            itemId: String,
            recipientId: String,
            reEncryptedKey: String
        ) async throws {
            try await vaultDataSource.shareVaultItem(
                itemId: itemId,
                recipientId: recipientId,
                reEncryptedKey: reEncryptedKey
            )
        }
    }

    /// Deletes a vault item from both server and local cache.
    struct DeleteVaultItem: Sendable {
        private let vaultDataSource: VaultDataSource
        private let localDatabase: LocalDatabaseProtocol

        init(vaultDataSource: VaultDataSource, localDatabase: LocalDatabaseProtocol) {
            self.vaultDataSource = vaultDataSource
            self.localDatabase = localDatabase
        }

        func execute(itemId: String) async throws {
            // Delete from server first
            try await vaultDataSource.deleteVaultItem(itemId: itemId)
            // Then delete from local cache
            try? await localDatabase.deleteVaultItem(id: itemId)
        }
    }
}
