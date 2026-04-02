import Foundation
import UIKit

/// Use case for creating and uploading an encrypted vault item.
struct CreateVaultItemUseCase: Sendable {
    private let vaultRepository: VaultRepositoryProtocol
    private let mediaManager: MediaManagerProtocol

    init(vaultRepository: VaultRepositoryProtocol, mediaManager: MediaManagerProtocol) {
        self.vaultRepository = vaultRepository
        self.mediaManager = mediaManager
    }

    /// Compresses (if needed), encrypts, and uploads a vault item.
    func execute(data: Data, name: String, type: VaultItem.VaultItemType) async throws -> VaultItem {
        SanchrLogger.media.info("Creating vault item: \(name) (\(type.rawValue))")

        var processedData = data

        // Compress images before encrypting
        if type == .photo, let image = UIImage(data: data) {
            processedData = try await mediaManager.compressImage(image, maxSizeKB: 2048)
        }

        // Upload via repository (handles encryption)
        return try await vaultRepository.uploadItem(
            data: processedData,
            name: name,
            type: type
        )
    }
}
