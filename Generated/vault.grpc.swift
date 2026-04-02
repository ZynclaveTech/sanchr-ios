import Foundation

// MARK: - vync.vault gRPC Client
// Generated from Proto/vault.proto — DO NOT EDIT

/// Client protocol for the VaultService gRPC service.
protocol Vync_Vault_VaultServiceClientProtocol: Sendable {
    /// Fetches vault items with optional filter and pagination.
    func getVaultItems(_ request: Vync_Vault_GetVaultItemsRequest) async throws -> Vync_Vault_GetVaultItemsResponse

    /// Creates a new vault item from an encrypted upload.
    func createVaultItem(_ request: Vync_Vault_CreateVaultItemRequest) async throws -> Vync_Vault_VaultItem

    /// Deletes a vault item by ID.
    func deleteVaultItem(_ request: Vync_Vault_DeleteVaultItemRequest) async throws -> Vync_Vault_DeleteVaultItemResponse

    /// Shares a vault item with another user by re-encrypting the key.
    func shareVaultItem(_ request: Vync_Vault_ShareVaultItemRequest) async throws -> Vync_Vault_ShareVaultItemResponse
}

/// Concrete gRPC client for VaultService.
final class Vync_Vault_VaultServiceClient: Vync_Vault_VaultServiceClientProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    func getVaultItems(_ request: Vync_Vault_GetVaultItemsRequest) async throws -> Vync_Vault_GetVaultItemsResponse {
        SanchrLogger.network.info("gRPC: VaultService/GetVaultItems")
        throw AppError.serverUnreachable
    }

    func createVaultItem(_ request: Vync_Vault_CreateVaultItemRequest) async throws -> Vync_Vault_VaultItem {
        SanchrLogger.network.info("gRPC: VaultService/CreateVaultItem")
        throw AppError.serverUnreachable
    }

    func deleteVaultItem(_ request: Vync_Vault_DeleteVaultItemRequest) async throws -> Vync_Vault_DeleteVaultItemResponse {
        SanchrLogger.network.info("gRPC: VaultService/DeleteVaultItem")
        throw AppError.serverUnreachable
    }

    func shareVaultItem(_ request: Vync_Vault_ShareVaultItemRequest) async throws -> Vync_Vault_ShareVaultItemResponse {
        SanchrLogger.network.info("gRPC: VaultService/ShareVaultItem")
        throw AppError.serverUnreachable
    }
}
