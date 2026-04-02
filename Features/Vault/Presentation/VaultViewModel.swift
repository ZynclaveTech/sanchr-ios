import Foundation

/// View model for the vault screen.
@Observable
final class VaultViewModel {
    var items: [VaultItem] = []
    var isLoading: Bool = false
    var errorMessage: String?
    var storageUsed: Int64 = 0

    func loadItems(vaultRepository: VaultRepositoryProtocol) async {
        isLoading = true
        defer { isLoading = false }

        do {
            items = try await vaultRepository.fetchItems()
            storageUsed = try await vaultRepository.storageUsed()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteItem(_ item: VaultItem, vaultRepository: VaultRepositoryProtocol) async {
        do {
            try await vaultRepository.deleteItem(id: item.id)
            items.removeAll { $0.id == item.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var formattedStorageUsed: String {
        ByteCountFormatter.string(fromByteCount: storageUsed, countStyle: .file)
    }
}
