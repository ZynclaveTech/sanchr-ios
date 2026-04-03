import AVFoundation
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
        ) async throws -> (
            items: [VaultItem], totalPhotos: Int32, totalVideos: Int32, totalFiles: Int32
        ) {
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
                encryptedThumbnailURL: proto.thumbnailURL.isEmpty ? nil : URL(string: proto.thumbnailURL),
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
            ttlSeconds: Int64 = 0,
            onProgress: (@Sendable (Double) -> Void)? = nil
        ) async throws -> VaultItem {
            var processedData = data
            var thumbnail: Data?

            if mediaType == "photo", let image = UIImage(data: data) {
                // Compress and generate thumbnail
                processedData = try await mediaManager.compressImage(image, maxSizeKB: 2048)
                thumbnail = image
                    .preparingThumbnail(of: CGSize(width: 300, height: 300))?
                    .jpegData(compressionQuality: 0.6)
            } else if mediaType == "video" {
                thumbnail = Self.generateVideoThumbnail(from: data)
            } else if mediaType == "file" {
                thumbnail = Self.generateDocumentThumbnail(from: data, fileName: fileName)
            }

            let protoItem = try await vaultDataSource.createVaultItem(
                data: processedData,
                fileName: fileName,
                mediaType: mediaType,
                senderID: senderID,
                ttlSeconds: ttlSeconds,
                thumbnailData: thumbnail,
                onProgress: onProgress
            )

            var item = GetVaultItems.mapToVaultItem(protoItem)
            // Cache the plaintext thumbnail locally so it's instant on this device
            item.thumbnailData = thumbnail
            return item
        }

        /// Extracts the first frame from video data as a JPEG thumbnail.
        private static func generateVideoThumbnail(from data: Data) -> Data? {
            let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            defer { try? FileManager.default.removeItem(at: tmpURL) }
            do {
                try data.write(to: tmpURL)
                let asset = AVAsset(url: tmpURL)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 300, height: 300)
                let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
                return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.6)
            } catch {
                return nil
            }
        }

        /// Generates a thumbnail for document files (PDFs get first-page render, images inside docs, etc).
        private static func generateDocumentThumbnail(from data: Data, fileName: String) -> Data? {
            let ext = (fileName as NSString).pathExtension.lowercased()

            // PDF: render the first page
            if ext == "pdf" {
                return generatePDFThumbnail(from: data)
            }

            // Image files uploaded as "file" type (e.g. PNG, TIFF, BMP, HEIC)
            let imageExtensions = ["png", "tiff", "tif", "bmp", "heic", "heif", "gif", "webp"]
            if imageExtensions.contains(ext), let image = UIImage(data: data) {
                return image
                    .preparingThumbnail(of: CGSize(width: 300, height: 300))?
                    .jpegData(compressionQuality: 0.6)
            }

            // Other file types: no thumbnail (will show type icon)
            return nil
        }

        /// Renders the first page of a PDF as a JPEG thumbnail.
        private static func generatePDFThumbnail(from data: Data) -> Data? {
            guard let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider),
                  let page = document.page(at: 1) else { return nil }

            let pageRect = page.getBoxRect(.mediaBox)
            let scale: CGFloat = 300.0 / max(pageRect.width, pageRect.height)
            let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)

            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))

                ctx.cgContext.translateBy(x: 0, y: size.height)
                ctx.cgContext.scaleBy(x: scale, y: -scale)
                ctx.cgContext.drawPDFPage(page)
            }
            return image.jpegData(compressionQuality: 0.7)
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
