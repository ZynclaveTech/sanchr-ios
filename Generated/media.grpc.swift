import Foundation

// MARK: - vync.media gRPC Client
// Generated from Proto/media.proto — DO NOT EDIT

/// Client protocol for the MediaService gRPC service.
protocol Vync_Media_MediaServiceClientProtocol: Sendable {
    /// Requests a presigned URL for uploading encrypted media.
    func getUploadUrl(_ request: Vync_Media_GetUploadUrlRequest) async throws -> Vync_Media_PresignedUrlResponse

    /// Requests a presigned URL for downloading encrypted media.
    func getDownloadUrl(_ request: Vync_Media_GetDownloadUrlRequest) async throws -> Vync_Media_PresignedUrlResponse

    /// Confirms that a media upload has completed successfully.
    func confirmUpload(_ request: Vync_Media_ConfirmUploadRequest) async throws -> Vync_Media_ConfirmUploadResponse
}

/// Concrete gRPC client for MediaService.
final class Vync_Media_MediaServiceClient: Vync_Media_MediaServiceClientProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    func getUploadUrl(_ request: Vync_Media_GetUploadUrlRequest) async throws -> Vync_Media_PresignedUrlResponse {
        SanchrLogger.network.info("gRPC: MediaService/GetUploadUrl")
        throw AppError.serverUnreachable
    }

    func getDownloadUrl(_ request: Vync_Media_GetDownloadUrlRequest) async throws -> Vync_Media_PresignedUrlResponse {
        SanchrLogger.network.info("gRPC: MediaService/GetDownloadUrl")
        throw AppError.serverUnreachable
    }

    func confirmUpload(_ request: Vync_Media_ConfirmUploadRequest) async throws -> Vync_Media_ConfirmUploadResponse {
        SanchrLogger.network.info("gRPC: MediaService/ConfirmUpload")
        throw AppError.serverUnreachable
    }
}
