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

// MARK: - Implementation Shell

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
        // TODO: Fetch from server, update local DB
        return try await localDatabase.fetchVaultItems()
    }

    func uploadItem(data: Data, name: String, type: VaultItem.VaultItemType) async throws
        -> VaultItem
    {
        SanchrLogger.media.info("Uploading vault item: \(name)")

        // TODO: 1. Encrypt data with AES-GCM
        // TODO: 2. Upload ciphertext to server
        // TODO: 3. Save metadata to local DB
        // TODO: 4. Return VaultItem

        let encrypted = try mediaEncryption.encrypt(data: data)
        _ = encrypted  // Suppress unused warning

        throw AppError.serverUnreachable
    }

    func downloadItem(id: String) async throws -> Data {
        SanchrLogger.media.info("Downloading vault item: \(id)")

        // TODO: 1. Fetch ciphertext from server
        // TODO: 2. Retrieve encryption key from local DB
        // TODO: 3. Decrypt and return plaintext

        throw AppError.serverUnreachable
    }

    func deleteItem(id: String) async throws {
        // TODO: Delete from server and local DB
        try await localDatabase.deleteVaultItem(id: id)
    }

    func storageUsed() async throws -> Int64 {
        let items = try await localDatabase.fetchVaultItems()
        return items.reduce(0) { $0 + $1.sizeBytes }
    }
}
