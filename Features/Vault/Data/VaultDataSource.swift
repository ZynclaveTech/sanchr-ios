import Foundation

/// Data source for vault-related gRPC service calls.
final class VaultDataSource: @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    // TODO: Implement when proto-generated stubs are available
    //
    // func fetchItems() async throws -> [VaultItemResponse] { ... }
    // func uploadItem(encryptedData: Data, metadata: VaultItemMetadata) async throws -> VaultItemResponse { ... }
    // func downloadItem(itemId: String) async throws -> Data { ... }
    // func deleteItem(itemId: String) async throws { ... }
}
