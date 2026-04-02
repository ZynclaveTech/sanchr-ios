import Foundation

// MARK: - vync.keys gRPC Client
// Generated from Proto/keys.proto — DO NOT EDIT

/// Client protocol for the KeyService gRPC service.
protocol Vync_Keys_KeyServiceClientProtocol: Sendable {
    /// Uploads the full key bundle (identity key, signed pre-key, one-time pre-keys).
    func uploadKeyBundle(_ request: Vync_Keys_KeyBundle) async throws -> Vync_Keys_UploadKeyBundleResponse

    /// Fetches a pre-key bundle for establishing a session with a specific user device.
    func getPreKeyBundle(_ request: Vync_Keys_GetPreKeyBundleRequest) async throws -> Vync_Keys_PreKeyBundleResponse

    /// Uploads additional one-time pre-keys when the server count is low.
    func uploadOneTimePreKeys(_ request: Vync_Keys_UploadOneTimePreKeysRequest) async throws -> Vync_Keys_PreKeyCountResponse

    /// Queries the server for the remaining one-time pre-key count.
    func getPreKeyCount(_ request: Vync_Keys_GetPreKeyCountRequest) async throws -> Vync_Keys_PreKeyCountResponse

    /// Lists all registered device IDs for a user.
    func getUserDevices(_ request: Vync_Keys_GetUserDevicesRequest) async throws -> Vync_Keys_GetUserDevicesResponse
}

/// Concrete gRPC client for KeyService.
final class Vync_Keys_KeyServiceClient: Vync_Keys_KeyServiceClientProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    func uploadKeyBundle(_ request: Vync_Keys_KeyBundle) async throws -> Vync_Keys_UploadKeyBundleResponse {
        SanchrLogger.network.info("gRPC: KeyService/UploadKeyBundle")
        throw AppError.serverUnreachable
    }

    func getPreKeyBundle(_ request: Vync_Keys_GetPreKeyBundleRequest) async throws -> Vync_Keys_PreKeyBundleResponse {
        SanchrLogger.network.info("gRPC: KeyService/GetPreKeyBundle")
        throw AppError.serverUnreachable
    }

    func uploadOneTimePreKeys(_ request: Vync_Keys_UploadOneTimePreKeysRequest) async throws -> Vync_Keys_PreKeyCountResponse {
        SanchrLogger.network.info("gRPC: KeyService/UploadOneTimePreKeys")
        throw AppError.serverUnreachable
    }

    func getPreKeyCount(_ request: Vync_Keys_GetPreKeyCountRequest) async throws -> Vync_Keys_PreKeyCountResponse {
        SanchrLogger.network.info("gRPC: KeyService/GetPreKeyCount")
        throw AppError.serverUnreachable
    }

    func getUserDevices(_ request: Vync_Keys_GetUserDevicesRequest) async throws -> Vync_Keys_GetUserDevicesResponse {
        SanchrLogger.network.info("gRPC: KeyService/GetUserDevices")
        throw AppError.serverUnreachable
    }
}
