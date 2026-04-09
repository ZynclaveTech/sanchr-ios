import Foundation
import SanchrShared

/// Abstraction over the vault fetching use case so `VaultSource` can be
/// tested without spinning up the real data source / encryption pipeline.
///
/// Returns a flat list of already-decrypted `VaultItem`s plus the opaque
/// pagination cursor. Sealed items are filtered out by the underlying use
/// case.
protocol VaultItemsLoading: Sendable {
    func execute(
        limit: Int32,
        cursor: String
    ) async throws -> VaultUseCases.GetVaultItems.Result
}

/// Thin adapter over `VaultUseCases.GetVaultItems` for the attachment picker.
/// Does NOT duplicate fetching/decryption logic — it only narrows the API to
/// what the picker needs (a flat list of items for display).
///
/// Client-side filtering by media type is applied in `load(filter:)` because
/// the server-side vault API no longer supports a `filter` parameter
/// (metadata is encrypted client-side; the server can't filter on name or
/// mime type).
final class VaultSource: Sendable {
    private let getVaultItems: VaultItemsLoading

    init(getVaultItems: VaultItemsLoading) {
        self.getVaultItems = getVaultItems
    }

    func loadAll() async throws -> [VaultItem] {
        try await getVaultItems.execute(limit: 100, cursor: "").items
    }

    /// Loads a page of vault items and applies a client-side filter by
    /// `VaultItem.type` raw value. An empty or unknown filter returns all.
    func load(filter: String) async throws -> [VaultItem] {
        let items = try await getVaultItems.execute(limit: 100, cursor: "").items
        switch filter {
        case "photo": return items.filter { $0.type == .photo }
        case "video": return items.filter { $0.type == .video }
        case "audio": return items.filter { $0.type == .audio }
        case "file", "document": return items.filter { $0.type == .document }
        case "note": return items.filter { $0.type == .note }
        default: return items
        }
    }
}

extension VaultUseCases.GetVaultItems: VaultItemsLoading {}
