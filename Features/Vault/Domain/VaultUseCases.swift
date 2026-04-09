import AVFoundation
import Foundation
import UIKit
import SanchrShared

/// Domain use cases for vault operations.
///
/// These thin wrappers cover the user-driven vault browser flows:
///   - list items (paginated)
///   - upload an item (manual path)
///   - delete an item
///
/// Each use case decrypts metadata locally using `AccessKeyStore` and never
/// exposes ciphertext or raw proto types above the use case boundary.
///
/// Sharing was removed intentionally — the forward-secure vault design does
/// not support key re-wrapping; the UX for outbound sharing is deferred.
enum VaultUseCases {

    // MARK: - Get

    /// Fetches a paginated slice of vault items. Sealed items (whose
    /// `AccessK_vault` is unavailable on this device) are filtered out.
    struct GetVaultItems: Sendable {
        private let vaultDataSource: VaultDataSource
        private let accessKeyStore: AccessKeyStoreProtocol
        private let mediaEncryption: MediaEncryptionProtocol

        init(
            vaultDataSource: VaultDataSource,
            accessKeyStore: AccessKeyStoreProtocol,
            mediaEncryption: MediaEncryptionProtocol
        ) {
            self.vaultDataSource = vaultDataSource
            self.accessKeyStore = accessKeyStore
            self.mediaEncryption = mediaEncryption
        }

        struct Result: Sendable {
            let items: [VaultItem]
            let nextCursor: String
        }

        func execute(
            limit: Int32 = 20,
            cursor: String = ""
        ) async throws -> Result {
            let response = try await vaultDataSource.getVaultItems(limit: limit, cursor: cursor)
            var items: [VaultItem] = []
            for protoItem in response.items {
                if let item = try await decryptToItem(protoItem) {
                    items.append(item)
                }
            }
            return Result(items: items, nextCursor: response.nextCursor)
        }

        private func decryptToItem(_ proto: Vync_Vault_VaultItem) async throws -> VaultItem? {
            let vaultItemId = proto.vaultItemID
            guard let accessKey = try await accessKeyStore.retrieve(mediaId: vaultItemId) else {
                return nil  // sealed — hidden from UI list
            }
            let metadataJson = try mediaEncryption.decrypt(
                ciphertext: proto.encryptedMetadata,
                key: accessKey,
                iv: Data()
            )
            let metadata = try JSONDecoder().decode(VaultItemMetadata.self, from: metadataJson)
            return VaultItem(
                id: vaultItemId,
                mediaId: proto.mediaID,
                name: metadata.name,
                type: Self.vaultItemType(fromMimeType: metadata.mimeType),
                sizeBytes: metadata.sizeBytes,
                thumbnailData: metadata.thumbnailJpeg,
                createdAt: Date(timeIntervalSince1970: TimeInterval(proto.createdAt) / 1000.0),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(proto.createdAt) / 1000.0),
                isCachedLocally: false,
                status: .live
            )
        }

        private static func vaultItemType(fromMimeType mime: String) -> VaultItem.VaultItemType {
            if mime.hasPrefix("image/") { return .photo }
            if mime.hasPrefix("video/") { return .video }
            if mime.hasPrefix("audio/") { return .audio }
            if mime == "text/plain" { return .note }
            return .document
        }
    }

    // MARK: - Upload

    /// Compresses (if needed), encrypts, and uploads an item to the vault via
    /// the manual path. Generates a preview thumbnail locally so the vault
    /// browser has an immediate render post-upload.
    struct UploadToVault: Sendable {
        private let vaultDataSource: VaultDataSource
        private let mediaManager: MediaManagerProtocol

        init(vaultDataSource: VaultDataSource, mediaManager: MediaManagerProtocol) {
            self.vaultDataSource = vaultDataSource
            self.mediaManager = mediaManager
        }

        func execute(
            data: Data,
            fileName: String,
            mediaType: String,
            onProgress: (@Sendable (Double) -> Void)? = nil
        ) async throws -> VaultItem {
            var processedData = data
            var thumbnail: Data?

            if mediaType == "photo", let image = UIImage(data: data) {
                processedData = try await mediaManager.compressImage(image, maxSizeKB: 2048)
                thumbnail = image
                    .preparingThumbnail(of: CGSize(width: 300, height: 300))?
                    .jpegData(compressionQuality: 0.6)
            } else if mediaType == "video" {
                thumbnail = Self.generateVideoThumbnail(from: data)
            } else if mediaType == "file" || mediaType == "document" {
                thumbnail = Self.generateDocumentThumbnail(from: data, fileName: fileName)
            }

            let (proto, metadata) = try await vaultDataSource.createVaultItem(
                data: processedData,
                fileName: fileName,
                mediaType: mediaType,
                thumbnailData: thumbnail,
                onProgress: onProgress
            )

            return VaultItem(
                id: proto.vaultItemID,
                mediaId: proto.mediaID,
                name: metadata.name,
                type: Self.vaultItemType(fromMimeType: metadata.mimeType),
                sizeBytes: metadata.sizeBytes,
                thumbnailData: thumbnail ?? metadata.thumbnailJpeg,
                createdAt: Date(timeIntervalSince1970: TimeInterval(proto.createdAt) / 1000.0),
                updatedAt: Date(),
                isCachedLocally: false,
                status: .live
            )
        }

        private static func vaultItemType(fromMimeType mime: String) -> VaultItem.VaultItemType {
            if mime.hasPrefix("image/") { return .photo }
            if mime.hasPrefix("video/") { return .video }
            if mime.hasPrefix("audio/") { return .audio }
            if mime == "text/plain" { return .note }
            return .document
        }

        /// Extracts the first frame from video data as a JPEG thumbnail.
        private static func generateVideoThumbnail(from data: Data) -> Data? {
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mp4")
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

        /// Generates a thumbnail for document files (PDFs get first-page
        /// render, image-typed documents get preparingThumbnail).
        private static func generateDocumentThumbnail(from data: Data, fileName: String) -> Data? {
            let ext = (fileName as NSString).pathExtension.lowercased()

            // PDF: render the first page
            if ext == "pdf" {
                return generatePDFThumbnail(from: data)
            }

            // Image files uploaded as "file" type
            let imageExtensions = ["png", "tiff", "tif", "bmp", "heic", "heif", "gif", "webp"]
            if imageExtensions.contains(ext), let image = UIImage(data: data) {
                return image
                    .preparingThumbnail(of: CGSize(width: 300, height: 300))?
                    .jpegData(compressionQuality: 0.6)
            }

            return nil
        }

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

    // MARK: - Delete

    /// Deletes a vault item from both the server and the local cache.
    /// Leaves the access-key entry in `AccessKeyStore` — it's useless without
    /// a matching server row and the sliding TTL reaps it.
    struct DeleteVaultItem: Sendable {
        private let vaultDataSource: VaultDataSource
        private let localDatabase: LocalDatabaseProtocol

        init(vaultDataSource: VaultDataSource, localDatabase: LocalDatabaseProtocol) {
            self.vaultDataSource = vaultDataSource
            self.localDatabase = localDatabase
        }

        func execute(vaultItemId: String) async throws {
            try await vaultDataSource.deleteVaultItem(vaultItemId: vaultItemId)
            try? await localDatabase.deleteVaultItem(id: vaultItemId)
        }
    }
}
