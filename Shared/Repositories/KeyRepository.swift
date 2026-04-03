import Foundation

/// Protocol defining Signal Protocol key management operations.
protocol KeyRepositoryProtocol: AnyObject, Sendable {
    /// Uploads the full key bundle (identity key, signed pre-key, one-time pre-keys) to the server.
    func uploadKeyBundle(_ bundle: Vync_Keys_KeyBundle) async throws

    /// Fetches the pre-key bundle for a specific user and device from the server.
    func getPreKeyBundle(userId: String, deviceId: Int32) async throws -> Vync_Keys_PreKeyBundleResponse

    /// Uploads additional one-time pre-keys to the server.
    func uploadOneTimePreKeys(_ keys: [Vync_Keys_OneTimePreKey]) async throws -> Int32

    /// Gets the current count of remaining one-time pre-keys on the server.
    func getPreKeyCount() async throws -> Int32

    /// Fetches all device IDs registered for a user.
    func getUserDevices(userId: String) async throws -> [Int32]
}

// MARK: - Implementation

final class KeyRepositoryImpl: KeyRepositoryProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    func uploadKeyBundle(_ bundle: Vync_Keys_KeyBundle) async throws {
        SanchrLogger.crypto.info("Uploading key bundle to server")

        _ = try await grpcClient.keyService.uploadKeyBundle(bundle)

        SanchrLogger.crypto.info("Key bundle uploaded successfully")
    }

    func getPreKeyBundle(userId: String, deviceId: Int32) async throws -> Vync_Keys_PreKeyBundleResponse {
        SanchrLogger.crypto.info("Fetching pre-key bundle for \(userId.prefix(8))... device \(deviceId)")

        var request = Vync_Keys_GetPreKeyBundleRequest()
        request.userID = userId
        request.deviceID = deviceId

        return try await grpcClient.keyService.getPreKeyBundle(request)
    }

    func uploadOneTimePreKeys(_ keys: [Vync_Keys_OneTimePreKey]) async throws -> Int32 {
        SanchrLogger.crypto.info("Uploading \(keys.count) one-time pre-keys")

        var request = Vync_Keys_UploadOneTimePreKeysRequest()
        request.keys = keys

        let response = try await grpcClient.keyService.uploadOneTimePreKeys(request)

        SanchrLogger.crypto.info("Server now has \(response.count) one-time pre-keys")
        return response.count
    }

    func getPreKeyCount() async throws -> Int32 {
        SanchrLogger.crypto.info("Checking pre-key count on server")

        let request = Vync_Keys_GetPreKeyCountRequest()
        let response = try await grpcClient.keyService.getPreKeyCount(request)

        return response.count
    }

    func getUserDevices(userId: String) async throws -> [Int32] {
        SanchrLogger.crypto.info("Fetching devices for user \(userId.prefix(8))...")

        var request = Vync_Keys_GetUserDevicesRequest()
        request.userID = userId

        let response = try await grpcClient.keyService.getUserDevices(request)

        return response.deviceIds
    }
}
