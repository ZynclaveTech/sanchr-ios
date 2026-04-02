import Foundation

/// Domain use cases for vault operations.
enum VaultUseCases {

    /// Fetches all vault items.
    struct FetchItems: Sendable {
        private let vaultRepository: VaultRepositoryProtocol

        init(vaultRepository: VaultRepositoryProtocol) {
            self.vaultRepository = vaultRepository
        }

        func execute() async throws -> [VaultItem] {
            try await vaultRepository.fetchItems()
        }
    }

    /// Downloads and decrypts a vault item.
    struct DownloadItem: Sendable {
        private let vaultRepository: VaultRepositoryProtocol

        init(vaultRepository: VaultRepositoryProtocol) {
            self.vaultRepository = vaultRepository
        }

        func execute(itemId: String) async throws -> Data {
            try await vaultRepository.downloadItem(id: itemId)
        }
    }
}
