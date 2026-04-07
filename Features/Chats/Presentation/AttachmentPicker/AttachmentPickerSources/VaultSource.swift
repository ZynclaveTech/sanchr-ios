import Foundation

/// Abstraction over the vault fetching use case so VaultSource can be tested
/// without spinning up the real data source / encryption pipeline.
protocol VaultItemsLoading: Sendable {
    func execute(
        filter: String,
        limit: Int32,
        cursor: String
    ) async throws -> (items: [VaultItem], totalPhotos: Int32, totalVideos: Int32, totalFiles: Int32)
}

/// Thin adapter over `VaultUseCases.GetVaultItems` for the attachment picker.
/// Does NOT duplicate fetching/encryption logic — it only narrows the API to
/// what the picker needs (a flat list of items for a given filter).
final class VaultSource: Sendable {
    private let getVaultItems: VaultItemsLoading

    init(getVaultItems: VaultItemsLoading) {
        self.getVaultItems = getVaultItems
    }

    func loadAll() async throws -> [VaultItem] {
        try await getVaultItems.execute(filter: "all", limit: 100, cursor: "").items
    }

    func load(filter: String) async throws -> [VaultItem] {
        try await getVaultItems.execute(filter: filter, limit: 100, cursor: "").items
    }
}

extension VaultUseCases.GetVaultItems: VaultItemsLoading {}
